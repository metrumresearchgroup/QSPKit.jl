# ============================================================
# Pipeline operations: with, events, keep, simulate
# ============================================================

import Base: >>

# ----------------------------------------------------------
# with — stage parameter overrides
# ----------------------------------------------------------

function _params_as_dict(params)
    out = Dict{Symbol, Any}()
    for (k, v) in pairs(params)
        out[Symbol(k)] = v
    end
    return out
end

_merge_named_params(::NamedTuple{()}, nt::NamedTuple) = nt
_merge_named_params(params::NamedTuple, nt::NamedTuple) = isempty(params) ? nt : merge(params, nt)
_merge_named_params(params, nt::NamedTuple) = begin
    isempty(params) && return nt
    out = _params_as_dict(params)
    for (k, v) in pairs(nt)
        out[Symbol(k)] = v
    end
    out
end

"""
    with(ctx::SimContext, pairs)

Stage parameter overrides on the context. Returns a new SimContext.
Pairs can be a Dict, Vector of Pairs, or any iterable of key => value.
"""
function with(ctx::SimContext, pairs)
    new_params = _params_as_dict(ctx.params)
    for (k, v) in pairs
        new_params[Symbol(k)] = v
    end
    SimContext(ctx.prob, ctx.sol, new_params, ctx.events, ctx.solver,
              ctx.solve_kwargs, ctx.phases, ctx.persist, ctx.sys)
end

function with(ctx::SimContext, nt::NamedTuple)
    new_params = _merge_named_params(ctx.params, nt)
    SimContext(ctx.prob, ctx.sol, new_params, ctx.events, ctx.solver,
              ctx.solve_kwargs, ctx.phases, ctx.persist, ctx.sys)
end

function with(ctx::SimContext, pair::Pair)
    new_params = _params_as_dict(ctx.params)
    new_params[Symbol(first(pair))] = last(pair)
    SimContext(ctx.prob, ctx.sol, new_params, ctx.events, ctx.solver,
              ctx.solve_kwargs, ctx.phases, ctx.persist, ctx.sys)
end

"""
    with(pairs)

Curried form — returns a function `ctx -> with(ctx, pairs)`.
"""
with(pairs) = PipelineStep(:with, ctx -> with(ctx, pairs))

# ----------------------------------------------------------
# events — stage discrete events (doses, infusions, resets, ...)
# ----------------------------------------------------------

function _merge_event_schedules(existing, events_data)
    schedule = InjecKit.prepare_events(events_data)
    isempty(existing) && return schedule
    return InjecKit.prepare_events(vcat(collect(existing), collect(schedule)))
end

"""
    events(ctx::SimContext, evs)

Stage discrete events on the context. Returns a new SimContext. Events are
accepted as raw `ev(...)` records, event vectors, or event DataFrames (doses,
infusions, state resets, parameter changes, ...); SimKit normalizes them
internally before simulation. Events **accumulate** (each call appends to any
already staged) and are **cleared after each `simulate`** (they are time-specific).
"""
function events(ctx::SimContext, events_data)
    new_events = _merge_event_schedules(ctx.events, events_data)
    SimContext(ctx.prob, ctx.sol, ctx.params, new_events, ctx.solver,
              ctx.solve_kwargs, ctx.phases, ctx.persist, ctx.sys)
end

"""
    events(evs)

Curried form — returns a `PipelineStep` for use with `|>`, so events can be
staged onto a `SimContext` or a bare `ODEProblem`: `prob |> events(evs)`.
"""
function events(events_data)
    schedule = InjecKit.prepare_events(events_data)
    return PipelineStep(:events, ctx -> events(ctx, schedule))
end

# ----------------------------------------------------------
# keep — persist staged params through next run
# ----------------------------------------------------------

"""
    keep(ctx::SimContext)

Mark staged params to persist through the next `simulate()` instead of being cleared.
"""
function keep(ctx::SimContext)
    SimContext(ctx.prob, ctx.sol, ctx.params, ctx.events, ctx.solver,
              ctx.solve_kwargs, ctx.phases, true, ctx.sys)
end

"""
    keep()

Curried form — returns a function `ctx -> keep(ctx)`.
"""
keep() = PipelineStep(:keep, ctx -> keep(ctx))

# ----------------------------------------------------------
# simulate — solve a phase
# ----------------------------------------------------------

function _ordered_param_keys_values(params)
    raw_keys = Tuple(sort!(collect(keys(params)); by=string))
    raw_values = Tuple(params[k] for k in raw_keys)
    return raw_keys, raw_values
end

function _ordered_param_keys_values(params::NamedTuple)
    return keys(params), Tuple(params)
end

_default_alg() = OrdinaryDiffEq.AutoTsit5(OrdinaryDiffEq.Rosenbrock23())

