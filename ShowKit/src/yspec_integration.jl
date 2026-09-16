# ============================================================
# SpecKit Integration — axis_col_labs, col_label
# ============================================================
# Duck-typed: works with any object that has .columns dict
# where entries have .short, .label, .unit fields (YspecMetadata).

"""
    axis_col_labs(spec, cols::Vector{Symbol}) -> Dict{Symbol, String}

Generate pmplots-style `"COL//Label [unit]"` strings from yspec metadata.

# Example
```julia
spec = load_yspec("data_spec.yml")
labs = axis_col_labs(spec, [:DV, :PRED, :TIME])
dv_pred(df; x=labs[:PRED], y=labs[:DV])
```
"""
function axis_col_labs(spec, cols::Vector{Symbol})
    result = Dict{Symbol, String}()
    columns = spec.columns
    for col in cols
        haskey(columns, col) || continue
        result[col] = _col_label_string(col, columns[col])
    end
    result
end

"""
    axis_col_labs(spec) -> Dict{Symbol, String}

Generate `"COL//Label [unit]"` strings for all columns in the spec.
"""
function axis_col_labs(spec)
    axis_col_labs(spec, collect(keys(spec.columns)))
end

"""
    col_label(spec, col::Symbol) -> String

Get a display label `"Label [unit]"` for a single column from yspec metadata.
"""
function col_label(spec, col::Symbol)
    columns = spec.columns
    haskey(columns, col) || return string(col)
    cs = columns[col]
    label = something(cs.short, cs.label, string(col))
    unit_str = isnothing(cs.unit) ? "" : " [$(cs.unit)]"
    "$(label)$(unit_str)"
end

# Internal: build "COL//Label [unit]" string
function _col_label_string(col::Symbol, cs)
    label = something(cs.short, cs.label, string(col))
    unit_str = isnothing(cs.unit) ? "" : " [$(cs.unit)]"
    "$(col)//$(label)$(unit_str)"
end

"""
    ys_factors(data::DataFrame, spec, cols::Vector{Symbol}) -> DataFrame
    ys_factors!(data::DataFrame, spec, cols::Vector{Symbol}) -> DataFrame

Decode yspec `values` / `decode` columns for plotting.
"""
function ys_factors(data::DataFrame, spec, cols::Vector{Symbol})
    out = copy(data)
    ys_factors!(out, spec, cols)
end

ys_factors(data::DataFrame, spec, cols::Symbol...) =
    ys_factors(data, spec, collect(cols))

function ys_factors!(data::DataFrame, spec, cols::Vector{Symbol})
    for col in cols
        col in Symbol.(names(data)) || continue
        haskey(spec.columns, col) || continue
        mapping = spec.columns[col].values
        (mapping isa Dict && !isempty(mapping)) || continue
        data[!, col] = [
            ismissing(value) ? missing : string(_ys_decode_value(mapping, value))
            for value in data[!, col]
        ]
    end
    data
end

ys_factors!(data::DataFrame, spec, cols::Symbol...) =
    ys_factors!(data, spec, collect(cols))

function _ys_decode_value(mapping::Dict, value)
    haskey(mapping, value) && return mapping[value]
    for (code, label) in mapping
        string(code) == string(value) && return label
        code isa Real && value isa Real && Float64(code) == Float64(value) && return label
    end
    value
end
