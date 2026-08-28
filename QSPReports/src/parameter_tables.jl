# Parameter catalog and overlay tables.

"""Stable `(section, name)` identity for one parameter-table row."""
struct ParameterRowKey
    section::Symbol
    name::Symbol
end

Base.:(==)(a::ParameterRowKey, b::ParameterRowKey) =
    a.section === b.section && a.name === b.name
Base.hash(k::ParameterRowKey, h::UInt) = hash(k.name, hash(k.section, h))

"""Construct a row key in the `parameters` section."""
parameter_key(name) = ParameterRowKey(:parameters, Symbol(name))

"""Construct a row key in the `initials` section."""
initial_key(name) = ParameterRowKey(:initials, Symbol(name))

"""Construct a row key in the `constants` section."""
constant_key(name) = ParameterRowKey(:constants, Symbol(name))

const _BASE_TABLE_COLUMNS = [
    :row_key, :section, :name, :display, :role,
    :keyfile_value, :keyfile_initial, :expression, :unit,
    :description, :description_source, :label, :abbr,
    :source, :source_source, :lower, :upper,
]

"""
    ParameterUpdate

Serializable parameter, initial-condition, and constant changes with a label,
optional source, and free-form metadata.
"""
struct ParameterUpdate
    parameters::Dict{Symbol, Any}
    initials::Dict{Symbol, Any}
    constants::Dict{Symbol, Any}
    label::Symbol
    source::Union{Nothing, String}
    metadata::Dict{Symbol, Any}
end

"""Report-table rows to merge under a shared overlay label."""
struct ParameterOverlay
    rows::Vector{NamedTuple}
    label::Symbol
end

function _symdict(x)
    out = Dict{Symbol, Any}()
    x === nothing && return out
    entries = x isa AbstractDict || x isa NamedTuple ? pairs(x) : x
    for entry in entries
        entry isa Pair || throw(ArgumentError(
            "Expected a dictionary, named tuple, or iterator of pairs; " *
            "got an entry of type $(typeof(entry))",
        ))
        out[Symbol(first(entry))] = last(entry)
    end
    return out
end

"""
    model_update(; parameters, initials, constants, label, source, metadata)

Create a normalized [`ParameterUpdate`](@ref) from dictionaries, named tuples,
or other pair iterators.
"""
function model_update(; parameters=(;), initials=(;), constants=(;),
        label::Symbol=:update, source=nothing, metadata=Dict{Symbol, Any}())
    ParameterUpdate(
        _symdict(parameters),
        _symdict(initials),
        _symdict(constants),
        Symbol(label),
        source === nothing ? nothing : String(source),
        _symdict(metadata),
    )
end

"""Alias for [`model_update`](@ref)."""
parameter_update(; kwargs...) = model_update(; kwargs...)
ParameterUpdate(; kwargs...) = model_update(; kwargs...)

function _named_values(values, names=nothing; transform=identity)
    if values isa AbstractDict || values isa NamedTuple
        return _symdict(values)
    end
    names === nothing && error("Vector-valued optimization results need `names=...`")
    raw_values = collect(values)
    raw_names = collect(names)
    length(raw_values) == length(raw_names) ||
        error("Optimization result has $(length(raw_values)) values but $(length(raw_names)) names")
    out = Dict{Symbol, Any}()
    for (name, value) in zip(raw_names, raw_values)
        out[Symbol(name)] = transform(value)
    end
    return out
end

function _result_field(result, field::Symbol, default=missing)
    try
        return getproperty(result, field)
    catch
        return default
    end
end

function _result_values(result; names=nothing, value_field=nothing, transform=identity)
    if value_field !== nothing
        values = _result_field(result, Symbol(value_field), missing)
        values === missing && error("Result has no field :$(Symbol(value_field))")
        return _named_values(values, names; transform)
    end

    result isa AbstractDict && return _named_values(result, names; transform)
    result isa NamedTuple && return _named_values(result, names; transform)
    result isa AbstractVector && return _named_values(result, names; transform)

    for field in (:params, :parameters, :estimates)
        values = _result_field(result, field, missing)
        values === missing || return _named_values(values, names; transform)
    end

    minimizer = _result_field(result, :minimizer, missing)
    minimizer === missing || return _named_values(minimizer, names; transform)

    error("Cannot extract parameter values from $(typeof(result)); pass a Dict/NamedTuple, " *
          "use `optimization_update(...; value_field=...)`, or provide an object with " *
          "`params`, `parameters`, `estimates`, or `minimizer`.")