_phase_update_kwargs(t_start, duration, ::Nothing) = (tspan = (t_start, t_start + duration),)
_phase_update_kwargs(t_start, duration, u0) = (tspan = (t_start, t_start + duration), u0 = u0)

function _append_phase(phases::Vector{Phase}, phase::Phase)
    out = Vector{Phase}(undef, length(phases) + 1)
    copyto!(out, phases)
    out[end] = phase
    return out
end

function _solve_phase_problem(prob, events, alg, kw)
    if isempty(events)
        if alg === nothing
            return OrdinaryDiffEq.solve(prob; kw...)
        else
            return OrdinaryDiffEq.solve(prob, alg; kw...)
        end
    end
    return OrdinaryDiffEq.solve(prob, events, alg; kw...)
end

function _solve_phase_problem(prob, events::InjecKit.EventSchedule, alg, kw)
    runner = InjecKit.cached_event_runner(prob, events)
    return InjecKit.solve_event_runner(runner, alg; kw...)
end

function SimRunner(ctx::SimContext, duration::Real; params, absolute::Bool=false,
                   solver=nothing, kwargs...)
    prob = ctx.prob
    t_start = if absolute && ctx.sol !== nothing
        ctx.sol.t[end]
    else
        0.0
    end
    base_u0 = isnothing(ctx.sol) ? nothing : ctx.sol(ctx.sol.t[end])
    default_solver = something(solver, ctx.solver, _default_alg())
    default_solve_kwargs = merge(ctx.solve_kwargs, NamedTuple(kwargs))
    phase_tspan = (t_start, t_start + duration)
    raw_keys = Tuple(params)
    prepared = InjecKit.PreparedEventSolve(
        prob, ctx.events; params=raw_keys, tspan=phase_tspan, base_u0=base_u0)
    return SimRunner(prepared, default_solver, default_solve_kwargs)
end

function (runner::SimRunner)(overrides; solver=nothing, duration=nothing, tspan=nothing, kwargs...)
    alg = something(solver, runner.default_solver)
    solve_kwargs = merge(runner.default_solve_kwargs, NamedTuple(kwargs))
    return runner.prepared(
        overrides; alg=alg, duration=duration, tspan=tspan, solve_kwargs...)
end

function _cached_sim_runner(ctx::SimContext, duration::Real, absolute::Bool,
                            param_keys::Tuple, t_start::Real)
    ctx.events isa InjecKit.EventSchedule || return nothing

    key = _simrunner_cache_key(ctx.prob, ctx.events, param_keys, t_start, ctx.sol)
    cached = _simrunner_cache_get(key, ctx.prob, ctx.events, param_keys, t_start, ctx.sol)
    cached === nothing || return cached

    planning_ctx = SimContext(
        ctx.prob,
        ctx.sol,
        NamedTuple(),
        ctx.events,
        ctx.solver,
        NamedTuple(),
        ctx.phases,
        ctx.persist,
        ctx.sys,
    )
    runner = SimRunner(planning_ctx, duration; params=param_keys, absolute=absolute)
    return _simrunner_cache_put!(key, ctx.prob, ctx.events, param_keys, t_start, ctx.sol, runner)
end

function _simulate_solution(ctx::SimContext, duration::Real; absolute::Bool=false,
                            solver=nothing, overrides=nothing, kwargs...)
    prob = ctx.prob
    params = overrides === nothing ? ctx.params : _merge_named_params(ctx.params, overrides)

    # 1. Time handling
    t_start = if absolute && ctx.sol !== nothing
        ctx.sol.t[end]
    else
        0.0
    end

    # 2. Initial conditions from previous phase
    u0 = isnothing(ctx.sol) ? nothing : ctx.sol(ctx.sol.t[end])

    # Check cache before doing any work
    alg = something(solver, ctx.solver, _default_alg())
    kw = merge(ctx.solve_kwargs, NamedTuple(kwargs))
    cache_key = nothing
    cached_sol = nothing
    if _cache_enabled()
        cache_key = _cache_key(prob, params, ctx.events, duration, t_start, u0, alg, kw)
        cached_sol = _cache_get(cache_key, prob, params, ctx.events, duration,
            t_start, u0, alg, kw)
    end

    sol = if cached_sol !== nothing
        cached_sol
    else
        raw_keys, _ = isempty(params) ? ((), ()) : _ordered_param_keys_values(params)
        runner = _cached_sim_runner(ctx, duration, absolute, raw_keys, t_start)
        runner === nothing &&
            error("SimKit requires normalized InjecKit event schedules in SimContext.")
        raw_sol = runner(params; solver=alg, duration=duration, kw...)
        if cache_key !== nothing
            _cache_put!(cache_key, prob, params, ctx.events, duration, t_start,
                u0, alg, kw, raw_sol)
        end
        raw_sol
    end
end

