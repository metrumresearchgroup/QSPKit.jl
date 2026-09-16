# ============================================================
# RCall Backend — parse yspec via real R yspec package
# Uses runtime-resolved _rcopy/_reval wrappers
# ============================================================

"""
    parse_yspec_rcall(path::AbstractString) -> YspecMetadata

Parse a yspec YAML file using the real yspec R package via RCall (through CondaR).
"""
function parse_yspec_rcall(path::AbstractString)
    return lock(_SPEC_R_LOCK) do
    r_available() || error("RCall backend not available")

    _reval(".__yspec_tmp__ <- yspec::ys_load('$(escape_string(path))')")

    attrs = _rcopy(_reval("attributes(.__yspec_tmp__)"))

    description = get(attrs, "description", nothing)
    sponsor = get(attrs, "sponsor", nothing)
    projectnumber = get(attrs, "projectnumber", nothing)
    data_stem = get(attrs, "data_stem", nothing)
    data_path = get(attrs, "data_path", nothing)

    flags_raw = get(attrs, "flags", Dict())
    flags = Dict{Symbol, Vector{Symbol}}()
    if flags_raw isa AbstractDict
        for (k, v) in flags_raw
            flags[Symbol(k)] = Symbol.(v isa Vector ? v : [v])
        end
    end

    glue_raw = get(attrs, "glue", Dict())
    glue = if glue_raw isa AbstractDict
        Dict{String, String}(string(k) => string(v) for (k, v) in glue_raw)
    else
        Dict{String, String}()
    end

    lookup_files = _to_string_vector(get(attrs, "lookup_file", String[]))
    extend_files = _to_string_vector(get(attrs, "extend_file", String[]))

    columns = OrderedDict{Symbol, ColumnSpec}()
    col_names_r = _rcopy(Vector{String}, _reval("names(.__yspec_tmp__)"))

    for col_name in col_names_r
        name = Symbol(col_name)
        col_r = _rcopy(_reval("as.list(.__yspec_tmp__[['$(col_name)']])"))

        short = get(col_r, "short", nothing)
        label = get(col_r, "label", nothing)
        long = get(col_r, "long", nothing)
        unit = get(col_r, "unit", nothing)
        col_type = Symbol(get(col_r, "type", "numeric"))
        source = get(col_r, "source", nothing)
        comment = get(col_r, "comment", nothing)

        range_val = get(col_r, "range", nothing)
        range_tuple = if range_val isa Vector && length(range_val) == 2
            (Float64(range_val[1]), Float64(range_val[2]))
        else
            nothing
        end

        values_raw = get(col_r, "values", nothing)
        decode_raw = get(col_r, "decode", nothing)
        values = _parse_values(values_raw, decode_raw)

        dots_raw = get(col_r, "dots", nothing)
        dots = _parse_dots(dots_raw)

        namespaces = Dict{String, Dict{Symbol, String}}()
        if col_r isa AbstractDict
            for (field_key, field_val) in col_r
                fk = string(field_key)
                if contains(fk, ".")
                    parts = split(fk, ".", limit=2)
                    field = Symbol(parts[1])
                    ns_name = parts[2]
                    ns_dict = get!(namespaces, ns_name, Dict{Symbol, String}())
                    ns_dict[field] = string(field_val)
                end
            end
        end

        from_lookup = get(col_r, "lookup", false) isa Bool ? get(col_r, "lookup", false) : true

        columns[name] = ColumnSpec(name;
            short = isnothing(short) ? nothing : string(short),
            label = isnothing(label) ? nothing : string(label),
            long = isnothing(long) ? nothing : string(long),
            unit = isnothing(unit) ? nothing : string(unit),
            type = col_type,
            range = range_tuple,
            values = values,
            source = isnothing(source) ? nothing : string(source),
            comment = isnothing(comment) ? nothing : string(comment),
            dots = dots,
            namespaces = namespaces,
            from_lookup = from_lookup,
        )
    end

    _reval("rm(.__yspec_tmp__)")

    return YspecMetadata(;
        description = isnothing(description) ? nothing : string(description),
        sponsor = isnothing(sponsor) ? nothing : string(sponsor),
        projectnumber = isnothing(projectnumber) ? nothing : string(projectnumber),
        data_stem = isnothing(data_stem) ? nothing : string(data_stem),
        data_path = isnothing(data_path) ? nothing : string(data_path),
        columns, flags, glue, lookup_files, extend_files,
    )
    end
end

"""
    validate_yspec_rcall(data, spec_path::AbstractString) -> Bool

Validate a DataFrame against a yspec file using R's ys_check().
Returns true if validation passes, throws on failure.
"""
function validate_yspec_rcall(data, spec_path::AbstractString)
    return lock(_SPEC_R_LOCK) do
    r_available() || error("RCall backend not available for validation")

    result = _rcopy(Bool, _reval("""
        spec <- yspec::ys_load('$(escape_string(spec_path))')
        tryCatch({
            yspec::ys_check(data, spec)
            TRUE
        }, error = function(e) {
            message(e\$message)
            FALSE
        })
    """))

    result || error("yspec validation failed. Check R messages for details.")
    return true
    end
end
