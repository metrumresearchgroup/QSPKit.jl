"""
    QSPKitIO

Versioned, named-field archives for QSPKit result objects. Archives are backed
by JLD2 and carry a small manifest describing their format, schema, package,
Julia version, and creation time.

Archive restoration resolves loaded Julia types and invokes their constructors.
Only restore archives from trusted sources.
"""
module QSPKitIO

import Dates
import JLD2
import TOML

export ArchiveSpec, ArchiveContext
export save_archive, load_archive, read_archive_manifest
export has_archive_native_payload, read_archive_native_payload
export archive_payload, restore_payload
export record_schema!, archive_type_name, coerce_field, default_field
export TYPE_KEY

"""Dictionary key used to record a fully qualified Julia type name."""
const TYPE_KEY = "__type__"
const OPAQUE_KEY = "__opaque__"

"""
    ArchiveSpec(format; kwargs...)

Define one archive format and its current version. `archivable_modules`
selects which concrete structs may be serialized by named fields. Field
policies can skip runtime-only fields, unwrap `Ref` fields, register custom
archive/restore handlers, and supply defaults for fields added after an archive
was written.
"""
struct ArchiveSpec
    format::String
    archive_version::Int
    package_name::String
    package_module::Union{Nothing, Module}
    archivable_modules::Set{Symbol}
    skip_fields::Dict{DataType, Tuple{Vararg{Symbol}}}
    ref_fields::Dict{DataType, Tuple{Vararg{Symbol}}}
    archive_handlers::Dict{DataType, Function}
    restore_handlers::Dict{DataType, Function}
    default_fields::Dict{Tuple{DataType, Symbol}, Any}
end

function ArchiveSpec(format::AbstractString;
                     archive_version::Integer = 1,
                     package_name::AbstractString = "unknown",
                     package_module::Union{Nothing, Module} = nothing,
                     archivable_modules = Symbol[],
                     skip_fields::AbstractDict = Dict{DataType, Tuple{Vararg{Symbol}}}(),
                     ref_fields::AbstractDict = Dict{DataType, Tuple{Vararg{Symbol}}}(),
                     archive_handlers::AbstractDict = Dict{DataType, Function}(),
                     restore_handlers::AbstractDict = Dict{DataType, Function}(),
                     default_fields::AbstractDict = Dict{Tuple{DataType, Symbol}, Any}())
    modules = Set(Symbol.(collect(archivable_modules)))
    package_module === nothing || push!(modules, nameof(package_module))
    return ArchiveSpec(String(format), Int(archive_version), String(package_name),
                       package_module, modules,
                       _typed_symbol_tuple_dict(skip_fields),
                       _typed_symbol_tuple_dict(ref_fields),
                       _typed_function_dict(archive_handlers),
                       _typed_function_dict(restore_handlers),
                       _typed_default_field_dict(default_fields))
end

function _typed_symbol_tuple_dict(d::AbstractDict)
    out = Dict{DataType, Tuple{Vararg{Symbol}}}()
    for (T, names) in d
        T isa DataType || throw(ArgumentError("ArchiveSpec field policy key must be a concrete DataType; got $T"))
        out[T] = Tuple(Symbol.(collect(names)))
    end
    return out
end

function _typed_function_dict(d::AbstractDict)
    out = Dict{DataType, Function}()
    for (T, f) in d
        T isa DataType || throw(ArgumentError("ArchiveSpec handler key must be a concrete DataType; got $T"))
        f isa Function || throw(ArgumentError("ArchiveSpec handler value for $T must be a Function; got $(typeof(f))"))
        out[T] = f
    end
    return out
end

function _typed_default_field_dict(d::AbstractDict)
    out = Dict{Tuple{DataType, Symbol}, Any}()
    for (key, value) in d
        key isa Tuple && length(key) == 2 ||
            throw(ArgumentError("ArchiveSpec default_fields keys must be (Type, field_symbol); got $key"))
        T, name = key
        T isa DataType || throw(ArgumentError("ArchiveSpec default field type must be a concrete DataType; got $T"))
        out[(T, Symbol(name))] = value
    end
    return out