"""
    simulate_solution(ctx::SimContext, duration::Real; kwargs...)

Apply staged params/events and return the ODE solution directly without
recording a new `Phase` or returning a new `SimContext`. This uses the same
update, event-plan, solver, and cache machinery as `simulate`.
"""
function simulate_solution(ctx::SimContext, duration::Real; absolute::Bool=false,
                           solver=nothing, overrides=nothing, kwargs...)
    return _simulate_solution(ctx, duration; absolute=absolute, solver=solver,
        overrides=overrides, kwargs...)
end

"""
    simulate(ctx::SimContext, duration::Real; name::Symbol=:phase, absolute::Bool=false,
             solver=nothing, kwargs...)

Apply staged params/events, solve the ODE for `duration`, and advance state.

Returns a new SimContext with the solution recorded as a Phase.

# Time handling
- **Relative** (default): each phase runs from `t=0` to `t=duration`
- **Absolute** (`absolute=true`): continues from previous phase end time

# After simulate
- Events are always cleared (they are time-specific)
- Params are cleared unless `keep()` was called beforehand
- The `persist` flag resets to `false`

# Solver / keyword propagation
`solver` and solver keyword arguments (`saveat`, `reltol`, `abstol`, `maxiters`,
…) passed here are baked into the returned context and **propagate to later
phases until overwritten** (then the new value continues to propagate forward).
Omitting `solver` keeps the auto-switching default (`AutoTsit5(Rosenbrock23())`);
the phase-control keywords `name`/`absolute` never leak into the solver options.

# Direct pipeline entry
A pipeline may start from a bare `ODEProblem`, which auto-wraps in a default
`SimContext` (see [`SimContext`](@ref)) — e.g. `prob |> simulate(duration; …)`.
"""
function simulate(ctx::SimContext, duration::Real; name::Symbol=:phase, absolute::Bool=false,
                  solver=nothing, kwargs...)
    prob = ctx.prob
    sol = _simulate_solution(ctx, duration; absolute=absolute, solver=solver, kwargs...)

    # 5. Record phase; clear or keep params based on persist flag
    phase = Phase(name, sol, Float64(duration))
    new_params = ctx.persist ? copy(ctx.params) : NamedTuple()
    new_events = InjecKit.prepare_events(InjecKit.IEvent[])

    # Solver/kwargs propagate forward: an explicit value passed to this simulate
    # becomes the new default and continues to propagate to later phases until
    # overwritten again. (`solver === nothing` keeps the auto-default in play.)
    new_solver = solver === nothing ? ctx.solver : solver
    new_solve_kwargs = merge(ctx.solve_kwargs, NamedTuple(kwargs))

    SimContext(prob, sol, new_params, new_events, new_solver, new_solve_kwargs,
              _append_phase(ctx.phases, phase), false, ctx.sys)
end

"""
    simulate(ctx::SimContext; kwargs...)

Simulate with duration inferred from `prob.tspan[2] - prob.tspan[1]`.
"""
function simulate(ctx::SimContext; kwargs...)
    tspan = ctx.prob.tspan
    simulate(ctx, tspan[2] - tspan[1]; kwargs...)
end

"""
    simulate_solution(ctx::SimContext; kwargs...)

Return a solution with duration inferred from `prob.tspan[2] - prob.tspan[1]`.
"""
function simulate_solution(ctx::SimContext; kwargs...)
    tspan = ctx.prob.tspan
    simulate_solution(ctx, tspan[2] - tspan[1]; kwargs...)
end

"""
    simulate(duration::Real; kwargs...)

Curried form — returns a function `ctx -> simulate(ctx, duration; kwargs...)`.
"""
simulate(duration::Real; kwargs...) = PipelineStep(:simulate, ctx -> simulate(ctx, duration; kwargs...))

# ----------------------------------------------------------
# simulate — population-level (PopulationResult)
# ----------------------------------------------------------

"""
    simulate(pr::PopulationResult, duration::Real; parallel::Bool=true, kwargs...)

Simulate all subjects for `duration`. Per-subject errors are captured in
`pr.errors` rather than stopping the entire population.
"""
function simulate(pr::PopulationResult, duration::Real; parallel::Bool=true, kwargs...)
    _simulate_population(pr, parallel) do subj, ctx
        simulate(ctx, duration; kwargs...)
    end
end

"""
    simulate(pr::PopulationResult; parallel::Bool=true, kwargs...)

Simulate all subjects with duration inferred per-subject from `max(obs_times) * 1.05`.
Subjects with empty `obs_times` use the population-wide maximum.
"""
function simulate(pr::PopulationResult; parallel::Bool=true, kwargs...)
    # Compute population-wide fallback duration from all obs_times
    all_obs = Float64[]
    for s in pr.population
        append!(all_obs, s.obs_times)
    end
    isempty(all_obs) && error("No obs_times in any subject; pass an explicit duration to simulate()")
    pop_t_end = maximum(all_obs) * 1.05

    _simulate_population(pr, parallel) do subj, ctx
        t_end = isempty(subj.obs_times) ? pop_t_end : maximum(subj.obs_times) * 1.05
        simulate(ctx, t_end; kwargs...)
    end
