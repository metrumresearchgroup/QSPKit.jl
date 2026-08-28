"""
    CondaR

Provide a CondaPkg-managed, isolated R runtime and lock-serialized wrappers
around the small RCall surface used by QSPKit.
"""
module CondaR

# IMPORTANT: We deliberately do NOT `using RCall` at module top-level.
# RCall's __init__ starts R immediately on import, and the R isolation env
# vars (R_PROFILE_USER, R_LIBS_USER, R_ENVIRON_USER, …) must be set BEFORE
# R starts — otherwise the project's .Rprofile runs, renv activates, and
# .libPaths() gets hijacked away from the conda library.
#
# A previous version of this file set those env vars at module-body top
# level. That looked correct (set them before `using RCall`), but in Julia
# top-level expressions in a precompiled module run ONCE during precompile
# (in a throwaway subprocess) and are NOT re-executed at load time. So the
# ENV mutations happened in the precompile process, died with it, and the
# real process started RCall with no isolation in place. The diagnostic for
# this: `get(ENV, "R_PROFILE_USER", "<unset>") == "<unset>"` right after
# `using CondaR`, despite the source apparently setting it.
#
# Fix: do all env setup inside __init__() (runs once per loading process),
# then load RCall via `Base.require` from within __init__() — so RCall's
# own __init__() runs with the env vars already in place.

using CondaPkg
using Pkg

const _DEFAULT_CONDAPKG_BACKEND = "MicroMamba"
const _DEFAULT_CONDAPKG_ENV = "@qspkit_r"

# Runtime function references — populated in __init__ after RCall has loaded.
const _rcopy_fn   = Ref{Any}(nothing)
const _reval_fn   = Ref{Any}(nothing)
const _rcall_fn   = Ref{Any}(nothing)
const _robject_fn = Ref{Any}(nothing)
const _R_LOCK = ReentrantLock()

"""
    r_home()

Return the R home directory from the CondaPkg environment.
"""
r_home() = joinpath(CondaPkg.envdir(), "lib", "R")

"""
    r_libdir()

Return the R library directory from the CondaPkg environment.
"""
r_libdir() = joinpath(r_home(), "library")

# ---- R isolation env vars (must be set BEFORE RCall starts R) ----

function _set_condapkg_env_defaults!()
    !isempty(get(ENV, "JULIA_CONDAPKG_ENV", "")) && return nothing

    backend = get(ENV, "JULIA_CONDAPKG_BACKEND", "")
    exe = get(ENV, "JULIA_CONDAPKG_EXE", "")
    if isempty(backend) && isempty(exe)
        ENV["JULIA_CONDAPKG_BACKEND"] = _DEFAULT_CONDAPKG_BACKEND
        ENV["JULIA_CONDAPKG_ENV"] = _DEFAULT_CONDAPKG_ENV
    elseif backend in ("MicroMamba", "System")
        ENV["JULIA_CONDAPKG_ENV"] = _DEFAULT_CONDAPKG_ENV
    elseif isempty(backend) && !isempty(exe) && !occursin("pixi", lowercase(basename(exe)))
        ENV["JULIA_CONDAPKG_ENV"] = _DEFAULT_CONDAPKG_ENV
    end
    return nothing
end

function _set_r_env!()
    rhome = r_home()
    isdir(rhome) || return
    libdir = r_libdir()
    ENV["R_HOME"]         = rhome
    ENV["R_LIBS_SITE"]    = libdir
    ENV["R_LIBS_USER"]    = ""
    ENV["R_LIBS"]         = ""
    # Point at /dev/null instead of "" — some env-cleaning hooks treat an
    # empty value as "unset" and fall through to the default lookup
    # (CWD ./.Rprofile, then ~/.Rprofile). A real path that resolves to an
    # empty/no-op file is unambiguous.
    ENV["R_PROFILE"]      = "/dev/null"
    ENV["R_PROFILE_USER"] = "/dev/null"
    ENV["R_ENVIRON"]      = "/dev/null"
    ENV["R_ENVIRON_USER"] = "/dev/null"
    ENV["RENV_CONFIG_AUTOLOADER_ENABLED"] = "FALSE"
    return nothing
end

# ---- Public wrappers (resolve at call time via the runtime refs) ----

"""
    rcopy(args...; kwargs...)

Convert an R value to a Julia value through the initialized shared R runtime.
Calls are serialized because embedded R is not thread-safe.
"""
function rcopy(args...; kwargs...)
    return lock(_R_LOCK) do
        fn = _rcopy_fn[]
        fn === nothing && error("RCall is not initialized — `using CondaR` must complete first")
        return fn(args...; kwargs...)
    end
end

"""
    reval(args...; kwargs...)

Evaluate R code through the initialized shared R runtime.
"""
function reval(args...; kwargs...)
    return lock(_R_LOCK) do
        fn = _reval_fn[]
        fn === nothing && error("RCall is not initialized")
        return fn(args...; kwargs...)
    end
