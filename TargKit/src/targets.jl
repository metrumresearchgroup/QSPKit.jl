# ============================================================
# targets() — convenience constructor for target DataFrames
# ============================================================

"""
    targets(; name = (value, lower, upper), ...) -> DataFrame

Convenience constructor for a target DataFrame from keyword arguments.
Each keyword becomes a row with `:name`, `:value`, `:lower`, `:upper`.

    targets(Blood_Eos = (2.5, 1.5, 4.0), FeNO = (40.0, 25.0, 55.0))
"""
function targets(; kwargs...)
    isempty(kwargs) && return DataFrame(name=Symbol[], value=Float64[], lower=Float64[], upper=Float64[])
    rows = NamedTuple[]
    for (k, v) in pairs(kwargs)
        if v isa Tuple{<:Real, <:Real, <:Real}
            push!(rows, (name=k, value=Float64(v[1]), lower=Float64(v[2]), upper=Float64(v[3])))
        elseif v isa Real
            push!(rows, (name=k, value=Float64(v), lower=NaN, upper=NaN))
        else
            error("targets(): value for :$k must be (value, lower, upper) or a scalar, got $(typeof(v))")
        end
    end
    df = DataFrame(rows)
    # Replace NaN lower/upper with missing-like sentinel? No — keep NaN for simplicity.
    # Users who want no range simply omit lower/upper or use DataFrame tools.
    return df
end
