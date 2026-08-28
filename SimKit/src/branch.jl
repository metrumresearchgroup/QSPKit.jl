# ============================================================
# Branching, result extraction, and phase access
# ============================================================

import DataFrames: DataFrame, nrow

# ----------------------------------------------------------
# branch — fork into multiple arms from a common base
# ----------------------------------------------------------

"""
    branch(ctx::SimContext, arms::Pair{Symbol}...)

Run each arm pipeline from `ctx` eagerly, returning `Dict{Symbol, SimContext}`.

Each arm is a `name => pipeline_fn` pair where `pipeline_fn` is a function
or Pipeline that takes a SimContext and returns a SimContext.

# Example
```julia
arms = branch(baseline,
    :quiet => with(quiet_params) >> simulate(18.0),
    :pulse => with(pulse_params) >> events(pulse_events) >> simulate(18.0),
    :step => with(step_params) >> events(step_events) >> simulate(18.0),
    :burst => with(burst_params) >> events(burst_events) >> simulate(18.0),
)
```
"""
function branch(ctx::SimContext, arms::Pair{Symbol}...)
    Dict(name => fn(ctx) for (name, fn) in arms)
end

"""
    branch(ctx::SimContext, df::DataFrame; name::Symbol, params::Vector{Symbol}, event_col::Union{Symbol, Nothing}=nothing)

Create branch arms from a DataFrame of conditions.

Each row becomes an arm. The `name` column provides arm labels, `params` columns
provide parameter overrides, and the optional `event_col` column provides events.

# Example
```julia
conditions = DataFrame(
    mode = [:quiet, :pulse, :step, :burst],
    response_gain = [0.2, 0.55, 1.0, 1.6],
    schedule = [nothing, pulse_events, step_events, burst_events],
)
arms = branch(baseline, conditions;
    name=:mode, params=[:response_gain], event_col=:schedule)
```
"""
function branch(ctx::SimContext, df::DataFrame; name::Symbol, params::Vector{Symbol},
                event_col::Union{Symbol, Nothing}=nothing)
    arms = Dict{Symbol, SimContext}()
    for row_idx in 1:nrow(df)
        arm_name = Symbol(df[row_idx, name])
        # Build parameter overrides from specified columns
        overrides = Dict{Symbol, Any}()
        for p in params
            val = df[row_idx, p]
            if !ismissing(val) && !(val isa Number && isnan(val))
                overrides[p] = val
            end
        end
        # Start from base context with overrides
        arm_ctx = with(ctx, overrides)
        # Add events if specified
        if event_col !== nothing
            ev = df[row_idx, event_col]
            if ev !== nothing && !ismissing(ev)
                arm_ctx = events(arm_ctx, ev)
            end
        end
        arms[arm_name] = arm_ctx
    end
    return arms
end

# ----------------------------------------------------------
# branch_lazy — deferred execution
# ----------------------------------------------------------

"""
    branch_lazy(ctx::SimContext, arms::Pair{Symbol}...)

Like `branch`, but defers execution. Returns a `LazyBranch` — arms are only
executed when first accessed via `getindex`, and results are cached.

# Example
```julia
arms = branch_lazy(baseline, :pulse => pipeline1, :step => pipeline2)
arms[:pulse]   # pipeline1 runs now, returns SimContext
arms[:step]    # pipeline2 runs now
```
"""
function branch_lazy(ctx::SimContext, arms::Pair{Symbol}...)
    LazyBranch(ctx, Dict{Symbol, Any}(name => fn for (name, fn) in arms))
end

# ----------------------------------------------------------
# Pipeline + ODEProblem entry forms for branch / branch_lazy
# ----------------------------------------------------------
# In addition to the `SimContext`-first forms above, a branch can start from a
# bare `ODEProblem` (auto-wrapped in a default `SimContext`, see [`SimContext`](@ref))
# or be used as a curried `PipelineStep` so it can sit in a pipeline:
#     prob |> branch(:a => p1, :b => p2)
#     prob |> branch(conditions; name=:mode, params=[:response_gain])

