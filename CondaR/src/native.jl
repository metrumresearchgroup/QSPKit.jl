# Requirements belong to QSPKit; concrete native resolutions belong to projects.
function _native_requirements(platform=_platform())
    spec = TOML.parsefile(joinpath(@__DIR__, "..", "Runtime.toml"))
    groups = get(spec, "platform-deps", Dict())
    deps = copy(spec["deps"])
    platform.os != "win" && merge!(deps, get(groups, "unix", Dict()))
    merge!(deps, get(groups, platform.os, Dict()), get(groups, platform.subdir, Dict()))
    Dict("platform" => platform.subdir, "channels" => spec["channels"], "deps" => deps)
end

function _host_identity()
    version = if Sys.islinux()
        unsafe_string(ccall(:gnu_get_libc_version, Cstring, ()))
    elseif Sys.isapple()
        readchomp(`sw_vers -productVersion`)
    else
        string(Sys.windows_version())
    end
    Dict("machine" => Sys.MACHINE, "version" => version)
end

function _validate_resolution(resolution; platform=_platform())
    get(resolution, "format", 0) == 1 || error("Unsupported CondaR native resolution format")
    resolution["platform"] == platform.subdir || error("Native resolution belongs to another OS/architecture")
    resolution["host"] == _host_identity() || error("Native resolution belongs to another host ABI; refresh the environment")
    names = Set{String}()
    for artifact in resolution["artifacts"]
        artifact["name"] in names && error("Duplicate native artifact: $(artifact["name"])")
        push!(names, artifact["name"])
        startswith(artifact["url"], "https://conda.anaconda.org/conda-forge/") || error("Unexpected native provider: $(artifact["url"])")
        subdir = split(artifact["url"], '/')[end-1]
        subdir in (platform.subdir, "noarch") || error("Native artifact belongs to another OS/architecture: $(artifact["name"])")
        occursin(r"^[a-f0-9]{64}$", artifact["sha256"]) || error("Missing native SHA256: $(artifact["name"])")
    end
    "r-base" in names || error("Native resolution does not contain R")
    resolution
end

function _explicit_spec(resolution)
    "@EXPLICIT\n" * join([a["url"] * "#" * a["sha256"] for a in resolution["artifacts"]], "\n") * "\n"
end

_runtime_path(cache, resolution) = joinpath(cache, "runtimes", _path_id(_fingerprint(resolution)))

function _solve_native(directory; verbose=false)
    policy = _native_requirements()
    packages = [name * (version == "*" ? "" : version) for (name,version) in sort!(collect(policy["deps"]))]
    channels = reduce(vcat, [["-c", channel] for channel in policy["channels"]])
    # This prefix is never created: the dry run returns the complete dependency
    # solution. Actual installation below uses that solution's exact artifacts.
    prefix = joinpath(directory, "solve")
    command = _micromamba_cmd(`--no-rc create --dry-run --json -y -p $prefix --platform $(policy["platform"]) --override-channels --strict-channel-priority $channels $packages`)
    logfile = _installer_log(directory, "native-resolve")
    _run_logged(command, logfile; verbose, label="Resolving compatible native packages")
    output = read(logfile, String)
    # Non-JSON diagnostics can precede/follow the JSON document on stderr.
    first_brace, last_brace = findfirst('{', output), findlast('}', output)
    first_brace === nothing && error("Native solver did not return JSON; see $logfile")
    result = JSON.parse(output[first_brace:last_brace])
    get(result, "success", false) || error("Native solver did not succeed; see $logfile")
    artifacts = [Dict(k => record[k] for k in ("name", "version", "build", "url", "sha256"))
                 for record in result["actions"]["LINK"]]
    sort!(artifacts; by=a -> a["name"])
    _validate_resolution(Dict("format" => 1, "platform" => policy["platform"],
                              "host" => _host_identity(), "artifacts" => artifacts))
end

function _resolve_native(directory; refresh=false, verbose=false)
    file = joinpath(directory, "native.toml")
    # Keep an interrupted attempt reproducible. Explicit refresh/latest mode
    # asks upstream to resolve again; an unchanged solution reuses its runtime.
    if !refresh && isfile(file)
        return _validate_resolution(TOML.parsefile(file))
    end
    resolution = _solve_native(directory; verbose)
    _atomic_toml(file, resolution)
    resolution
end

function _binary_catalog(runtime, resolution)
    library = joinpath(_rhome(runtime), "library")
    packages = Dict(lowercase(name) => name for name in readdir(library))
    catalog = Dict{String,Any}()
    for artifact in resolution["artifacts"]
        name = artifact["name"]
        startswith(name, "r-") && name != "r-base" || continue
        package = get(packages, name[3:end], nothing)
        package === nothing && continue
        metadata_file = joinpath(runtime, "conda-meta", "$name-$(artifact["version"])-$(artifact["build"]).json")
        metadata = JSON.parsefile(metadata_file)
        metadata["sha256"] == artifact["sha256"] || error("Installed native artifact differs from its resolution: $name")
        recipe_file = joinpath(get(metadata, "extracted_package_dir", ""), "info", "recipe", "meta.yaml")
        if !isfile(recipe_file)
            @info "CondaR: binary has no source recipe; repository source will be used" package
            continue
        end
        recipe = YAML.load_file(recipe_file)
        source = get(recipe, "source", nothing)
        if !(source isa AbstractDict) || !occursin(r"^[a-f0-9]{64}$", string(get(source, "sha256", "")))
            @info "CondaR: binary has no single verifiable source; repository source will be used" package
            continue
        end
        desc = read(joinpath(library, package, "DESCRIPTION"), String)
        version = match(r"(?m)^Version:\s*([^\r\n]+)", desc)
        version === nothing && error("Installed R binary lacks a version: $package")
        catalog[package] = Dict("version" => strip(version[1]), "source_sha256" => source["sha256"],
            "artifact" => artifact["url"], "patches" => get(source, "patches", nothing) === nothing ? String[] : source["patches"])
    end
    catalog
