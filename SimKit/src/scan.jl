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
results = scan(ctx, :dose => [10, 50, 100]) do c, p
    c |> with(p) |> simulate(400.0)
end

# Piped
results = ctx |> scan(:igg_baseline => [2.0, 4.0, 6.0]) do c, p
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
prob |> scan(:dose => [10, 50, 100]) do c, p
    c |> with(p) |> simulate(400.0)
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

# ----------------------------------------------------------
# Keyword form — no pipeline body
# ----------------------------------------------------------

"""
    scan(ctx::SimContext, ranges::Pair{Symbol}...; events=nothing, duration=nothing, kwargs...)
    scan(prob::ODEProblem, ranges::Pair{Symbol}...; events=nothing, duration=nothing, kwargs...)
    scan(ranges::Pair{Symbol}...; events=nothing, duration=nothing, kwargs...)  — curried, for piping

Keyword form of `scan`: sweep without writing a pipeline body. Each point in the
Cartesian product of `ranges` runs

    ctx |> with(<swept model quantities>) |> events(events(point)) |> simulate(duration; kwargs...)

- Swept names the model knows (parameters, or states as initial conditions) are
  staged with `with`.
- `events` is a function of the sweep point — a `NamedTuple`, so `p.dose` — that
  returns anything `events` accepts (`ev(...)`, an event vector, a regimen
  template, ...). Swept names the model does not know are only passed to this
  function; without `events`, every swept name must be a model parameter or state.
- `duration` defaults to the length of the problem's `tspan`. Remaining keywords
  (`solver`, `saveat`, `reltol`, `name`, ...) are forwarded to `simulate`.

Returns the same `(params=Dict, result=SimContext)` vector as the do-block form,
so `to_dataframe` and `result` work unchanged.

```julia
# Dose sweep: dose is not a model parameter, so it only reaches `events`
sweep = scan(prob, :dose => [1.0, 10.0, 100.0];
    events = p -> ev(cmt=:Depot, amt=p.dose), duration=72.0, saveat=1.0)

# Parameter sweep: no events needed
sweep = scan(prob, :CL => [0.5, 1.0, 2.0]; duration=72.0)
```
"""
function scan(ctx::SimContext, ranges::Pair{Symbol}...; events=nothing, duration=nothing, kwargs...)
    names = Symbol[first(r) for r in ranges]
    model_names = filter(n -> _is_model_quantity(n, ctx.sys), names)
    if events === nothing
        other = setdiff(names, model_names)
        isempty(other) || throw(ArgumentError(
            "scan: $(join(repr.(other), ", ")) $(length(other) == 1 ? "is not a model parameter or state" : "are not model parameters or states"). " *
            "Pass `events = p -> ...` to use swept values that are not model quantities."))
    end
    return scan(ctx, ranges...) do c, params
        _run_scan_point(c, params, names, model_names, events, duration; kwargs...)
    end
end

scan(prob::SciMLBase.ODEProblem, ranges::Pair{Symbol}...; kwargs...) =
    scan(SimContext(prob), ranges...; kwargs...)

scan(ranges::Pair{Symbol}...; kwargs...) =
    PipelineStep(:scan, ctx -> scan(ctx, ranges...; kwargs...))

_is_model_quantity(name::Symbol, sys) =
    InjecKit.is_parameter(name, sys) || InjecKit.is_state_variable(name, sys)

function _run_scan_point(ctx, params, names, model_names, event_fn, duration; kwargs...)
    isempty(model_names) || (ctx = with(ctx, [n => params[n] for n in model_names]))
    if event_fn !== nothing
        point = NamedTuple{Tuple(names)}(Tuple(params[n] for n in names))
        ctx = events(ctx, event_fn(point))
    end
    return duration === nothing ? simulate(ctx; kwargs...) : simulate(ctx, duration; kwargs...)
end

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
