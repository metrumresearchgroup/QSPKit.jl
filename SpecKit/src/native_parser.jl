# ============================================================
# Native Backend — parse yspec YAML using YAML.jl
# ============================================================

"""
    parse_yspec_native(path::AbstractString) -> YspecMetadata

Parse a yspec YAML file into a YspecMetadata struct using the native Julia parser.
Handles SETUP__ block, per-column blocks, lookup_file, extend_file, glue, namespaces.
"""
function parse_yspec_native(path::AbstractString)
    raw = YAML.load_file(path; dicttype=OrderedDict{String, Any})
    dir = dirname(abspath(path))

    # Extract SETUP__ block
    setup = get(raw, "SETUP__", Dict{String, Any}())

    # Parse SETUP__ fields
    description = get(setup, "description", nothing)
    sponsor = get(setup, "sponsor", nothing)
    projectnumber = get(setup, "projectnumber", nothing)
    data_stem = get(setup, "data_stem", nothing)
    data_path = get(setup, "data_path", nothing)

    glue = Dict{String, String}(
        string(k) => string(v)
        for (k, v) in get(setup, "glue", Dict())
    )

    flags = Dict{Symbol, Vector{Symbol}}(
        Symbol(k) => Symbol.(v)
        for (k, v) in get(setup, "flags", Dict())
    )

    lookup_files = _to_string_vector(get(setup, "lookup_file", String[]))
    extend_files = _to_string_vector(get(setup, "extend_file", String[]))

    # Load lookup definitions
    lookup_defs = OrderedDict{Symbol, Dict{String, Any}}()
    for lf in lookup_files
        lf_path = isabspath(lf) ? lf : joinpath(dir, lf)
        isfile(lf_path) || continue
        lf_raw = YAML.load_file(lf_path; dicttype=OrderedDict{String, Any})
        for (k, v) in lf_raw
            k == "SETUP__" && continue
            lookup_defs[Symbol(k)] = v isa AbstractDict ? v : Dict{String, Any}()
        end
    end

    # Parse per-column blocks
    columns = OrderedDict{Symbol, ColumnSpec}()
    for (key, val) in raw
        key == "SETUP__" && continue
        name = Symbol(key)
        col_raw = val isa AbstractDict ? val : Dict{String, Any}()

        # Resolve lookup: if column has "lookup: true" or was tagged with !look
        from_lookup = false
        if _is_lookup(col_raw) && haskey(lookup_defs, name)
            col_raw = merge(lookup_defs[name], col_raw)
            from_lookup = true
        elseif haskey(col_raw, "lookup")
            lookup_name = col_raw["lookup"]
            if lookup_name isa Bool && lookup_name
                lookup_src = name
            else
                lookup_src = Symbol(lookup_name)
            end
            if haskey(lookup_defs, lookup_src)
                col_raw = merge(lookup_defs[lookup_src], col_raw)
                from_lookup = true
            end
            delete!(col_raw, "lookup")
        elseif isempty(col_raw) && haskey(lookup_defs, name)
            # Empty entry auto-resolves from lookup
            col_raw = lookup_defs[name]
            from_lookup = true
        end

        # Apply glue interpolation
        col_raw = _apply_glue(col_raw, glue)

        # Parse about shorthand: about: [short, unit]
        if haskey(col_raw, "about")
            about = col_raw["about"]
            if about isa Vector && length(about) >= 2
                !haskey(col_raw, "short") && (col_raw["short"] = string(about[1]))
                !haskey(col_raw, "unit") && (col_raw["unit"] = string(about[2]))
            end
        end

        # Extract namespace fields (e.g., "unit.tex" -> namespaces["tex"][:unit])
        namespaces = Dict{String, Dict{Symbol, String}}()
        ns_keys = filter(k -> contains(string(k), "."), collect(keys(col_raw)))
        for ns_key in ns_keys
            parts = split(string(ns_key), ".", limit=2)
            field = Symbol(parts[1])
            ns_name = parts[2]
            ns_dict = get!(namespaces, ns_name, Dict{Symbol, String}())
            ns_dict[field] = _apply_glue_string(string(col_raw[ns_key]), glue)
        end

        # Parse values/decode
        values = _parse_values(get(col_raw, "values", nothing), get(col_raw, "decode", nothing))

        # Parse range
        range_val = get(col_raw, "range", nothing)
        range_tuple = if range_val isa Vector && length(range_val) == 2
            (Float64(range_val[1]), Float64(range_val[2]))
        else
            nothing
        end

        columns[name] = ColumnSpec(name;
            short = _get_str(col_raw, "short"),
            label = _get_str(col_raw, "label"),
            long = _get_str(col_raw, "long"),
            unit = _get_str(col_raw, "unit"),
            type = Symbol(get(col_raw, "type", "numeric")),
            range = range_tuple,
            values = values,
            source = _get_str(col_raw, "source"),
            comment = _get_str(col_raw, "comment"),
            dots = _parse_dots(get(col_raw, "dots", nothing)),
            namespaces = namespaces,
            from_lookup = from_lookup,
        )
    end

    # Process extend_files
    for ef in extend_files
        ef_path = isabspath(ef) ? ef : joinpath(dir, ef)
        isfile(ef_path) || continue
        ext_meta = parse_yspec_native(ef_path)
        for (name, col) in ext_meta.columns
            columns[name] = col
        end
    end

    # Inject flags into dots
    for (flag_name, flag_cols) in flags
        for col_name in flag_cols
            if haskey(columns, col_name)
                columns[col_name].dots[flag_name] = true
            end
        end
    end

    return YspecMetadata(;
        description, sponsor, projectnumber,
        data_stem, data_path,
        columns, flags, glue,
        lookup_files, extend_files,
    )