end

"""
    optimization_update(result; names=nothing, section=:parameters, kwargs...)

Extract estimates from a dictionary, named tuple, vector, or fit-like object
and return a [`ParameterUpdate`](@ref). Vector results require `names`.
"""
function optimization_update(result; names=nothing, label::Symbol=:estimate,
        source=nothing, section::Symbol=:parameters, value_field=nothing,
        transform=identity, metadata=Dict{Symbol, Any}())
    values = _result_values(result; names, value_field, transform)
    if section === :parameters
        return model_update(; parameters=values, label, source, metadata)
    elseif section === :initials
        return model_update(; initials=values, label, source, metadata)
    elseif section === :constants
        return model_update(; constants=values, label, source, metadata)
    end
    error("optimization_update section must be :parameters, :initials, or :constants; got :$section")
end

function _value_from_yaml_entry(v)
    if v isa AbstractDict
        haskey(v, "value") && return v["value"]
        haskey(v, :value) && return v[:value]
    end
    return v
end

function _yaml_values(data, names...)
    for name in names
        haskey(data, name) && return _symdict(Dict(k => _value_from_yaml_entry(v) for (k, v) in data[name]))
    end
    return Dict{Symbol, Any}()
end

"""Write a [`ParameterUpdate`](@ref) as a YAML mapping and return `path`."""
function save_parameter_update(path::AbstractString, update::ParameterUpdate)
    data = Dict{String, Any}(
        "kind" => "parameter_update",
        "label" => string(update.label),
        "parameters" => Dict(string(k) => v for (k, v) in update.parameters),
        "initials" => Dict(string(k) => v for (k, v) in update.initials),
        "constants" => Dict(string(k) => v for (k, v) in update.constants),
        "metadata" => Dict(string(k) => v for (k, v) in update.metadata),
    )
    update.source === nothing || (data["source"] = update.source)
    YAML.write_file(path, data)
    return path
end

"""Load a YAML parameter update written by [`save_parameter_update`](@ref)."""
function load_parameter_update(path::AbstractString)
    data = YAML.load_file(path)
    data isa AbstractDict || error("Parameter update file must contain a mapping: $path")
    parameters = _yaml_values(data, "parameters", :parameters, "values", :values)
    initials = _yaml_values(data, "initials", :initials)
    constants = _yaml_values(data, "constants", :constants)
    metadata = haskey(data, "metadata") ? _symdict(data["metadata"]) :
        haskey(data, :metadata) ? _symdict(data[:metadata]) : Dict{Symbol, Any}()
    label = Symbol(get(data, "label", get(data, :label, :update)))
    source = get(data, "source", get(data, :source, nothing))
    return model_update(; parameters, initials, constants, label, source, metadata)
end

function _rowkey_string(section::Symbol, name::Symbol)
    return string(section, ":", name)
end

function _display_name(section::Symbol, name::Symbol)
    section === :initials && return "init[$name]"
    section === :constants && return "constant[$name]"
    return string(name)
end

function _row_key_from_string(s::AbstractString)
    if startswith(s, "init[") && endswith(s, "]")
        return initial_key(Symbol(s[6:end-1]))
    elseif startswith(s, "constant[") && endswith(s, "]")
        return constant_key(Symbol(s[10:end-1]))
    elseif occursin(":", s)
        parts = split(s, ":"; limit=2)
        return ParameterRowKey(Symbol(parts[1]), Symbol(parts[2]))
    end
    return Symbol(s)
end

function _metadata_key(k)
    k isa ParameterRowKey && return k
    k isa Symbol && return k
    k isa AbstractString && return _row_key_from_string(k)
    return k
end

function _named_metadata(v)
    if v isa NamedTuple
        return v
    elseif v isa AbstractDict
        items = collect(pairs(v))
        names = Tuple(Symbol(k) for (k, _) in items)
        values = Tuple(value for (_, value) in items)
        return NamedTuple{names}(values)
    end
    error("Metadata overlay entries must be NamedTuple or AbstractDict, got $(typeof(v))")
end

