# ============================================================
# scan — Cartesian product parameter sweeps
# ============================================================

"""
    scan(fn::Function, ctx::SimContext, ranges::Pair{Symbol}...)
    scan(fn::Function, ranges::Pair{Symbol}...)  — curried, for piping

Run `fn(ctx, params_dict)` for every combination in the Cartesian product
of the given parameter ranges. Returns a `Vector` of `(params=Dict, result=...)`
named tuples where result is whatever `fn` returns (SimContext or PopulationResult).

```julia
# Positional
results = scan(ctx, :input_level => [0.2, 0.7, 1.4, 2.1]) do c, p
    c |> with(p) |> simulate(12.0)
end

# Piped
results = ctx |> scan(:initial_offset => [0.1, 0.6, 1.3]) do c, p
    c |> with(p) |> subjects(pop) |> simulate()
end
```
"""
function scan(fn::Function, ctx::SimContext, ranges::Pair{Symbol}...)
    names = [r.first for r in ranges]
    values = [r.second for r in ranges]

    # Build Cartesian product (result type is Any to support both SimContext and PopulationResult)
    results = NamedTuple{(:params, :result), Tuple{Dict{Symbol, Any}, Any}}[]
    _scan_recurse!(results, fn, ctx, names, values, Dict{Symbol, Any}(), 1)
    return results
end

"""
    scan(fn::Function, ranges::Pair{Symbol}...)

Curried form — returns a `PipelineStep` for use with `|>`, so a scan can start
from a `SimContext` *or* a bare `ODEProblem`:

```julia
prob |> scan(:input_level => [0.2, 0.7, 1.4, 2.1]) do c, p
    c |> with(p) |> simulate(12.0)
end
```
"""
scan(fn::Function, ranges::Pair{Symbol}...) = PipelineStep(:scan, ctx -> scan(fn, ctx, ranges...))

"""
    scan(fn::Function, prob::ODEProblem, ranges::Pair{Symbol}...)

Run a scan directly from a bare `ODEProblem`, auto-wrapping it in a default
`SimContext` (see [`SimContext`](@ref)).
"""
scan(fn::Function, prob::SciMLBase.ODEProblem, ranges::Pair{Symbol}...) =
    scan(fn, SimContext(prob), ranges...)

function _scan_recurse!(results, fn, ctx, names, values, current, depth)
    if depth > length(names)
        params = copy(current)
        res = fn(ctx, params)
        push!(results, (params=params, result=res))
        return
    end
    for val in values[depth]
        current[names[depth]] = val
        _scan_recurse!(results, fn, ctx, names, values, current, depth + 1)
    end
    delete!(current, names[depth])
end
