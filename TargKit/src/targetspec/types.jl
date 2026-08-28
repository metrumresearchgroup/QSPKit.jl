# ============================================================
# TargetSet — pure data container for calibration targets
# ============================================================

using OrderedCollections: OrderedDict

"""
    TargetSet

A set of calibration targets: DataFrame of observations + optional yspec metadata.

TargetSet is a pure data container. It knows about **observed data** only.
Simulation mapping happens at `score()`/`fit()` time, not at construction.

Implements the Tables.jl interface for DataFrame ecosystem interoperability.

# Fields
- `df::DataFrame` — target data with `:value`, `:lower`, `:upper` + metadata columns
- `loss::Union{Symbol, Function}` — default loss type for scoring
- `metadata::Any` — optional YspecMetadata (from SpecKit), or nothing
"""
struct TargetSet
    df::DataFrame
    loss::Union{Symbol, Function}
    metadata::Any  # Union{YspecMetadata, Nothing} — Any to avoid hard SpecKit dep
end

# Tables.jl interface
import Tables
Tables.istable(::Type{TargetSet}) = true
Tables.schema(ts::TargetSet) = Tables.schema(ts.df)
Tables.rows(ts::TargetSet) = Tables.rows(ts.df)
Tables.columns(ts::TargetSet) = Tables.columns(ts.df)

# DataFrame-like access
function Base.getproperty(ts::TargetSet, s::Symbol)
    s in fieldnames(TargetSet) ? getfield(ts, s) : getproperty(ts.df, s)
end

function Base.propertynames(ts::TargetSet; private=false)
    fns = collect(fieldnames(TargetSet))
    append!(fns, propertynames(ts.df))
    unique(fns)
end

DataFrames.nrow(ts::TargetSet) = nrow(ts.df)
Base.eachrow(ts::TargetSet) = eachrow(ts.df)
Base.length(ts::TargetSet) = nrow(ts.df)

# Display
function Base.show(io::IO, ts::TargetSet)
    print(io, "TargetSet($(nrow(ts)) targets)")
end

function Base.show(io::IO, ::MIME"text/plain", ts::TargetSet)
    println(io, "TargetSet: $(nrow(ts)) targets, loss=:$(ts.loss)")
    if nrow(ts) > 0
        show(io, MIME"text/plain"(), ts.df)
    end
end