"""
    parameter_metadata_overlay(entries=Dict(); kwargs...)

Normalize metadata keyed by parameter names, display names, or
[`ParameterRowKey`](@ref) values into named-tuple entries.
"""
function parameter_metadata_overlay(entries::AbstractDict=Dict{Any, Any}(); kwargs...)
    out = Dict{Any, NamedTuple}()
    for (k, v) in entries
        out[_metadata_key(k)] = _named_metadata(v)
    end
    for (k, v) in kwargs
        out[_metadata_key(k)] = _named_metadata(v)
    end
    return out
end

"""Load and normalize a YAML parameter-metadata mapping."""
function load_parameter_metadata(path::AbstractString)
    data = YAML.load_file(path)
    data isa AbstractDict || error("Parameter metadata file must contain a mapping: $path")
    return parameter_metadata_overlay(data)
end

function _entry_field(entry, field::Symbol, default=missing)
    try
        return getproperty(entry, field)
    catch
        return default
    end
end

function _entry_metadata(entry)
    meta = _entry_field(entry, :metadata, Dict{Symbol, Any}())
    meta isa AbstractDict ? meta : Dict{Symbol, Any}()
end

function _meta(meta, key::Symbol, default=missing)
    haskey(meta, key) && return meta[key]
    skey = string(key)
    haskey(meta, skey) && return meta[skey]
    return default
end

function _entry_bounds(meta)
    bounds = _meta(meta, :bounds)
    if bounds === missing || bounds === nothing
        return missing, missing
    elseif bounds isa AbstractVector || bounds isa Tuple
        length(bounds) >= 2 || return missing, missing
        return bounds[1], bounds[2]
    end
    return missing, missing
end

function _unit_text(unit)
    unit === missing && return missing
    text = string(unit)
    isempty(text) ? missing : text
end

function _latex_identifier(value)
    text = replace(string(value),
        "\\" => "\\textbackslash{}", "_" => "\\_", "%" => "\\%",
        "#" => "\\#", "&" => "\\&", "{" => "\\{", "}" => "\\}",
        '$' => raw"\$")
    return "\\mathrm{" * text * "}"
end

function _latex_expr(value)
    value isa Number && return string(value)
    value isa Symbol && return value in (:pi, :π) ? "\\pi" : _latex_identifier(value)
    value isa QuoteNode && return _latex_expr(value.value)
    value isa Expr || return _latex_identifier(value)

    if value.head === :call
        op = value.args[1]
        args = value.args[2:end]
        if op === :/ && length(args) == 2
            return "\\frac{" * _latex_expr(args[1]) * "}{" * _latex_expr(args[2]) * "}"
        elseif op === :^ && length(args) == 2
            return "{" * _latex_expr(args[1]) * "}^{" * _latex_expr(args[2]) * "}"
        elseif op === :*
            return join(_latex_expr.(args), " \\cdot ")
        elseif op === :+
            return join(_latex_expr.(args), " + ")
        elseif op === :- && length(args) == 1
            return "-" * _latex_expr(only(args))
        elseif op === :-
            return join(_latex_expr.(args), " - ")
        end
        return _latex_identifier(op) * "\\left(" * join(_latex_expr.(args), ", ") * "\\right)"
    end
    return _latex_identifier(value)
end

function _latex_expression(value)
    text = string(value)
    startswith(text, '$') && endswith(text, '$') && return text
    parsed = Meta.parse(text)
    return "\$" * _latex_expr(parsed) * "\$"
end

function _is_expression_value(value, meta)
    _meta(meta, :expression, nothing) !== nothing && return true
    value isa AbstractString || return false
    parsed = try
        Meta.parse(value)
    catch
        return true
    end
    return !(parsed isa Number)
end

function _row_from_entry(section::Symbol, name::Symbol, entry)
    meta = _entry_metadata(entry)
    value = _entry_field(entry, :value)
    original = _entry_field(entry, :value_original, value)
    lower, upper = _entry_bounds(meta)
    desc = _meta(meta, :description)
    source = _meta(meta, :source)
    is_expr = _is_expression_value(original, meta)
    role = section === :parameters ?
        (is_expr ? :derived_parameter : :parameter) :
        section === :initials ? :initial_condition :
        section === :constants ? :constant : section
    return (
        row_key = _rowkey_string(section, name),
        section = section,
        name = name,
        display = _display_name(section, name),
        role = role,
        keyfile_value = section === :parameters ? (is_expr ? original : value) : missing,
        keyfile_initial = section === :initials ? value : missing,
        expression = is_expr ? original : missing,
        unit = _unit_text(_meta(meta, :unit_original, _entry_field(entry, :unit))),
        description = desc,
        description_source = ismissing(desc) ? missing : :keyfile,
        label = _meta(meta, :label),
        abbr = _meta(meta, :abbr),
        source = source,
        source_source = ismissing(source) ? missing : :keyfile,
        lower = lower,
        upper = upper,
    )