end

function _simulate_population(fn::Function, pr::PopulationResult, parallel::Bool)
    pop = pr.population
    n = length(pop)
    InjecKit.ensure_cache_capacity!(n)
    results_vec = Vector{Any}(undef, n)

    _sim_one = function(i)
        subj = pop[i]
        id = subj.id
        haskey(pr.contexts, id) || return SimulationError(:population, Dict{Symbol,Any}(), InjecKit.IEvent[],
            ErrorException("No context for subject $id"))
        ctx = pr.contexts[id]
        try
            fn(subj, ctx)
        catch e
            @error "Subject $(subj.id) failed" exception=(e, catch_backtrace())
            SimulationError(:population, ctx.params, ctx.events, e)
        end
    end

    if parallel && n > 1 && Threads.nthreads() > 1
        Threads.@threads for i in 1:n
            results_vec[i] = _sim_one(i)
        end
    else
        for i in 1:n
            results_vec[i] = _sim_one(i)
        end
    end

    new_contexts = Dict{Any, SimContext}()
    new_errors = copy(pr.errors)
    for i in 1:n
        id = pop[i].id
        r = results_vec[i]
        if r isa SimContext
            new_contexts[id] = r
        else
            new_errors[id] = r
            @warn "Subject $id failed: $(sprint(showerror, r.cause))"
        end
    end

    PopulationResult(pop, new_contexts, new_errors)
end

"""
    simulate(; kwargs...)

Zero-arg curried form — infers duration from `prob.tspan` for `SimContext`,
or from `obs_times` for `PopulationResult`.
"""
simulate(; kwargs...) = PipelineStep(:simulate, x -> simulate(x; kwargs...))

# ----------------------------------------------------------
# >> operator — Pipeline composition
# ----------------------------------------------------------

_step_entry(s::PipelineStep) = (name=s.name, fn=s.fn)
_step_entry(f::Function) = (name=:stage, fn=f)

>>(a::Union{Function, PipelineStep}, b::Union{Function, PipelineStep}) = Pipeline([_step_entry(a), _step_entry(b)])
>>(p::Pipeline, f::Union{Function, PipelineStep}) = Pipeline(vcat(p.stages, [_step_entry(f)]))
>>(f::Union{Function, PipelineStep}, p::Pipeline) = Pipeline(vcat([_step_entry(f)], p.stages))
>>(p1::Pipeline, p2::Pipeline) = Pipeline(vcat(p1.stages, p2.stages))

# ----------------------------------------------------------
# Display
# ----------------------------------------------------------

function Base.show(io::IO, ctx::SimContext)
    n_phases = length(ctx.phases)
    n_params = length(ctx.params)
    n_events = length(ctx.events)
    parts = String[]
    push!(parts, "$n_phases phase$(n_phases == 1 ? "" : "s")")
    n_params > 0 && push!(parts, "$n_params params staged")
    n_events > 0 && push!(parts, "$n_events event$(n_events == 1 ? "" : "s") queued")
    print(io, "SimContext: ", join(parts, ", "))
end

function Base.show(io::IO, ::MIME"text/plain", ctx::SimContext)
    println(io, "SimContext")
    if !isempty(ctx.phases)
        println(io, "  Phases:")
        for (i, p) in enumerate(ctx.phases)
            println(io, "    $i. :$(p.name)  ($(p.duration) days)")
        end
    end
    n_params = length(ctx.params)
    n_events = length(ctx.events)
    if n_params > 0 || n_events > 0
        println(io, "  Staged: $n_params params, $n_events events")
    end
    if ctx.solver !== nothing
        print(io, "  Solver: $(ctx.solver)")
    end
end

function Base.show(io::IO, p::Pipeline)
    print(io, "Pipeline($(length(p.stages)) stages)")
end

function Base.show(io::IO, ::MIME"text/plain", p::Pipeline)
    println(io, "Pipeline: $(length(p.stages)) stages")
    for (i, s) in enumerate(p.stages)
        println(io, "  $i. :$(s.name)")
    end
end

"""
    inspect(p::Pipeline)

Print a detailed description of a Pipeline's stages.
"""
function inspect(p::Pipeline)
    println("Pipeline: $(length(p.stages)) stages")
    for (i, s) in enumerate(p.stages)
        println("  $i. :$(s.name)")
    end
end

function Base.show(io::IO, phase::Phase)
    print(io, "Phase(:$(phase.name), $(phase.duration) days)")
end

function Base.show(io::IO, e::SimulationError)
    print(io, "SimulationError(:$(e.phase_name))")
end