end

"""
    ArchiveContext(spec)

Mutable state for one archive or restoration pass. The context accumulates the
named-field schemas written to the manifest and may be reused by custom
handlers.
"""
mutable struct ArchiveContext
    spec::ArchiveSpec
    type_schemas::Dict{String, Vector{String}}
end

ArchiveContext(spec::ArchiveSpec) =
    ArchiveContext(spec, Dict{String, Vector{String}}())

"""
    archive_payload(value, spec_or_context)

Convert `value` to the named-field representation governed by an `ArchiveSpec`
or an existing `ArchiveContext`. This does not write a file.
"""
archive_payload(value, spec::ArchiveSpec) = _archive(value, ArchiveContext(spec))
archive_payload(value, ctx::ArchiveContext) = _archive(value, ctx)
"""
    restore_payload(value[, spec_or_context])

Restore a value produced by [`archive_payload`](@ref). Restoration can resolve
loaded Julia types and run constructors or registered handlers, so the input
must be trusted.
"""
restore_payload(value, spec::ArchiveSpec) = _restore(value, ArchiveContext(spec))
restore_payload(value, ctx::ArchiveContext) = _restore(value, ctx)
restore_payload(value) = _restore(value, ArchiveContext(ArchiveSpec("AdHoc")))

"""
    save_archive(path, payload; spec, manifest_extra=Dict(), native_payloads=Dict())

Write a versioned archive and return `path`. `manifest_extra` adds caller-owned
metadata. `native_payloads` stores explicitly named JLD2-native objects beside
the portable named-field payload.
"""
function save_archive(path::AbstractString, payload;
                      spec::ArchiveSpec,
                      manifest_extra::AbstractDict = Dict{String, Any}(),
                      native_payloads::AbstractDict = Dict{String, Any}())
    ctx = ArchiveContext(spec)
    archived = _archive(payload, ctx)
    native = Dict{String, Any}(String(k) => v for (k, v) in native_payloads)
    manifest = _build_manifest(ctx, manifest_extra)
    if !isempty(native)
        manifest["native_payload_keys"] = sort!(collect(keys(native)))
    end
    _jldopen_with_emfile_retry(path, "w"; operation="write archive") do io
        io["__manifest__"] = manifest
        io["payload"] = archived
        isempty(native) || (io["__native_payloads__"] = native)
    end
    return path
end

"""Read and validate the string-keyed manifest from an archive."""
function read_archive_manifest(path::AbstractString)
    return _jldopen_with_emfile_retry(path, "r"; operation="read archive manifest") do io
        haskey(io, "__manifest__") ||
            error("Archive at $path is missing __manifest__")
        manifest = read(io, "__manifest__")
        manifest isa AbstractDict || error("Corrupt manifest in $path")
        return Dict{String, Any}(String(k) => v for (k, v) in manifest)
    end
end

"""
    load_archive(path; expected_format=nothing, max_archive_version=typemax(Int), spec=nothing)

Validate the archive format/version and restore its primary payload. Pass a
full `spec` when custom handlers or field-evolution defaults are required.
Archive contents must be trusted.
"""
function load_archive(path::AbstractString;
                      expected_format::Union{Nothing, AbstractString}=nothing,
                      max_archive_version::Integer = typemax(Int),
                      spec::Union{Nothing, ArchiveSpec}=nothing)
    fmt = spec === nothing ? expected_format : spec.format
    fmt === nothing && throw(ArgumentError(
        "load_archive requires either `expected_format` or `spec`"))
    max_version = spec === nothing ? Int(max_archive_version) : spec.archive_version
    ctx = ArchiveContext(spec === nothing ?
                         ArchiveSpec(String(fmt); archive_version=max_version) :
                         spec)
    return _jldopen_with_emfile_retry(path, "r"; operation="load archive") do io
        haskey(io, "__manifest__") ||
            error("Archive at $path is missing __manifest__")
        manifest = read(io, "__manifest__")
        manifest isa AbstractDict || error("Corrupt manifest in $path")
        format = String(get(manifest, "format", ""))
        format == String(fmt) ||
            error("Archive at $path has format \"$format\"; expected \"$(fmt)\"")
        version = Int(get(manifest, "archive_version", 0))
        version <= max_version ||
            error("Archive version $version at $path is newer than this reader supports (max $(max_version))")
        haskey(io, "payload") || error("Archive at $path is missing payload")
        return _restore(read(io, "payload"), ctx)
    end