end

function _section_set(sections)
    sections === :all && return Set([:parameters, :initials, :constants])
    sections isa Symbol && return Set([sections])
    return Set(Symbol.(collect(sections)))
end

function _has_field(x, field::Symbol)
    try
        getproperty(x, field)
        return true
    catch
        return false
    end
end

function _append_section_rows!(rows, kf, view_name::Symbol, section::Symbol)
    _has_field(kf, view_name) || return rows
    view = getproperty(kf, view_name)
    for (name, entry) in view
        push!(rows, _row_from_entry(section, Symbol(name), entry))
    end
    return rows
end

function _base_parameter_table(kf; sections=:all)
    wanted = _section_set(sections)
    rows = NamedTuple[]
    :parameters in wanted && _append_section_rows!(rows, kf, :Parameters, :parameters)
    :initials in wanted && _append_section_rows!(rows, kf, :Variables, :initials)
    :constants in wanted && _append_section_rows!(rows, kf, :Constants, :constants)
    df = isempty(rows) ? DataFrame([col => Any[] for col in _BASE_TABLE_COLUMNS]...) : DataFrame(rows)
    return df
end

function _find_row(df::DataFrame, section, name)
    target_name = Symbol(name)
    if section !== nothing
        target_section = Symbol(section)
        idx = findfirst(i -> df.section[i] === target_section && df.name[i] === target_name, axes(df, 1))
        idx === nothing || return idx
    end
    matches = findall(i -> df.name[i] === target_name || df.display[i] == string(name), axes(df, 1))
    return length(matches) == 1 ? only(matches) : nothing
end

function _ensure_column!(df::DataFrame, col::Symbol)
    if !(col in propertynames(df))
        df[!, col] = Any[missing for _ in axes(df, 1)]
    elseif eltype(df[!, col]) === Missing
        df[!, col] = Any[df[i, col] for i in axes(df, 1)]
    end
    return df
end

function _set_table_value!(df::DataFrame, row::Integer, col::Symbol, value)
    _ensure_column!(df, col)
    try
        df[row, col] = value
    catch err
        df[!, col] = Any[df[i, col] for i in axes(df, 1)]
        df[row, col] = value
    end
    return df
end

function _lookup_metadata(metadata, section::Symbol, name::Symbol, display)
    metadata === nothing && return nothing
    exact = ParameterRowKey(section, name)
    haskey(metadata, exact) && return metadata[exact]
    haskey(metadata, name) && return metadata[name]
    haskey(metadata, string(name)) && return metadata[string(name)]
    haskey(metadata, Symbol(display)) && return metadata[Symbol(display)]
    haskey(metadata, display) && return metadata[display]
    return nothing
end

function _should_replace(existing, value, policy::Symbol)
    policy === :prefer_overlay && return true
    policy === :fill_missing && return ismissing(existing) || existing === nothing || existing == ""
    policy === :error_on_conflict &&
        !(ismissing(existing) || existing === nothing || existing == "" || existing == value) &&
        error("Metadata overlay conflict: existing=$existing overlay=$value")
    return policy === :error_on_conflict
end

function _validate_metadata_policy(policy::Symbol)
    policy in (:prefer_overlay, :fill_missing, :error_on_conflict) ||
        throw(ArgumentError(
            "metadata_policy must be :prefer_overlay, :fill_missing, or " *
            ":error_on_conflict; got :$policy",
        ))
    return policy
end