end

"""
    rcall(args...; kwargs...)

Call an R function through the initialized shared R runtime.
"""
function rcall(args...; kwargs...)
    return lock(_R_LOCK) do
        fn = _rcall_fn[]
        fn === nothing && error("RCall is not initialized")
        return fn(args...; kwargs...)
    end
end

"""
    robject(args...; kwargs...)

Convert a Julia value to an R object through the initialized shared R runtime.
"""
function robject(args...; kwargs...)
    return lock(_R_LOCK) do
        fn = _robject_fn[]
        fn === nothing && error("RCall is not initialized")
        return fn(args...; kwargs...)
    end
end

# ---- Corrupted-install detection and auto-repair ----
#
# Pixi (and conda generally) record packages as installed via JSON entries in
# `<env>/conda-meta/` AND extract their files into `<env>/lib/R/library/<pkg>/`.
# If an extraction is interrupted (network drop, kill -9, FS hiccup), conda-meta
# is written but the package directory is left half-populated — typically with
# the directory tree present but file contents zero-length. Conda/pixi never
# verify file contents on subsequent runs, so the env stays silently broken.
# Symptom: `requireNamespace("foo")` fails with "there is no package called 'foo'"
# even though `<env>/lib/R/library/foo/` exists.
#
# We detect this by scanning every R package's DESCRIPTION for nonzero size,
# and repair by deleting the broken package dir + its conda-meta entry, then
# re-running CondaPkg.resolve() to trigger a re-extract from the pixi cache.

"""
    _find_corrupt_r_packages() -> Vector{String}

Scan `r_libdir()` for R packages whose `DESCRIPTION` is missing or 0 bytes
(the signature of an interrupted conda/pixi extraction). Returns the basenames
of corrupted package directories.
"""
function _find_corrupt_r_packages()
    libdir = r_libdir()
    isdir(libdir) || return String[]
    corrupted = String[]
    for entry in readdir(libdir)
        pkg_dir = joinpath(libdir, entry)
        isdir(pkg_dir) || continue
        desc = joinpath(pkg_dir, "DESCRIPTION")
        if !isfile(desc) || filesize(desc) == 0
            push!(corrupted, entry)
        end
    end
    return corrupted
end

"""
    _repair_corrupt_r_packages!(packages)

Delete each broken package's R-library directory and its matching conda-meta
entry, then call `CondaPkg.resolve(force=true)` to re-extract from the pixi
cache. Conda package names follow `r-<lowercase>` for R packages.
"""
function _repair_corrupt_r_packages!(packages::Vector{String})
    isempty(packages) && return
    libdir = r_libdir()
    metadir = joinpath(CondaPkg.envdir(), "conda-meta")
    for pkg in packages
        pkg_dir = joinpath(libdir, pkg)
        isdir(pkg_dir) && rm(pkg_dir; recursive=true, force=true)
        conda_pkg = "r-" * lowercase(pkg)
        if isdir(metadir)
            for entry in readdir(metadir)
                if startswith(entry, conda_pkg * "-") && endswith(entry, ".json")
                    rm(joinpath(metadir, entry); force=true)
                end
            end
        end
    end
    @info "CondaR: re-resolving environment to reinstall corrupted packages" n=length(packages)
    try
        CondaPkg.resolve(force=true)
    catch e
        @error "CondaR: CondaPkg.resolve(force=true) failed during auto-repair" exception=(e, catch_backtrace())
        rethrow()
    end
    return nothing
end

"""
    _autorepair_corrupted_r_lib!()

Detect and repair corrupted R package installs in the conda env. Runs once
during `__init__`. Slow path (pixi re-extract) only fires when corruption is
present; the no-op case is ~100 `stat` calls. Set
`CONDAR_DISABLE_AUTOREPAIR=true` to skip.
"""
function _autorepair_corrupted_r_lib!()
    lowercase(get(ENV, "CONDAR_DISABLE_AUTOREPAIR", "false")) in ("true","1","yes","on") && return
    corrupted = _find_corrupt_r_packages()
    isempty(corrupted) && return

    @warn "CondaR: detected $(length(corrupted)) corrupted R package(s) " *
          "(DESCRIPTION missing or 0 bytes — likely an interrupted pixi extraction). " *
          "Auto-repairing; this may take a few minutes on first run." packages=corrupted

    _repair_corrupt_r_packages!(corrupted)

    still_broken = _find_corrupt_r_packages()
    if isempty(still_broken)
        @info "CondaR: auto-repair complete" reinstalled=length(corrupted)
    else
        @error "CondaR: auto-repair could not restore some packages. " *
               "Manual fix: `rm -rf $(CondaPkg.envdir())` and restart Julia." packages=still_broken
    end
    return nothing
end