end

"""Return whether the archive contains the named native payload `key`."""
function has_archive_native_payload(path::AbstractString, key::AbstractString)
    return _jldopen_with_emfile_retry(path, "r"; operation="read archive native payload") do io
        haskey(io, "__native_payloads__") || return false
        payloads = read(io, "__native_payloads__")
        payloads isa AbstractDict || error("Corrupt native payload table in $path")
        return haskey(payloads, String(key))
    end
end

"""Read a named native payload, or error when its table or key is absent."""
function read_archive_native_payload(path::AbstractString, key::AbstractString)
    return _jldopen_with_emfile_retry(path, "r"; operation="read archive native payload") do io
        haskey(io, "__native_payloads__") ||
            error("Archive at $path has no native payload table")
        payloads = read(io, "__native_payloads__")
        payloads isa AbstractDict || error("Corrupt native payload table in $path")
        key_s = String(key)
        haskey(payloads, key_s) ||
            error("Archive at $path is missing native payload \"$key_s\"")
        return payloads[key_s]
    end
end

function _jldopen_with_emfile_retry(f::Function, path::AbstractString, mode::AbstractString;
                                    operation::AbstractString)
    try
        return JLD2.jldopen(path, mode) do io
            f(io)
        end
    catch err
        _is_open_file_limit_error(err) || rethrow()
        GC.gc()
        try
            return JLD2.jldopen(path, mode) do io
                f(io)
            end
        catch retry_err
            _is_open_file_limit_error(retry_err) || rethrow()
            error("QSPKitIO could not $(operation) at \"$(path)\" because the Julia process " *
                  "has too many open files (EMFILE). A GC retry did not free enough file " *
                  "descriptors. Close unused files/JLD2 handles or restart the Julia session; " *
                  "on long HPC runs, also check the process open-file limit (`ulimit -n`).")
        end
    end
end

_is_open_file_limit_error(err) =
    err isa SystemError && err.errnum == Base.Libc.EMFILE

function _build_manifest(ctx::ArchiveContext, extra::AbstractDict)
    manifest = Dict{String, Any}(
        "format" => ctx.spec.format,
        "archive_version" => ctx.spec.archive_version,
        "package_name" => ctx.spec.package_name,
        "package_version" => _package_version_string(ctx.spec.package_module),
        "julia_version" => string(VERSION),
        "saved_at" => string(Dates.now()),
        "type_schemas" => ctx.type_schemas,
    )
    for (k, v) in extra
        manifest[String(k)] = v
    end
    return manifest
end

function _package_version_string(mod::Union{Nothing, Module})
    mod === nothing && return "unknown"
    dir = pkgdir(mod)
    dir === nothing && return "unknown"
    proj_path = joinpath(dir, "Project.toml")
    isfile(proj_path) || return "unknown"
    try
        toml = TOML.parsefile(proj_path)
        return string(get(toml, "version", "unknown"))
    catch
        return "unknown"
    end
end

_full_type_name(T::Type) = string(parentmodule(T), ".", nameof(T))

"""Return QSPKitIO's fully qualified archive name for type `T`."""
archive_type_name(T::Type) = _full_type_name(T)