end

# ============================================================
# Helpers
# ============================================================

_to_string_vector(x::String) = [x]
_to_string_vector(x::Vector) = string.(x)
_to_string_vector(x) = String[]

function _get_str(d::AbstractDict, key::String)
    v = get(d, key, nothing)
    isnothing(v) ? nothing : string(v)
end

function _is_lookup(d::AbstractDict)
    haskey(d, "__tag__") && d["__tag__"] == "!look"
end

"""
Parse yspec values/decode into a standardized form.

yspec supports multiple syntaxes:
- `values: [1, 2, 3]` → Vector
- `values: {decode: value, ...}` → Dict{Symbol, Any} (decode → value)
- `values: !value:decode {value: decode, ...}` → Dict{Symbol, Any} (value → decode, reversed)
- `values: [...]` + `decode: [...]` → Dict{Symbol, Any} (parallel arrays)
"""
function _parse_values(values, decode)
    isnothing(values) && return nothing

    if values isa Vector
        if !isnothing(decode) && decode isa Vector && length(decode) == length(values)
            # Parallel arrays: values[i] is the code, decode[i] is the label
            return Dict{Any, Any}(values[i] => decode[i] for i in eachindex(values))
        end
        return values
    end

    if values isa AbstractDict
        # yspec default: {decode_label: code_in_data}
        # Convert to Dict with both directions accessible
        return Dict{Any, Any}(v => k for (k, v) in values)
    end

    return nothing
end

function _parse_dots(dots)
    isnothing(dots) && return Dict{Symbol, Any}()
    !(dots isa AbstractDict) && return Dict{Symbol, Any}()
    Dict{Symbol, Any}(Symbol(k) => v for (k, v) in dots)
end

"""Apply glue interpolation to all string values in a dict."""
function _apply_glue(d::AbstractDict, glue::Dict{String, String})
    isempty(glue) && return d
    result = Dict{String, Any}()
    for (k, v) in d
        result[string(k)] = if v isa String
            _apply_glue_string(v, glue)
        else
            v
        end
    end
    return result
end

"""Replace <<varname>> patterns with glue definitions."""
function _apply_glue_string(s::String, glue::Dict{String, String})
    isempty(glue) && return s
    for (name, replacement) in glue
        s = replace(s, "<<$(name)>>" => replacement)
    end
    return s
end