function _apply_metadata!(df::DataFrame, metadata; metadata_policy::Symbol=:prefer_overlay)
    metadata === nothing && return df
    for i in axes(df, 1)
        row_meta = _lookup_metadata(metadata, df.section[i], df.name[i], df.display[i])
        row_meta === nothing && continue
        for (field, value) in pairs(row_meta)
            col = Symbol(field)
            _ensure_column!(df, col)
            _should_replace(df[i, col], value, metadata_policy) || continue
            _set_table_value!(df, i, col, value)
            if col === :description
                _set_table_value!(df, i, :description_source, :overlay)
            elseif col === :source
                _set_table_value!(df, i, :source_source, :overlay)
            end
        end
    end
    return df
end

function _parameter_table(kf; metadata=nothing, sections=:all,
        metadata_policy::Symbol=:prefer_overlay, latex::Bool=true)
    _validate_metadata_policy(metadata_policy)
    df = _base_parameter_table(kf; sections)
    _apply_metadata!(df, metadata; metadata_policy)
    if latex
        for i in axes(df, 1)
            df.role[i] === :derived_parameter || continue
            ismissing(df.expression[i]) && continue
            formatted = _latex_expression(df.expression[i])
            _set_table_value!(df, i, :keyfile_value, formatted)
        end
    end
    return df
end

"""
    parameter_table(keyfile; metadata=nothing, sections=:all, latex=true, kwargs...)

Build a report-ready `DataFrame` from a ConfigKit keyfile-like object. Overloads
accept parameter updates, overlays, fit-like results, and variant keyfile paths.
The `unit` column retains the spelling from the keyfile when available. Derived
values in `keyfile_value` are rendered as math-mode LaTeX by default, while
`expression` always preserves the original keyfile text. Pass `latex=false` to
keep `keyfile_value` as plain text.
"""
function parameter_table(kf; metadata=nothing, sections=:all,
        metadata_policy::Symbol=:prefer_overlay, latex::Bool=true)
    _parameter_table(kf; metadata, sections, metadata_policy, latex)
end

function parameter_table(kf::ConfigKit.KeyfileAccessor; metadata=nothing,
        sections=nothing, metadata_policy::Symbol=:prefer_overlay,
        latex::Bool=true, variants=nothing, names=nothing,
        only_different::Bool=true, wide::Bool=false)
    if isnothing(variants) && isnothing(names) && !wide
        base_sections = isnothing(sections) ? :all : sections
        return _parameter_table(
            kf;
            metadata,
            sections=base_sections,
            metadata_policy,
            latex,
        )
    end
    variant_sections = isnothing(sections) ? :parameters : sections
    return parameter_table(
        kf.source_path;
        metadata,
        sections=variant_sections,
        metadata_policy,
        latex,
        variants,
        names,
        only_different,
        wide,
    )
end

function _row_namedtuple(section::Symbol, name::Symbol, fields::NamedTuple)
    merge((section=section, name=name), fields)
end

"""
    parameter_overlay(values; section=:parameters, label=:value, column=nothing)

Create a [`ParameterOverlay`](@ref) from named values or a fit-like result.
"""
function parameter_overlay(values::AbstractDict; section::Symbol=:parameters,
        label::Symbol=:value, column::Union{Nothing, Symbol}=nothing)
    col = something(column, Symbol(label, "_value"))
    rows = NamedTuple[]
    for (name, value) in values
        push!(rows, _row_namedtuple(section, Symbol(name), NamedTuple{(col, :value_source)}((value, label))))
    end
    return ParameterOverlay(rows, label)
end

parameter_overlay(values::NamedTuple; kwargs...) = parameter_overlay(Dict(pairs(values)); kwargs...)

function parameter_overlay(result; names=nothing, section::Symbol=:parameters,
        label::Symbol=:estimate, column::Union{Nothing, Symbol}=nothing,
        value_field=nothing, transform=identity)
    values = _result_values(result; names, value_field, transform)
    return parameter_overlay(values; section, label, column)
end

function _overlay_from_update(update::ParameterUpdate; label::Symbol=update.label)
    col = Symbol(label, "_value")
    value_source = update.source === nothing ? label : update.source
    rows = NamedTuple[]
    for (name, value) in update.parameters
        push!(rows, _row_namedtuple(:parameters, name, NamedTuple{(col, :value_source)}((value, value_source))))
    end
    for (name, value) in update.initials
        push!(rows, _row_namedtuple(:initials, name, NamedTuple{(col, :value_source)}((value, value_source))))
    end
    for (name, value) in update.constants
        push!(rows, _row_namedtuple(:constants, name, NamedTuple{(col, :value_source)}((value, value_source))))
    end
    return ParameterOverlay(rows, label)