function _resolve_type(name::AbstractString)
    parts = split(String(name), '.')
    isempty(parts) && error("Cannot resolve empty type name")
    mod = _resolve_root_module(Symbol(parts[1]), name)
    for p in parts[2:end-1]
        sym = Symbol(p)
        isdefined(mod, sym) || error("Cannot resolve \"$name\": $(mod).$p is not defined")
        mod = getfield(mod, sym)
    end
    leaf = Symbol(parts[end])
    isdefined(mod, leaf) || error("Cannot resolve \"$name\": $(mod).$(parts[end]) is not defined")
    return getfield(mod, leaf)
end

function _resolve_root_module(name::Symbol, qualified::AbstractString)
    name === :Main && return Main
    isdefined(Main, name) && return getfield(Main, name)
    for m in values(Base.loaded_modules)
        nameof(m) === name && return m
    end
    error("Cannot resolve type \"$qualified\": top-level module $name is not loaded")
end

function _is_archivable_struct(::Type{T}, ctx::ArchiveContext) where {T}
    isstructtype(T) || return false
    isconcretetype(T) || return false
    T <: Tuple && return false
    T <: NamedTuple && return false
    T <: Function && return false
    T <: AbstractDict && return false
    T <: AbstractArray && return false
    T <: Ref && return false
    cur = parentmodule(T)
    while true
        nameof(cur) in ctx.spec.archivable_modules && return true
        nxt = parentmodule(cur)
        nxt === cur && return false
        cur = nxt
    end
end

function _kwarg_constructor_names(::Type{T}) where {T}
    for m in methods(T)
        if m.nargs == 1
            kws = Base.kwarg_decl(m)
            isempty(kws) && continue
            return kws
        end
    end
    return nothing
end

function _record_schema!(ctx::ArchiveContext, T::Type)
    name = _full_type_name(T)
    haskey(ctx.type_schemas, name) && return
    skip = get(ctx.spec.skip_fields, T, ())
    ctx.type_schemas[name] = String[String(n) for n in fieldnames(T) if !(n in skip)]
end
"""
    record_schema!(ctx, T)

Record the non-skipped field names of `T` in `ctx.type_schemas`. Returns the
new schema, or `nothing` when it was already recorded.
"""
record_schema!(ctx::ArchiveContext, T::Type) = _record_schema!(ctx, T)

_archive(value, ctx::ArchiveContext) = _archive_dispatch(value, ctx)

function _archive_dispatch(value, ctx::ArchiveContext)
    T = typeof(value)
    handler = get(ctx.spec.archive_handlers, T, nothing)
    if handler !== nothing
        return handler(value, ctx)
    elseif value isa AbstractDict
        return _archive_dict(value, ctx)
    elseif value isa NamedTuple
        return _archive_namedtuple(value, ctx)
    elseif value isa Tuple
        return _archive_tuple(value, ctx)
    elseif value isa AbstractArray
        return _archive_array(value, ctx)
    elseif _is_archivable_struct(T, ctx)
        return _archive_struct(value, ctx)
    elseif _is_jld2_native(value)
        return value
    else
        return _unsupported_archive_value(value, ctx)
    end
end

_is_jld2_native(::Any) = false
_is_jld2_native(::Number) = true
_is_jld2_native(::AbstractString) = true
_is_jld2_native(::Symbol) = true
_is_jld2_native(::Nothing) = true
_is_jld2_native(::Missing) = true

function _archive_dict(d::AbstractDict, ctx::ArchiveContext)
    out = Dict{String, Any}("__container__" => "Dict")
    kt = keytype(d)
    vt = valtype(d)
    if _is_simple_concrete_type(kt)
        out["key_type"] = _try_full_type_name(kt)
    end
    if _is_simple_concrete_type(vt)
        out["value_type"] = _try_full_type_name(vt)
    end
    entries = Dict{String, Any}[]
    for (k, v) in d
        push!(entries, Dict{String, Any}(
            "key" => _archive(k, ctx),
            "value" => _archive(v, ctx),
        ))
    end
    out["entries"] = entries
    return out
