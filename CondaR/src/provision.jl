_cache_root(root) = joinpath(first(DEPOT_PATH), "condar", _path_id(bytes2hex(SHA.sha256(realpath(root)))))
function _atomic_toml(path, value)
    mkpath(dirname(path))
    temp, io = mktemp(dirname(path))
    try
        TOML.print(io, value; sorted=true)
        close(io)
        mv(temp, path; force=true)
    finally
        isopen(io) && close(io)
        isfile(temp) && rm(temp)
    end
end

function _atomic_copy(source, destination)
    temp, io = mktemp(dirname(destination))
    close(io)
    try
        cp(source, temp; force=true)
        mv(temp, destination; force=true)
    finally
        isfile(temp) && rm(temp)
    end
end

function _r_environment(runtime, library; platform=_platform())
    e = Dict{String,String}()
    e["R_HOME"] = _rhome(runtime, platform)
    e["R_LIBS"] = library
    e["R_LIBS_USER"] = library
    e["R_LIBS_SITE"] = library
    for key in ("R_PROFILE", "R_PROFILE_USER", "R_ENVIRON", "R_ENVIRON_USER", "R_MAKEVARS_USER")
        e[key] = platform.os == "win" ? "NUL" : "/dev/null"
    end
    e["RENV_CONFIG_AUTOLOADER_ENABLED"] = "FALSE"
    e["CONDA_PREFIX"] = runtime
    e["MAKEFLAGS"] = get(ENV, "MAKEFLAGS", "-j$(min(4, Sys.CPU_THREADS))")
    e["PATH"] = join([_runtime_bins(runtime, platform); get(ENV, "PATH", "")], platform.os == "win" ? ';' : ':')
    native = platform.os == "win" ? joinpath(runtime, "Library") : runtime
    # Do not combine a managed compiler/sysroot with host pkg-config metadata.
    # Explicit pkgr package/repository Env customizations are applied later.
    pcdirs = join([joinpath(native, "lib", "pkgconfig"), joinpath(native, "share", "pkgconfig")], platform.os == "win" ? ';' : ':')
    e["PKG_CONFIG_PATH"] = pcdirs
    e["PKG_CONFIG_LIBDIR"] = pcdirs
    e["PKG_CONFIG_SYSROOT_DIR"] = ""
    cert = platform.os == "win" ? joinpath(runtime, "Library", "ssl", "cacert.pem") : joinpath(runtime, "ssl", "cacert.pem")
    isfile(cert) && (e["CURL_CA_BUNDLE"] = cert)
    e
end

function _run_worker(runtime, library, action, config_file, plan_file; verbose=false)
    script = joinpath(@__DIR__, "provision.R")
    rscript = _rscript(runtime)
    # micromamba run applies compiler/native-library activation hooks for source installs.
    command = _micromamba_cmd(`--no-rc run -p $runtime $rscript --vanilla $script $action $config_file $plan_file $library`)
    _run_logged(addenv(command, _r_environment(runtime, library)),
                _installer_log(dirname(config_file), action); verbose, label="R package $action")
end