end

function _blank_row(section::Symbol, name::Symbol; role=section)
    return Dict{Symbol, Any}(
        :row_key => _rowkey_string(section, name),
        :section => section,
        :name => name,
        :display => _display_name(section, name),
        :role => role,
        :keyfile_value => missing,
        :keyfile_initial => missing,
        :expression => missing,
        :unit => missing,
        :description => missing,
        :description_source => missing,
        :label => missing,
        :abbr => missing,
        :source => missing,
        :source_source => missing,
        :lower => missing,
        :upper => missing,
    )
end

function _append_overlay_row!(df::DataFrame, row)
    section = hasproperty(row, :section) ? Symbol(row.section) : :parameters
    name = Symbol(row.name)
    role = hasproperty(row, :role) ? Symbol(row.role) : section
    newrow = _blank_row(section, name; role)
    for (field, value) in pairs(row)
        field in (:section, :name) && continue
        newrow[Symbol(field)] = value
    end
    push!(df, newrow; cols=:union)
    return df
end

function _merge_overlay!(df::DataFrame, overlay::ParameterOverlay; unmatched::Symbol=:append)
    unmatched in (:append, :drop, :warn, :error) ||
        throw(ArgumentError("unmatched must be :append, :drop, :warn, or :error"))
    for row in overlay.rows
        hasproperty(row, :name) || error("ParameterOverlay rows must have a :name field")
        section = hasproperty(row, :section) ? Symbol(row.section) : nothing
        idx = _find_row(df, section, row.name)
        if idx === nothing
            if unmatched === :append
                _append_overlay_row!(df, row)
            elseif unmatched === :warn
                @warn "Dropping unmatched parameter overlay row" name=row.name section=section
            elseif unmatched === :error
                error("Unmatched parameter overlay row: $(row.name)")
            end
            continue
        end
        for (field, value) in pairs(row)
            field in (:section, :name) && continue
            _set_table_value!(df, idx, Symbol(field), value)
        end
    end
    return df
end

function parameter_table(kf, overlay::ParameterOverlay; metadata=nothing, sections=:all,
        metadata_policy::Symbol=:prefer_overlay, unmatched::Symbol=:append,
        latex::Bool=true)
    df = parameter_table(kf; metadata, sections, metadata_policy, latex)
    _merge_overlay!(df, overlay; unmatched)
    _apply_metadata!(df, metadata; metadata_policy)
    return df
end

function parameter_table(kf, update::ParameterUpdate; metadata=nothing, sections=:all,
        metadata_policy::Symbol=:prefer_overlay, unmatched::Symbol=:append,
        overlay_name::Symbol=update.label, latex::Bool=true)
    parameter_table(kf, _overlay_from_update(update; label=overlay_name);
        metadata, sections, metadata_policy, unmatched, latex)
end

function parameter_table(kf, values::AbstractDict; metadata=nothing, sections=:all,
        metadata_policy::Symbol=:prefer_overlay, unmatched::Symbol=:append,
        overlay_name::Symbol=:updated, section::Symbol=:parameters, latex::Bool=true)
    parameter_table(kf, parameter_overlay(values; section, label=overlay_name);
        metadata, sections, metadata_policy, unmatched, latex)
end

function parameter_table(kf, values::NamedTuple; kwargs...)
    parameter_table(kf, Dict(pairs(values)); kwargs...)
end

function parameter_table(kf, result; metadata=nothing, sections=:all,
        metadata_policy::Symbol=:prefer_overlay, unmatched::Symbol=:append,
        overlay_name::Symbol=:estimate, section::Symbol=:parameters,
        names=nothing, value_field=nothing, transform=identity, latex::Bool=true)
    overlay = parameter_overlay(result; names, section, label=overlay_name,
        value_field, transform)
    return parameter_table(kf, overlay; metadata, sections, metadata_policy, unmatched, latex)
end

