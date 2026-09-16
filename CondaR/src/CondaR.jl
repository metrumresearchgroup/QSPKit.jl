"""An isolated R runtime with automatic project-aware package provisioning."""
module CondaR

using Downloads, JSON, MD5, Libdl, MicroMamba, Pidfile, Preferences, ProjectRoot, SHA, TOML, YAML

const _R_LOCK = ReentrantLock()
const _R_MODULE = Ref{Any}(nothing)
const _ACTIVE = Ref{Any}(nothing)
const _PREPARED = Dict{Tuple{String,Symbol},Any}()

include("tex.jl")
include("config.jl")
include("platform.jl")
include("installer_output.jl")
include("native.jl")
include("provision.jl")

function _prepare_rcall!(root, mode; prepare=_prepare, ensure_tex=ensure_tex_path!)
    prepared = prepare(root, mode)
    _set_rcall_preferences!(root, prepared)
    merge!(ENV, _r_environment(prepared.runtime, prepared.library))
    ensure_tex()
    ENV["KMP_DUPLICATE_LIB_OK"] = "TRUE"
    _ACTIVE[] = prepared
    return prepared
end

"""
    prepare!()

Provision and validate the active project's managed R environment, then write
the project-local RCall preferences without importing RCall. This is intended
for setup processes that run before a fresh Julia process imports ShowKit or
RCall. An unchanged environment is reused.
"""
function prepare!()
    lock(_R_LOCK) do
        root = _project_root()
        return _prepare_rcall!(root, _mode(root))
    end
end

function _ensure_r!()
    lock(_R_LOCK) do
        _R_MODULE[] === nothing || return _R_MODULE[]
        root = _project_root()
        id = Base.PkgId(Base.UUID("6f49c342-dc21-5d91-9882-a32aef131414"), "RCall")
        haskey(Base.loaded_modules, id) && error("RCall was loaded before CondaR could select its R environment. Restart Julia and use ShowKit before importing RCall.")
        prepared = _prepare_rcall!(root, _mode(root))
        R = Base.require(@__MODULE__, :RCall)
        rhome = Base.invokelatest(getproperty, R, :Rhome)
        rhome == prepared.rhome || error(
            "RCall selected $rhome, expected $(prepared.rhome). " *
            "RCall's compile-time preferences were not present when this Julia " *
            "process started. Run `using CondaR; CondaR.prepare!()` in a setup " *
            "process, then start a fresh Julia process.")
        rcall_function = Base.invokelatest(getproperty, R, :rcall)
        Base.invokelatest(
            rcall_function,
            Symbol(".libPaths"),
            [prepared.library, joinpath(prepared.rhome, "library")],
        )
        _ACTIVE[] = prepared
        _R_MODULE[] = R
        R
    end
end

for name in (:rcopy, :reval, :rcall, :robject)
    @eval function $name(args...; kwargs...)
        lock(_R_LOCK) do
            R = _ensure_r!()
            function_from_r = Base.invokelatest(
                getproperty, R, $(QuoteNode(name)))
            Base.invokelatest(function_from_r, args...; kwargs...)
        end
    end
end

"""
    configure!(; mode=:project, verbose=nothing)

Persist the mode in the consuming project's LocalPreferences.toml and refresh
its native and R package resolutions. Unchanged solutions reuse their
verified environments. `:project` follows pkgr.yml (or uses latest when absent);
`:latest` ignores it. If R is already loaded, the current session keeps its
existing library and a restart is required to use a different prepared library.
`verbose=true` persists full live installer output; `false` selects concise
progress and log files. Omitting it preserves the current verbosity setting.
Returns paths and `restart_required`. No pkgr or renv files are changed.
"""
function configure!(; mode::Symbol=:project, verbose::Union{Nothing,Bool}=nothing)
    lock(_R_LOCK) do
        _configure!(_project_root(), mode; verbose)
    end
end

function _configure!(root, mode; verbose::Union{Nothing,Bool}=nothing, prepare=_prepare, active=_ACTIVE[])
    _validate_mode(mode)
    # Save first, so a failed project installation can be escaped with :latest.
    _preferences_lock(root) do
        settings = Pair{String,Any}["mode" => string(mode)]
        verbose !== nothing && push!(settings, "verbose" => verbose)
        Preferences.set_preferences!(_preferences_file(root), "CondaR", settings...; force=true)
    end
    prepared = prepare(root, mode; refresh=true)
    external_r = haskey(Base.loaded_modules, Base.PkgId(Base.UUID("6f49c342-dc21-5d91-9882-a32aef131414"), "RCall"))
    restart = active === nothing ? external_r : (active.library != prepared.library || active.runtime != prepared.runtime)
    restart && @info "CondaR: selected environment is ready. Restart Julia to use it; this session keeps its loaded R packages." mode
    merge(prepared, (; restart_required=restart))
end

r_home() = (_ensure_r!(); _ACTIVE[].rhome)
r_libdir() = (_ensure_r!(); _ACTIVE[].library)

function __init__()
    # No downloads, package builds, preferences writes, or R imports during init.
    ccall(:jl_generating_output, Cint, ()) != 0 && return
    _project_root()
end

export prepare!, rcopy, reval, rcall, robject, ensure_tex_path!
end