branch(prob::SciMLBase.ODEProblem, arms::Pair{Symbol}...) = branch(SimContext(prob), arms...)
branch(prob::SciMLBase.ODEProblem, df::DataFrame; kwargs...) = branch(SimContext(prob), df; kwargs...)
branch(arms::Pair{Symbol}...) = PipelineStep(:branch, ctx -> branch(ctx, arms...))
branch(df::DataFrame; kwargs...) = PipelineStep(:branch, ctx -> branch(ctx, df; kwargs...))

branch_lazy(prob::SciMLBase.ODEProblem, arms::Pair{Symbol}...) = branch_lazy(SimContext(prob), arms...)
branch_lazy(arms::Pair{Symbol}...) = PipelineStep(:branch_lazy, ctx -> branch_lazy(ctx, arms...))

# ----------------------------------------------------------
# result — extract ODESolutions
# ----------------------------------------------------------

"""
    result(ctx::SimContext)

Extract solutions as `Dict{Symbol, ODESolution}`. Returns the last phase
for each unique phase name.
"""
function result(ctx::SimContext)
    d = Dict{Symbol, Any}()
    for phase in ctx.phases
        d[phase.name] = phase.sol
    end
    return d
end

"""
    result(arms::Dict{Symbol, SimContext})

Extract last ODESolution from each arm. Returns `Dict{Symbol, ODESolution}`.
"""
function result(arms::Dict{Symbol, SimContext})
    Dict(name => ctx.phases[end].sol for (name, ctx) in arms if !isempty(ctx.phases))
end

"""
    result(scan_results; by=nothing, phase=nothing)

Extract scan results into a `Dict` keyed by a scanned parameter. If the scan has
only one parameter, `by` is inferred. If a scanned `SimContext` has only one
phase, that phase solution is returned directly; use `phase` to select a named
phase from multi-phase contexts.
"""
function result(scan_results::Vector{<:NamedTuple}; by::Union{Symbol, Nothing}=nothing,
                phase::Union{Symbol, Nothing}=nothing)
    key = _scan_result_key(scan_results, by)
    out = Dict{Any, Any}()
    for entry in scan_results
        haskey(entry.params, key) || throw(KeyError(key))
        out[entry.params[key]] = _scan_result_value(entry.result, phase)
    end
    return out
end

_scan_result_key(_scan_results, by::Symbol) = by
function _scan_result_key(scan_results, ::Nothing)
    isempty(scan_results) && throw(ArgumentError("Cannot infer scan result key from empty scan results; pass `by=...`."))

    names = collect(keys(first(scan_results).params))
    length(names) == 1 || throw(ArgumentError(
        "Cannot infer scan result key from $(length(names)) scanned parameters; pass `by=...`."
    ))
    return only(names)
end

_scan_result_value(res, ::Nothing) = res
_scan_result_value(res::SimContext, ::Nothing) = length(res.phases) == 1 ? res.phases[1].sol : result(res)
_scan_result_value(res, phase::Symbol) = result(res, phase)

"""
    result(ctx::SimContext, name::Symbol)

Get the solution for the last phase with the given `name`.
"""
function result(ctx::SimContext, name::Symbol)
    for i in length(ctx.phases):-1:1
        if ctx.phases[i].name == name
            return ctx.phases[i].sol
        end
    end
    throw(KeyError(name))
end

"""
    result(ctx::SimContext, name::Symbol, idx::Int)

Get the solution for the `idx`-th phase with the given `name`.
"""
function result(ctx::SimContext, name::Symbol, idx::Int)
    count = 0
    for phase in ctx.phases
        if phase.name == name
            count += 1
            if count == idx
                return phase.sol
            end
        end
    end
    throw(BoundsError("Only $count phase(s) named :$name, requested index $idx"))
end

# ----------------------------------------------------------
# phases — access phase history
# ----------------------------------------------------------

"""
    phases(ctx::SimContext)

Return the vector of completed `Phase` objects.
"""
phases(ctx::SimContext) = ctx.phases
