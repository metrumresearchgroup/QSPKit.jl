# Project configuration is read at runtime, never while precompiling CondaR.
const _REQUIRED_PACKAGES = ["ggplot2", "pmplots", "pmtables", "mrggsave", "pdftools", "vpc", "npde"]
const _LATEST_REPOS = ["CRAN" => "https://cloud.r-project.org"]
const _PROJECT_ROOT = Ref("")
const _FORMAT_VERSION = 3

function _project_root()
    isempty(_PROJECT_ROOT[]) || return _PROJECT_ROOT[]
    active = Base.active_project()
    active === nothing && error("CondaR needs an active Julia project. Start Julia with --project=.")
    # A macro here would find CondaR's own source tree, not the consuming project.
    _PROJECT_ROOT[] = realpath(ProjectRoot.find_root(dirname(active)))
end

function _project_file(root)
    for name in ("JuliaProject.toml", "Project.toml")
        file = joinpath(root, name)
        isfile(file) && return file
    end
    error("No Julia Project.toml in $root")
end

function _preferences_file(root)
    for name in ("JuliaLocalPreferences.toml", "LocalPreferences.toml")
        path = joinpath(root, name)
        isfile(path) && return path
    end
    joinpath(root, "LocalPreferences.toml")
end

_preferences_lock(f, root) = Pidfile.mkpidlock(f, joinpath(root, ".condar-preferences.pid"); wait=true)

function _preference(root, key, default)
    project = TOML.parsefile(_project_file(root))
    shared = get(get(project, "preferences", Dict()), "CondaR", Dict())
    file = _preferences_file(root)
    localprefs = isfile(file) ? get(TOML.parsefile(file), "CondaR", Dict()) : Dict()
    get(localprefs, key, get(shared, key, default))
end

_mode(root) = _validate_mode(Symbol(_preference(root, "mode", "project")))
function _verbose(root)
    value = _preference(root, "verbose", false)
    value isa Bool || throw(ArgumentError("CondaR verbose preference must be true or false"))
    value
end

function _validate_mode(mode)
    mode in (:project, :latest) || throw(ArgumentError("R mode must be :project or :latest; got $(repr(mode))"))
    mode
end

function _named_entries(entries, label)
    entries isa AbstractVector || error("pkgr.yml $label must be a list of named mappings")
    result = Pair{String,Any}[]
    for entry in entries
        entry isa AbstractDict && length(entry) == 1 || error("Invalid pkgr.yml $label entry: $entry")
        key, value = only(entry)
        any(p -> first(p) == key, result) && error("Duplicate pkgr.yml $label entry: $key")
        push!(result, String(key) => value)
    end
    result
end

function _customization(value, label; package=false)
    value isa AbstractDict || error("$label must be a mapping")
    allowed = package ? ("Repo", "Type", "Suggests", "Env") : ("Type", "Suggests", "Env")
    unknown = setdiff(collect(keys(value)), allowed)
    isempty(unknown) || error("Unsupported $label fields: $(join(unknown, ", "))")
    if haskey(value, "Type")
        value["Type"] == "source" || error("$label: CondaR supports Type: source only; system-R binaries cannot be used with managed R")
    end
    haskey(value, "Suggests") && !(value["Suggests"] isa Bool) && error("$label Suggests must be true or false")
    env = get(value, "Env", Dict())
    env isa AbstractDict && all(k isa String && v isa String for (k,v) in env) || error("$label Env must map names to strings")
    Dict{String,Any}(value)
end

function _configuration(root, mode=_mode(root))
    _validate_mode(mode)
    path = joinpath(root, "pkgr.yml")
    effective = mode == :project && isfile(path) ? :project : :latest
    config = Dict{String,Any}("format" => _FORMAT_VERSION, "mode" => string(effective),
        "requested_mode" => string(mode), "packages" => copy(_REQUIRED_PACKAGES),
        "github_packages" => ["pmplots", "pmtables", "mrggsave"],
        "repos" => [Dict("name" => k, "url" => v) for (k,v) in _LATEST_REPOS],
        "package_options" => Dict{String,Any}(), "repo_options" => Dict{String,Any}(), "suggests" => false)
    effective == :latest && return config
    delete!(config, "github_packages")
    y = YAML.load_file(path)
    y isa AbstractDict || error("pkgr.yml must contain a mapping")
    get(y, "Version", nothing) == 1 || error("CondaR supports pkgr.yml Version: 1")
    # These belong to pkgr's own execution/library management, not CondaR.
    ignored = ("Rpath", "Library", "Libpaths", "Lockfile", "Cache", "Logging", "Loglevel", "Threads", "Update", "Strict")
    unknown = setdiff(collect(keys(y)), ("Version", "Packages", "Repos", "Customizations", "Suggests", ignored...))
    isempty(unknown) || error("Unsupported pkgr.yml fields for CondaR: $(join(unknown, ", "))")
    # pkgr owns the project's R package list. QSPKit requests only its own roots;
    # repository policy and relevant dependency customizations are still honored.
    repos = _named_entries(get(y, "Repos", nothing), "Repos")
    isempty(repos) && error("pkgr.yml Repos cannot be empty")
    config["repos"] = [begin
        url isa String && occursin(r"^(https?://|file://)", url) || error("Invalid repository URL for $name")
        Dict("name" => name, "url" => rstrip(url, '/'))
    end for (name,url) in repos]
    suggests = get(y, "Suggests", false)
    suggests isa Bool || error("pkgr.yml Suggests must be true or false")
    config["suggests"] = suggests
    custom = get(y, "Customizations", Dict())
    custom isa AbstractDict || error("pkgr.yml Customizations must be a mapping")
    isempty(setdiff(collect(keys(custom)), ["Packages", "Repos"])) || error("Unsupported pkgr.yml Customizations section")
    for (section, target) in (("Packages", "package_options"), ("Repos", "repo_options"))
        for (name, value) in _named_entries(get(custom, section, []), "Customizations.$section")
            opts = _customization(value, "Customizations.$section.$name"; package=section == "Packages")
            section == "Repos" && !(name in first.(repos)) && error("Unknown repository customization: $name")
            haskey(opts, "Repo") && !(opts["Repo"] in first.(repos)) && error("Unknown repository for $name: $(opts["Repo"])")
            config[target][name] = opts
        end
    end
    config
end

function _toml_string(value)
    sprint(io -> TOML.print(io, value; sorted=true))
end
_fingerprint(config) = bytes2hex(SHA.sha256(_toml_string(config)))

# Every string passed to R is data; no shell or R interpolation of project input.
_r_literal(x::AbstractString) = "\"" * replace(x, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t") * "\""
_r_literal(x::Bool) = x ? "TRUE" : "FALSE"
_r_literal(x::Integer) = string(x)
_r_literal(x::AbstractVector) = "list(" * join(_r_literal.(x), ",") * ")"
_r_literal(x::AbstractDict) = "setNames(list(" * join([_r_literal(x[k]) for k in sort!(collect(keys(x)))], ",") * "),c(" * join(_r_literal.(sort!(collect(keys(x)))), ",") * "))"