end

function _try_full_type_name(T::Type)
    try
        return _full_type_name(T)
    catch
        return nothing
    end
end

_is_simple_concrete_type(T::Type) =
    T isa DataType && isempty(T.parameters) && isconcretetype(T) && T !== Any

function _archive_namedtuple(nt::NamedTuple, ctx::ArchiveContext)
    out = Dict{String, Any}("__container__" => "NamedTuple",
                            "names" => String[String(n) for n in keys(nt)])
    for (k, v) in pairs(nt)
        out[String(k)] = _archive(v, ctx)
    end
    return out
end

function _archive_tuple(t::Tuple, ctx::ArchiveContext)
    out = Dict{String, Any}("__container__" => "Tuple", "n" => length(t))
    for (i, v) in enumerate(t)
        out[string(i)] = _archive(v, ctx)
    end
    return out
end

function _archive_array(a::AbstractArray, ctx::ArchiveContext)
    if isbitstype(eltype(a)) || eltype(a) <: Union{AbstractString, Symbol, Nothing}
        return a
    end
    out = Dict{String, Any}("__container__" => "Array",
                            "size" => collect(size(a)))
    et = eltype(a)
    if _is_simple_concrete_type(et)
        name = _try_full_type_name(et)
        name === nothing || (out["eltype"] = name)
    end
    items = Vector{Any}(undef, length(a))
    for (i, v) in enumerate(a)
        items[i] = _archive(v, ctx)
    end
    out["items"] = items
    return out
end

function _archive_struct(value::T, ctx::ArchiveContext) where {T}
    _record_schema!(ctx, T)
    skip = get(ctx.spec.skip_fields, T, ())
    refs = get(ctx.spec.ref_fields, T, ())
    out = Dict{String, Any}(TYPE_KEY => _full_type_name(T))
    for name in fieldnames(T)
        name in skip && continue
        v = getfield(value, name)
        if name in refs && v isa Ref
            v = v[]
        end
        out[String(name)] = _archive(v, ctx)
    end
    return out
end

function _unsupported_archive_value(value, ctx::ArchiveContext)
    error("QSPKitIO archive $(ctx.spec.format) cannot persist value of type $(typeof(value)). " *
          "Register a named-field archive handler or strip/rebuild this runtime field; " *
          "opaque runtime payloads are unsupported.")
end

_restore(value, ctx::ArchiveContext) = _restore_dispatch(value, ctx)

function _restore_dispatch(value, ctx::ArchiveContext)
    if value isa AbstractDict
        if get(value, TYPE_KEY, nothing) isa AbstractString
            return _restore_struct(value, ctx)
        elseif get(value, OPAQUE_KEY, false) === true
            error("QSPKitIO archive $(ctx.spec.format) contains an opaque runtime payload. " *
                  "Legacy opaque payloads are unsupported; re-save from the current named-field archive path.")
        elseif haskey(value, "__container__")
            kind = value["__container__"]
            kind == "Dict" && return _restore_container_dict(value, ctx)
            kind == "NamedTuple" && return _restore_container_namedtuple(value, ctx)
            kind == "Tuple" && return _restore_container_tuple(value, ctx)
            kind == "Array" && return _restore_container_array(value, ctx)
            error("Unknown __container__ marker: $(kind)")
        else
            return Dict(k => _restore(v, ctx) for (k, v) in value)
        end
    elseif value isa NamedTuple
        return NamedTuple{keys(value)}(Tuple(_restore(v, ctx) for v in values(value)))
    elseif value isa Tuple
        return Tuple(_restore(v, ctx) for v in value)
    else
        return value
    end
end

