# ============================================================
# Core types for SimKit
# ============================================================

"""
    Phase

A completed simulation phase, recording its name, solution, and duration.
"""
struct Phase
    name::Symbol
    sol::Any  # ODESolution
    duration::Float64
end

"""
    SimContext

Immutable state container that flows through a simulation pipeline.

Holds the base ODE problem, the latest solution, staged parameter overrides
and dosing events, solver configuration, and the history of completed phases.
"""
struct SimContext
    prob::SciMLBase.ODEProblem
    sol::Union{Nothing, Any}           # ODESolution or nothing
    params::Any                        # staged param overrides (Dict or fixed-key NamedTuple; consumed by next simulate)
    events::Any                        # staged dosing events, normalized internally (consumed by next simulate)
    solver::Any                        # default solver algorithm
    solve_kwargs::NamedTuple           # default solver kwargs (reltol, maxiters, etc.)
    phases::Vector{Phase}              # history of completed phases
    persist::Bool                      # if true, keep() was called — params survive next simulate()
    sys::Any                           # optional pre-compiled MTK system
end

"""
    SimulationError <: Exception

Wraps a solver failure with context about which phase failed,
what parameters were applied, and what events were staged.
"""
struct SimulationError <: Exception
    phase_name::Symbol
    params::Any
    events::Any
    cause::Exception
end

"""
    SimRunner

Reusable simulation executor for repeated evaluations of one fixed simulation
shape. Public simulation APIs build and use the same cached event/update
machinery automatically; direct construction is only for callers that want an
explicit reusable executor object.
"""
struct SimRunner
    prepared::Any
    default_solver::Any
    default_solve_kwargs::NamedTuple
end

function Base.showerror(io::IO, e::SimulationError)
    print(io, "SimulationError in phase :$(e.phase_name)")
    if !isempty(e.params)
        print(io, " ($(length(e.params)) params)")
    end
    if !isempty(e.events)
        print(io, " ($(length(e.events)) events)")
    end
    print(io, "\n  Caused by: ")
    showerror(io, e.cause)
end

"""
    LazyBranch

Dict-like container for lazily evaluated pipeline arms.
Each arm is only executed when first accessed, and results are cached.
"""
struct LazyBranch
    base::SimContext
    arms::Dict{Symbol, Any}       # Function or Pipeline — anything callable
    cache::Dict{Symbol, SimContext}
    lock::ReentrantLock
end

function LazyBranch(base::SimContext, arms::Dict{Symbol, <:Any})
    LazyBranch(base, arms, Dict{Symbol, SimContext}(), ReentrantLock())
end

function LazyBranch(base::SimContext, arms::Dict{Symbol, <:Any}, cache::Dict{Symbol, SimContext})
    LazyBranch(base, arms, cache, ReentrantLock())
end

function Base.getindex(lb::LazyBranch, key::Symbol)
    return lock(lb.lock) do
        if haskey(lb.cache, key)
            return lb.cache[key]
        end
        haskey(lb.arms, key) || throw(KeyError(key))
        result = lb.arms[key](lb.base)
        lb.cache[key] = result
        return result
    end
end

Base.keys(lb::LazyBranch) = keys(lb.arms)
Base.haskey(lb::LazyBranch, key::Symbol) = haskey(lb.arms, key)
Base.length(lb::LazyBranch) = length(lb.arms)

function Base.iterate(lb::LazyBranch)
    ks = collect(keys(lb.arms))
    isempty(ks) && return nothing
    k = ks[1]
    return (k => lb[k], (ks, 2))
end

function Base.iterate(lb::LazyBranch, state)
    ks, idx = state
    idx > length(ks) && return nothing
    k = ks[idx]
    return (k => lb[k], (ks, idx + 1))
end

"""
    Pipeline

First-class, inspectable pipeline composed of named stages.
Supports `|>` for composition and is callable on a SimContext.

# Example
```julia
pipeline = events(evs) |> simulate(100.0)
result = baseline |> pipeline  # executes the pipeline
```
"""
struct Pipeline
    stages::Vector{NamedTuple{(:name, :fn), Tuple{Symbol, Function}}}
end

function Pipeline(pairs::Vector{Pair{Symbol, F}}) where {F<:Function}
    Pipeline([(name=k, fn=v) for (k, v) in pairs])
end

function (p::Pipeline)(ctx::SimContext)
    foldl((c, s) -> s.fn(c), p.stages; init=ctx)
end

"""
    PipelineStep

A single curried pipeline step (e.g., `events(evs)`, `simulate(100.0)`).
Supports `|>` for composition: `events(evs) |> simulate(100.0)` produces a Pipeline.
Also callable: `step(ctx)` executes the step on a SimContext.
"""
struct PipelineStep
    name::Symbol
    fn::Function
end