end

function _ensure_runtime(runtime, resolution; verbose=false)
    _validate_resolution(resolution)
    identity = _fingerprint(resolution)
    ready = joinpath(runtime, "condar-ready.toml")
    check_script = joinpath(@__DIR__, "runtime_check.R")
    check_version = bytes2hex(SHA.sha256(read(check_script)))
    if isfile(ready)
        previous = TOML.parsefile(ready)
        get(previous, "resolution", "") == identity || error("Runtime $runtime belongs to another native resolution")
        get(previous, "check", "") == check_version && return runtime
    else
        mkpath(dirname(runtime))
        isdir(runtime) && rm(runtime; recursive=true) # incomplete, never published
        explicit = runtime * ".explicit.txt"
        write(explicit, _explicit_spec(resolution))
        command = _micromamba_cmd(`--no-rc create -y -p $runtime --platform $(resolution["platform"]) --file $explicit`)
        _run_logged(command, _installer_log(dirname(runtime), "runtime"); verbose,
                    label="Installing resolved native packages", fail_on_critical=true)
        catalog = _binary_catalog(runtime, resolution)
        _atomic_toml(joinpath(runtime, "condar-binaries.toml"), catalog)
        _atomic_toml(joinpath(runtime, "condar-native.toml"), resolution)
    end
    isfile(_rscript(runtime)) && isfile(_libr(_rhome(runtime))) || error("Managed R executables/shared library missing at $runtime")
    catalog = TOML.parsefile(joinpath(runtime, "condar-binaries.toml"))
    packages = [merge(info, Dict("package" => package)) for (package,info) in catalog]
    binary_config = runtime * ".binaries.R"
    write(binary_config, "packages <- " * _r_literal(packages) * "\n")
    command = _micromamba_cmd(`--no-rc run -p $runtime $(_rscript(runtime)) --vanilla $check_script $binary_config`)
    _run_logged(addenv(command, _r_environment(runtime, "")), _installer_log(dirname(runtime), "runtime-check");
                verbose, label="Verifying resolved R binaries")
    _atomic_toml(ready, Dict("resolution" => identity, "check" => check_version))
    runtime
end

# Compare selected repository bytes with the installed binary's upstream source.
# A version match alone is insufficient, including between two MPN snapshots.
function _attest_sources(runtime, plan, cache; downloader=Downloads.download)
    catalog = TOML.parsefile(joinpath(runtime, "condar-binaries.toml"))
    records = JSON.parsefile(plan * ".json")
    verified = Dict{String,Any}()
    for rec in records
        package = rec["Package"]
        binary = get(catalog, package, nothing)
        binary === nothing && continue
        binary["version"] == rec["Version"] && rec["BinaryAllowed"] || continue
        println(stderr, "CondaR: Verifying binary source for $package against $(rec["Repository"])")
        directory = mkpath(joinpath(cache, "sources"))
        source = joinpath(directory, binary["source_sha256"] * ".tar.gz")
        md5 = rec["MD5sum"]
        # A repository checksum permits reuse of already verified downloaded
        # bytes. Without one, retrieve the selected URL again on refresh.
        if isempty(md5) || !isfile(source) || bytes2hex(open(MD5.md5, source)) != md5
            temp, io = mktemp(directory)
            close(io)
            try
                downloader(rec["TarURL"], temp)
                actual_md5 = bytes2hex(open(MD5.md5, temp))
                !isempty(md5) && actual_md5 != md5 && error("Repository source checksum mismatch: $package ($(rec["TarURL"]))")
                if bytes2hex(open(SHA.sha256, temp)) != binary["source_sha256"]
                    @info "CondaR: binary source differs; using selected repository source" package
                    continue
                end
                mv(temp, source; force=true)
            finally
                isfile(temp) && rm(temp; force=true)
            end
        end
        bytes2hex(open(SHA.sha256, source)) == binary["source_sha256"] || error("Cached R source checksum mismatch: $package")
        verified[package] = merge(binary, Dict("source_md5" => bytes2hex(open(MD5.md5, source)),
                                              "source_url" => rec["TarURL"]))
    end
    verified
end
function _ensure_build_tools(runtime; verbose=false)
    check = joinpath(@__DIR__, "native_check.R")
    version = bytes2hex(SHA.sha256(read(check)))
    marker = joinpath(runtime, "condar-build-verified.toml")
    isfile(marker) && get(TOML.parsefile(marker), "check", "") == version && return
    if Sys.isapple()
        Sys.which("xcrun") === nothing && error("The selected R sources need compilation. Install Apple's Command Line Tools with xcode-select --install, then retry. Prebuilt R packages do not need an SDK.")
        sdk = readchomp(`xcrun --sdk macosx --show-sdk-path`)
        isdir(sdk) || error("Apple SDK not found at $sdk")
    end
    command = _micromamba_cmd(`--no-rc run -p $runtime $(_rscript(runtime)) --vanilla $check $runtime`)
    _run_logged(addenv(command, _r_environment(runtime, "")),
                _installer_log(dirname(runtime), "native-check"); verbose, label="Checking tools for source-only R packages")
    _atomic_toml(marker, Dict("check" => version))
end