function _restore_container_dict(env::AbstractDict, ctx::ArchiveContext)
    key_type = haskey(env, "key_type") ? _safe_resolve_type(env["key_type"]) : Any
    val_type = haskey(env, "value_type") ? _safe_resolve_type(env["value_type"]) : Any
    K = key_type === Any ? Any : key_type
    V = val_type === Any ? Any : val_type
    out = Dict{K, V}()
    for entry in env["entries"]
        k = _restore(entry["key"], ctx)
        v = _restore(entry["value"], ctx)
        out[K === Any ? k : convert(K, k)] = V === Any ? v : convert(V, v)
    end
    return out
end

function _restore_container_namedtuple(env::AbstractDict, ctx::ArchiveContext)
    names = Tuple(Symbol(n) for n in env["names"])
    values = Tuple(_restore(env[String(n)], ctx) for n in names)
    return NamedTuple{names}(values)
end

function _restore_container_tuple(env::AbstractDict, ctx::ArchiveContext)
    n = Int(env["n"])
    return Tuple(_restore(env[string(i)], ctx) for i in 1:n)
end

function _restore_container_array(env::AbstractDict, ctx::ArchiveContext)
    sz = Tuple(Int(s) for s in env["size"])
    raw = [_restore(v, ctx) for v in env["items"]]
    if haskey(env, "eltype")
        T = _safe_resolve_type(env["eltype"])
        if T !== Any
            typed = Vector{T}(undef, length(raw))
            for (i, v) in enumerate(raw)
                typed[i] = v
            end
            raw = typed
        end
    end
    return length(sz) == 1 ? raw : reshape(raw, sz)
end

function _safe_resolve_type(name::AbstractString)
    try
        return _resolve_type(name)
    catch
        return Any
    end
end

function _restore_struct(env::AbstractDict, ctx::ArchiveContext)
    type_name = env[TYPE_KEY]::AbstractString
    T = _resolve_type(type_name)
    handler = get(ctx.spec.restore_handlers, T, nothing)
    handler === nothing || return handler(T, env, ctx)
    return _generic_restore_struct(T, env, ctx)
end

function _generic_restore_struct(::Type{T}, env::AbstractDict, ctx::ArchiveContext) where {T}
    restored = Dict{Symbol, Any}()
    for (key, raw) in env
        key isa AbstractString || continue
        startswith(key, "__") && continue
        name = Symbol(key)
        v = _restore(raw, ctx)
        if name in get(ctx.spec.ref_fields, T, ()) && !(v isa Ref)
            v = Ref(v)
        end
        restored[name] = v
    end

    kw_names = _kwarg_constructor_names(T)
    if kw_names !== nothing
        kwargs = Pair{Symbol, Any}[]
        for k in kw_names
            haskey(restored, k) || continue
            push!(kwargs, k => restored[k])
        end
        return T(; kwargs...)
    end

    names = fieldnames(T)
    values = Vector{Any}(undef, length(names))
    for (i, name) in enumerate(names)
        v = haskey(restored, name) ? restored[name] : default_field(ctx, T, name)
        values[i] = _coerce_field(T, name, v)
    end
    return T(values...)
end

function _coerce_field(::Type{T}, name::Symbol, value) where {T}
    value === nothing && return value
    FT = fieldtype(T, name)
    FT === Any && return value
    value isa FT && return value
    return convert(FT, value)
end
"""Convert `value` to the declared field type `T.name` when necessary."""
coerce_field(::Type{T}, name::Symbol, value) where {T} =
    _coerce_field(T, name, value)

"""
    default_field(ctx, T, name)

Return the registered field-evolution default for `T.name`, evaluating it when
the default is a function. Errors if the `ArchiveSpec` has no such default.
"""
function default_field(ctx::ArchiveContext, ::Type{T}, name::Symbol) where {T}
    key = (T, name)
    if haskey(ctx.spec.default_fields, key)
        v = ctx.spec.default_fields[key]
        v isa Function && return v(T, Val(name))
        return v
    end
    error("Cannot restore $T from archive: required field :$name is missing " *
          "and no default is registered in ArchiveSpec.default_fields")
end

end # module QSPKitIO