(s::PipelineStep)(ctx::SimContext) = s.fn(ctx)

# |> composition: same operator everywhere
Base.:(|>)(a::PipelineStep, b::PipelineStep) = Pipeline([(name=a.name, fn=a.fn), (name=b.name, fn=b.fn)])
Base.:(|>)(p::Pipeline, s::PipelineStep) = Pipeline(vcat(p.stages, [(name=s.name, fn=s.fn)]))
Base.:(|>)(s::PipelineStep, p::Pipeline) = Pipeline(vcat([(name=s.name, fn=s.fn)], p.stages))
Base.:(|>)(p1::Pipeline, p2::Pipeline) = Pipeline(vcat(p1.stages, p2.stages))

# |> execution: context into step or pipeline
Base.:(|>)(ctx::SimContext, s::PipelineStep) = s(ctx)
Base.:(|>)(ctx::SimContext, p::Pipeline) = p(ctx)

# |> entry: an ODEProblem can enter the pipeline directly — it auto-wraps in a
# default SimContext (no explicit solver; the auto-switching default applies at
# solve time, and solver/kwargs can be set on the first `simulate`).
Base.:(|>)(prob::SciMLBase.ODEProblem, s::PipelineStep) = SimContext(prob) |> s
Base.:(|>)(prob::SciMLBase.ODEProblem, p::Pipeline) = SimContext(prob) |> p

# ============================================================
# Subject and Population
# ============================================================

"""
    Subject

A single individual's data for simulation or estimation.

Fields:
- `id` — subject identifier (from ID column)
- `events` — dosing events extracted from EVID=1 rows
- `obs_times` — observation times from EVID=0 rows
- `obs_values` — DV values at observation times (nothing for simulation-only)
- `obs_names` — biomarker label per observation (nothing for single-output models)
- `obs_censors` — censoring label per observation (`:none`, `:left`, `:right`) or nothing
- `obs_limits` — censoring limit per observation (`NaN` for uncensored) or nothing
- `covariates` — numeric columns for model parameter overrides (Float64 NamedTuple)
- `columns` — ALL non-reserved dataset columns with original types (for carry_out)
"""
struct Subject
    id::Any
    events::Vector{InjecKit.IEvent}
    obs_times::Vector{Float64}
    obs_values::Union{Nothing, Vector{Float64}}
    obs_names::Union{Nothing, Vector{Symbol}}
    obs_censors::Union{Nothing, Vector{Symbol}}
    obs_limits::Union{Nothing, Vector{Float64}}
    covariates::NamedTuple
    columns::NamedTuple
end

# 7-arg compat: no censor metadata
Subject(id, events, obs_times, obs_values, obs_names,
        covariates::NamedTuple, columns::NamedTuple) =
    Subject(id, events, obs_times, obs_values, obs_names, nothing, nothing,
            covariates, columns)

# 6-arg compat: columns defaults to covariates
Subject(id, events, obs_times, obs_values, obs_names, covariates::NamedTuple) =
    Subject(id, events, obs_times, obs_values, obs_names, nothing, nothing,
            covariates, covariates)

# 5-arg compat: obs_names=nothing, columns=covariates
Subject(id, events, obs_times, obs_values, covariates::NamedTuple) =
    Subject(id, events, obs_times, obs_values, nothing, nothing, nothing,
            covariates, covariates)

"""
    Population

A vector of `Subject`s — the canonical representation of multi-subject data.
"""
const Population = Vector{Subject}

# ============================================================
# PopulationResult — population simulation container
# ============================================================

"""
    PopulationResult

Container for population-level simulation results. Returned by `subjects()` and
flows through the pipeline via `|> simulate() |> to_dataframe`.

Implements the Dict interface so existing `for (id, ctx) in results` code keeps working.

# Fields
- `population`: Original `Population` (Vector{Subject}) with obs_times, obs_values, covariates
- `contexts`: `Dict{Any, SimContext}` keyed by subject ID
- `errors`: `Dict{Any, Exception}` for subjects that failed during simulation
"""
struct PopulationResult
    population::Population
    contexts::Dict{Any, SimContext}
    errors::Dict{Any, Exception}
end

Base.getindex(pr::PopulationResult, id) = pr.contexts[id]
Base.keys(pr::PopulationResult) = keys(pr.contexts)
Base.haskey(pr::PopulationResult, id) = haskey(pr.contexts, id)
Base.length(pr::PopulationResult) = length(pr.contexts)
Base.iterate(pr::PopulationResult) = iterate(pr.contexts)
Base.iterate(pr::PopulationResult, state) = iterate(pr.contexts, state)

# PopulationResult flows into pipeline steps
(s::PipelineStep)(pr::PopulationResult) = s.fn(pr)
Base.:(|>)(pr::PopulationResult, s::PipelineStep) = s(pr)