function _prepare(root, mode; refresh=false, cache=_cache_root(root), verbose=_verbose(root),
                  native_resolver=((directory; refresh) -> _resolve_native(directory; refresh, verbose)),
                  runtime_installer=((runtime, resolution) -> _ensure_runtime(runtime, resolution; verbose)),
                  attester=_attest_sources,
                  worker=((args...) -> _run_worker(args...; verbose)),
                  build_checker=(runtime -> _ensure_build_tools(runtime; verbose)))
    config = _configuration(root, mode)
    key = (root, mode)
    fingerprint = _fingerprint(Dict("configuration" => config,
        "native" => _native_requirements(), "host" => _host_identity()))
    if !refresh && haskey(_PREPARED, key) && _PREPARED[key].fingerprint == fingerprint
        return _PREPARED[key]
    end
    mkpath(cache)
    prepared = Pidfile.mkpidlock(joinpath(cache, "provision.pid"); wait=true) do
        config_dir = joinpath(cache, string(mode), _path_id(fingerprint))
        mkpath(config_dir)
        config_file = joinpath(config_dir, "config.R")
        current_file = joinpath(config_dir, "current.toml")
        current = isfile(current_file) ? TOML.parsefile(current_file) : nothing
        resolve = refresh || config["mode"] == "latest" || current === nothing || !isfile(current["plan"])
        plan = resolve ? joinpath(config_dir, "candidate.rds") : current["plan"]
        resolution = nothing
        runtime = ""
        # Only metadata transport failures may keep a previous latest environment.
        # Solver conflicts, source mismatches, build/validation failures stay errors.
        try
            resolution = resolve ? native_resolver(config_dir; refresh=(refresh || config["mode"] == "latest")) :
                         TOML.parsefile(joinpath(current["runtime"], "condar-native.toml"))
        catch err
            if config["mode"] == "latest" && current !== nothing && _native_transport_failure(err)
                @warn "CondaR: native repository refresh failed; keeping the previously verified environment. Freshness could not be checked." exception=(err, catch_backtrace())
                worker(current["runtime"], current["library"], "validate", config_file, current["plan"])
                return (; root, mode, effective_mode=Symbol(config["mode"]), fingerprint,
                    runtime=current["runtime"], rhome=_rhome(current["runtime"]), library=current["library"])
            end
            rethrow()
        end
        runtime = _runtime_path(cache, resolution)
        runtime_installer(runtime, resolution)
        if resolve
            # Resolve repository policy before considering the native binaries.
            write(config_file, "config <- " * _r_literal(config) * "\n")
            try
                worker(runtime, "", "resolve", config_file, plan)
            catch err
                if config["mode"] == "latest" && current !== nothing && _transport_failure(err)
                    @warn "CondaR: repository refresh failed; using the previously verified environment. Latest versions could not be checked." exception=(err, catch_backtrace())
                    worker(current["runtime"], current["library"], "validate", config_file, current["plan"])
                    return (; root, mode, effective_mode=Symbol(config["mode"]), fingerprint,
                        runtime=current["runtime"], rhome=_rhome(current["runtime"]), library=current["library"])
                end
                rethrow()
            end
            config["prebuilt"] = attester(runtime, plan, cache)
            write(config_file, "config <- " * _r_literal(config) * "\n")
            worker(runtime, "", "select", config_file, plan)
            _atomic_toml(joinpath(config_dir, "config.toml"), config)
        end
        # Native and R resolutions jointly identify the library: source builds
        # must never be reused against a different native environment.
        generation = _fingerprint(Dict("native" => resolution, "packages" => read(plan * ".tsv", String)))
        library = joinpath(config_dir, "libraries", _path_id(generation))
        ready = joinpath(library, "condar-ready.toml")
        if !isfile(ready)
            @info "CondaR: provisioning R packages" mode library
            mkpath(library)
            for entry in readdir(library; join=true)
                startswith(basename(entry), "00LOCK") && rm(entry; recursive=true, force=true)
            end
            build_file = plan * ".build"
            isfile(build_file) && !isempty(strip(read(build_file, String))) && build_checker(runtime)
            worker(runtime, library, "install", config_file, plan)
            worker(runtime, library, "validate", config_file, plan)
            _atomic_toml(ready, Dict("fingerprint" => fingerprint, "generation" => generation))
        elseif refresh || current === nothing || current["library"] != library
            # A published generation already passed validation. Reuse it across
            # sessions without starting an R worker to load every namespace.
            # Explicit refresh and publishing a different generation still check it.
            worker(runtime, library, "validate", config_file, plan)
        end
        published_plan = joinpath(library, "condar-plan.rds")
        for suffix in ("", ".tsv", ".json", ".build")
            if isfile(plan * suffix) && !isfile(published_plan * suffix)
                _atomic_copy(plan * suffix, published_plan * suffix)
            end
        end
        _atomic_toml(current_file, Dict("library" => library, "generation" => generation,
                                        "plan" => published_plan, "runtime" => runtime))
        (; root, mode, effective_mode=Symbol(config["mode"]), fingerprint, runtime, rhome=_rhome(runtime), library)
    end
    _PREPARED[key] = prepared
    prepared
end

# Micromamba uses exit 1 for both network problems and unsatisfiable solves.
# Recognize only specific transport diagnostics, never a generic solver failure.
function _native_transport_failure(err)
    _transport_failure(err) && return true
    err isa InstallationError && isfile(err.logfile) || return false
    occursin(r"Download error|Could not resolve host|Failed to connect|Connection timed out", read(err.logfile, String))
end

function _set_rcall_preferences!(root, prepared)
    libr = _libr(prepared.rhome)
    isfile(libr) || error("R shared library not found at $libr")
    _preferences_lock(root) do
        Preferences.set_preferences!(
            (Base.UUID("6f49c342-dc21-5d91-9882-a32aef131414"), "RCall"),
            "Rhome" => prepared.rhome,
            "libR" => libr;
            project_toml=_project_file(root),
            force=true,
        )
    end
end
