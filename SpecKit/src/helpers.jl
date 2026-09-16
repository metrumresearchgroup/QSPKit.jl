# ============================================================
# Helpers — namespace, decodes, lookup_source
# ============================================================

"""
    namespace(metadata::YspecMetadata, ns::AbstractString) -> YspecMetadata

Return a new YspecMetadata with fields switched to the given namespace.
E.g., `namespace(meta, "tex")` replaces `unit` with `unit.tex` values where defined.
"""
function namespace(metadata::YspecMetadata, ns::AbstractString)
    _apply_namespace(metadata, String(ns))
end

function _apply_namespace(metadata::YspecMetadata, ns::String)
    new_columns = OrderedDict{Symbol, ColumnSpec}()
    for (name, col) in metadata.columns
        if haskey(col.namespaces, ns)
            ns_overrides = col.namespaces[ns]
            new_col = ColumnSpec(name;
                short = get(ns_overrides, :short, col.short),
                label = get(ns_overrides, :label, col.label),
                long = get(ns_overrides, :long, col.long),
                unit = get(ns_overrides, :unit, col.unit),
                type = col.type,
                range = col.range,
                values = col.values,
                source = col.source,
                comment = get(ns_overrides, :comment, col.comment),
                dots = col.dots,
                namespaces = col.namespaces,
                from_lookup = col.from_lookup,
            )
            new_columns[name] = new_col
        else
            new_columns[name] = col
        end
    end
    YspecMetadata(;
        description = metadata.description,
        sponsor = metadata.sponsor,
        projectnumber = metadata.projectnumber,
        data_stem = metadata.data_stem,
        data_path = metadata.data_path,
        columns = new_columns,
        flags = metadata.flags,
        glue = metadata.glue,
        lookup_files = metadata.lookup_files,
        extend_files = metadata.extend_files,
    )
end

"""
    decodes(metadata::YspecMetadata, col::Symbol) -> Dict

Get the decode map for a column from yspec metadata.
Returns Dict mapping code → label.
"""
function decodes(metadata::YspecMetadata, col::Symbol)
    haskey(metadata.columns, col) || error("Unknown column: :$col")
    col_spec = metadata.columns[col]
    isnothing(col_spec.values) && return Dict()

    if col_spec.values isa Dict
        return col_spec.values
    else
        return Dict(v => v for v in col_spec.values)
    end
end

"""
    lookup_source(metadata::YspecMetadata) -> Vector{NamedTuple}

Audit provenance: show where each column's definition came from.
Returns a vector of named tuples with column metadata.
"""
function lookup_source(metadata::YspecMetadata)
    rows = NamedTuple[]
    for (name, col) in metadata.columns
        push!(rows, (
            column = name,
            from_lookup = col.from_lookup,
            has_short = !isnothing(col.short),
            has_unit = !isnothing(col.unit),
            has_values = !isnothing(col.values),
            has_range = !isnothing(col.range),
        ))
    end
    rows
end
