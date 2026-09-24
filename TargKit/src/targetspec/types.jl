# ============================================================
# TargetSet — pure data container for calibration targets
# ============================================================

using OrderedCollections: OrderedDict

"""
    MatchSpec

How the rows of a TargetSet are matched to simulation output (`match` / `at`).
See `TargKit/docs/matching.md`.
"""
struct MatchSpec
    keys::Vector{Pair{Symbol, Symbol}}   # target column => simulation key
    at_column::Union{Symbol, Nothing}    # target column holding each row's `at`
    at_axis::Union{Symbol, Nothing}      # simulation axis; nothing = no `at`
    at_value::Any                        # constant `at` when at_column === nothing
    variable::Union{Symbol, Nothing}     # simulated variable; nothing = per-row :variable column
end

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
- `match::Union{MatchSpec, Nothing}` — how rows match simulation output, or
  nothing when a `predict` function maps them
"""
struct TargetSet
    df::DataFrame
    loss::Union{Symbol, Function}
    metadata::Any  # Union{YspecMetadata, Nothing} — Any to avoid hard SpecKit dep
    match::Union{MatchSpec, Nothing}
end

TargetSet(df::DataFrame, loss, metadata) = TargetSet(df, loss, metadata, nothing)

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
    println(io, "TargetSet: $(nrow(ts)) targets, loss=:$(ts.loss)", _match_summary(ts.match))
    if nrow(ts) > 0
        show(io, MIME"text/plain"(), ts.df)
    end
end

_match_summary(::Nothing) = ""

function _match_summary(spec::MatchSpec)
    parts = String[]
    if !isempty(spec.keys)
        keys = [t == k ? repr(t) : "$(repr(t)) => $(repr(k))" for (t, k) in spec.keys]
        push!(parts, "match=[" * join(keys, ", ") * "]")
    end
    if spec.at_axis !== nothing
        at = spec.at_column === nothing ? "$(repr(spec.at_axis)) => $(spec.at_value)" :
            spec.at_column == spec.at_axis ? repr(spec.at_axis) :
            "$(repr(spec.at_column)) => $(repr(spec.at_axis))"
        push!(parts, "at=" * at)
    end
    spec.variable === nothing || push!(parts, "variable=$(repr(spec.variable))")
    return ", " * join(parts, ", ")
end