"""
    _rcall_configuration()

Read RCall's generated dependency configuration without importing RCall (and
therefore without starting embedded R). Returns the configured `Rhome` and
`libR`, or empty strings when the configuration is absent or unreadable.
"""
function _rcall_configuration()
    package = Base.identify_package(@__MODULE__, "RCall")
    package === nothing && return (Rhome="", libR="")
    source = Base.locate_package(package)
    source === nothing && return (Rhome="", libR="")

    depfile = joinpath(dirname(dirname(source)), "deps", "deps.jl")
    isfile(depfile) || return (Rhome="", libR="")

    try
        contents = read(depfile, String)
        configured_home = _generated_const_string(contents, "Rhome")
        configured_lib = _generated_const_string(contents, "libR")
        return (Rhome=configured_home, libR=configured_lib)
    catch err
        @debug "CondaR: could not read RCall dependency configuration" depfile exception=(err, catch_backtrace())
        return (Rhome="", libR="")
    end
end

function _generated_const_string(contents::AbstractString, name::AbstractString)
    matched = match(Regex("(?m)^const " * name * raw" = (.+)$"), contents)
    matched === nothing && return ""
    parsed = Meta.parse(only(matched.captures))
    return parsed isa String ? parsed : ""
end

function _rcall_configuration_matches(rhome::AbstractString)
    configured = _rcall_configuration()
    return configured.Rhome == rhome && !isempty(configured.libR) && isfile(configured.libR)
end

function _build_rcall_for_managed_r!()
    CondaPkg.resolve()
    rhome = r_home()
    if !isfile(joinpath(rhome, "bin", "R"))
        error("R not found at $rhome after CondaPkg.resolve()")
    end

    _set_r_env!()
    Pkg.build("RCall")
    _rcall_configuration_matches(rhome) ||
        error("RCall build completed but did not record the managed R installation at $rhome")
    return rhome
end

function _ensure_rcall_configured!()
    expected = r_home()
    _rcall_configuration_matches(expected) && return false

    @info "CondaR: configuring RCall for the managed R installation" Rhome=expected
    _build_rcall_for_managed_r!()
    return true
end

"""
    configure!()

Rebuild RCall to use the CondaPkg R installation.
Writes to RCall's `deps/deps.jl` (works regardless of dependency depth).
Requires a Julia restart to take effect.
"""
function configure!()
    rhome = _build_rcall_for_managed_r!()
    @info "RCall built against CondaPkg R at $rhome. Restart Julia for this to take effect."
    return rhome
end

function __init__()
    # Allow duplicate libomp (Homebrew Julia OpenBLAS vs Conda R)
    ENV["KMP_DUPLICATE_LIB_OK"] = "TRUE"

    # Skip during precompilation — Pkg.build()/Base.require() are unsafe here,
    # and ENV mutations would target the throwaway precompile process anyway.
    ccall(:jl_generating_output, Cint, ()) != 0 && return

    # 1. Keep CondaR on one shared R runtime instead of one .CondaPkg env per
    #    active Julia project. CondaPkg must see these before envdir() resolves.
    _set_condapkg_env_defaults!()

    # 2. Isolate R from any project/user/system R configuration. This must
    #    happen before RCall's __init__ runs Rf_initEmbeddedR().
    _set_r_env!()

    # 3. Detect and repair conda/pixi extraction failures (0-byte DESCRIPTION
    #    files in the R lib). Must run BEFORE R starts so R doesn't cache
    #    "package X is missing" for the broken packages.
    _autorepair_corrupted_r_lib!()

    # 4. RCall's package build can run before CondaR's __init__ in a fresh
    #    environment, leaving deps/deps.jl empty. Configure it against the
    #    managed R now, before importing RCall and starting embedded R.
    _ensure_rcall_configured!()

    # 5. Point R's libcurl at the conda env's CA certificates.
    certfile = joinpath(CondaPkg.envdir(), "ssl", "cacert.pem")
    if isfile(certfile)
        ENV["CURL_CA_BUNDLE"] = certfile
    end

    # 6. Now load RCall. Its __init__ starts R, which sees R_PROFILE_USER
    #    pointing at /dev/null and does not source the project .Rprofile.
    RCall = Base.require(@__MODULE__, :RCall)

    _rcopy_fn[]   = RCall.rcopy
    _reval_fn[]   = RCall.reval
    _rcall_fn[]   = RCall.rcall
    _robject_fn[] = RCall.robject

    # 7. Verify R home, pin .libPaths() to the conda library.
    expected = r_home()
    if RCall.Rhome == expected
        Base.invokelatest(RCall.rcall, Symbol(".libPaths"), r_libdir())
    else
        @warn "RCall.Rhome ($(RCall.Rhome)) does not match CondaPkg R ($expected). " *
              "Running CondaR.configure!() — restart Julia after this completes."
        try
            configure!()
        catch e
            @error "CondaR.configure!() failed" exception=e
        end
    end
end

export rcopy, rcall, reval, robject

end # module