"""
    parameter_table(source::AbstractString; variants=nothing, names=nothing,
        only_different=true, wide=false, latex=true)

Build a long-form report table comparing parameter values across keyfile
variants. Each row contains `name`, `variant`, `value`, `unit`, `description`,
and the resolved `source` metadata. By default, only parameters whose values
differ across the selected variants are returned.

`source` must be a ConfigKit keyfile path. When `variants=nothing`, all variants
reported by `ConfigKit.list_available_variants(source)` are compared. Use
`names` to restrict the comparison to selected parameters and
`only_different=false` to retain selected parameters with identical values.
With `wide=true`, return one row per parameter with `<variant>_value` and
`<variant>_source` columns. Wide output requires `unit` and `description` to be
consistent across the selected variants.

# Example
```julia
parameter_table(
    "synthetic-profiles.yml";
    names=[:mixing_weight, :branch_count],
)
```
"""
function parameter_table(source::AbstractString; variants=nothing,
        names=nothing, only_different::Bool=true, latex::Bool=true,
        metadata=nothing, sections=:parameters,
        metadata_policy::Symbol=:prefer_overlay, wide::Bool=false)
    _section_set(sections) == Set([:parameters]) || throw(ArgumentError(
        "variant parameter tables currently support sections=:parameters only",
    ))
    selected_variants = if isnothing(variants)
        sort!(collect(ConfigKit.list_available_variants(String(source))); by=string)
    else
        Symbol.(collect(variants))
    end
    length(selected_variants) >= 2 || throw(ArgumentError(
        "parameter_table with variants requires at least two variants",
    ))
    length(unique(selected_variants)) == length(selected_variants) ||
        throw(ArgumentError("variants must be unique"))

    selected_names = isnothing(names) ? nothing : Set(Symbol.(collect(names)))
    frames = DataFrame[]
    for (variant_index, variant) in enumerate(selected_variants)
        kf = ConfigKit.load_keyfile(String(source); variant)
        table = _parameter_table(
            kf;
            metadata,
            sections=:parameters,
            metadata_policy,
            latex=false,
        )
        if !isnothing(selected_names)
            filter!(:name => in(selected_names), table)
        end

        frame = select(
            table,
            :name,
            :keyfile_value => :value,
            :expression,
            :role,
            :unit,
            :description,
            :source,
        )
        frame.variant = fill(variant, nrow(frame))
        frame._variant_order = fill(variant_index, nrow(frame))
        frame._comparison_value = copy(frame.value)
        if latex
            for i in axes(frame, 1)
                frame.role[i] === :derived_parameter || continue
                ismissing(frame.expression[i]) && continue
                _set_table_value!(frame, i, :value,
                                  _latex_expression(frame.expression[i]))
            end
        end
        push!(frames, frame)
    end

    table = reduce((a, b) -> vcat(a, b; cols=:union), frames)
    if only_different
        varying_names = Set(
            group.name[1]
            for group in groupby(table, :name)
            if length(unique(group._comparison_value)) > 1
        )
        filter!(:name => in(varying_names), table)
    end

    sort!(table, [:name, :_variant_order])
    table = select(table, :name, :variant, :value, :unit, :description, :source)
    return wide ? _wide_variant_parameter_table(table, selected_variants) : table
end

function _common_variant_metadata(group, column::Symbol)
    values = unique(collect(skipmissing(group[!, column])))
    length(values) <= 1 || throw(ArgumentError(
        "Cannot create a wide variant parameter table because $(group.name[1]) " *
        "has different $column values across variants",
    ))
    return isempty(values) ? missing : only(values)
end

function _wide_variant_parameter_table(table::DataFrame, variants)
    if isempty(table)
        result = DataFrame(name=Symbol[], unit=Any[], description=Any[])
        for variant in variants
            result[!, Symbol(variant, "_value")] = Any[]
            result[!, Symbol(variant, "_source")] = Any[]
        end
        return result
    end

    rows = NamedTuple[]
    for group in groupby(table, :name; sort=false)
        fields = Pair{Symbol, Any}[
            :name => group.name[1],
            :unit => _common_variant_metadata(group, :unit),
            :description => _common_variant_metadata(group, :description),
        ]
        for variant in variants
            index = findfirst(==(variant), group.variant)
            value = isnothing(index) ? missing : group.value[index]
            source = isnothing(index) ? missing : group.source[index]
            push!(fields, Symbol(variant, "_value") => value)
            push!(fields, Symbol(variant, "_source") => source)
        end
        push!(rows, (; fields...))
    end
    return DataFrame(rows)
end
