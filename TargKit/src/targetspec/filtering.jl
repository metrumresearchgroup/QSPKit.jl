# TargetSet filtering — row subsetting with where()

"""
    where(ts::TargetSet, pair::Pair) → TargetSet

Filter a TargetSet's rows by column value. Returns a new TargetSet with matching
rows, preserving the loss function and metadata.

Supports scalar or vector matching:
- `:col => value` — keep rows where `col == value`
- `:col => [v1, v2]` — keep rows where `col ∈ [v1, v2]`

# Examples
```julia
where(ts, :condition => :nominal)
where(ts, :variable => [:gain, :lag])
```
"""
function where(ts::TargetSet, pair::Pair)
    col, val = pair
    mask = if val isa AbstractVector
        [row[col] in val for row in eachrow(ts.df)]
    else
        [row[col] == val for row in eachrow(ts.df)]
    end
    TargetSet(ts.df[mask, :], ts.loss, ts.metadata)
end

"""
    where(pair::Pair) → Function

Curried form for piping: `ts |> where(:condition => :nominal)`.
"""
where(pair::Pair) = ts -> where(ts, pair)
