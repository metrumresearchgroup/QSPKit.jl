# Reusable event execution over a prepared InjecKit event plan.

"""
    EventRunner(prob, events; tspan=prob.tspan)

Prepare the event-lowering plan for repeated solves of one
ModelingToolkit-backed ODE problem shape. Execute it with
[`solve_event_runner`](@ref).
"""
struct EventRunner
    base_prob::Any
    solve_prob::Any
    forced_solve_prob::Any
    forced_f::Any
    event_schedule::Any
    event_plan::Any
    lowering::Symbol
    default_tspan::Tuple{Float64, Float64}
end

struct _EventRunnerCacheEntry
    sys_id::UInt
    sys::Any
    f_type::Any
    p_type::Any
    n_states::Int
    tstart::Float64
    signature::Any
    runner::EventRunner
end

struct _PreparedUpdateEventSolveCacheEntry
    base_prob_id::UInt
    base_prob::Any
    raw_keys::Tuple
    tspan::Tuple{Float64, Float64}
    signature::Any
    prepared::Any
end

"""
    PreparedEventSolve(prob, events; params=(), tspan=prob.tspan, base_u0=nothing)

Reusable executor for a fixed problem/update/event shape. It composes
ConfigKit's prepared update layout with InjecKit's prepared event runner so
callers can update parameters/initial conditions and solve eventful problems
without rebuilding either plan on each evaluation.
"""
struct PreparedEventSolve
    base_prob::Any
    solve_prob::Any
    param_keys::Tuple
    update_keys::Tuple
    update_caches::Vector{Any}
    value_buffers::Vector{Vector{Any}}
    event_runner::EventRunner
    defer_initial_state_actions::Bool
    default_tspan::Tuple{Float64, Float64}
    base_u0::Any
end

function _forced_event_problem(prob::ODEProblem, plan)
    plan isa _EventPlan || return prob, nothing
    isempty(plan.state_infusions) && return prob, nothing
    forced_f = _state_infusion_forced_f(prob, plan)
    return SciMLBase.remake(prob; f=forced_f, build_initializeprob=false), forced_f
end

function _apply_runner_state_infusion_forcing(prob::ODEProblem, plan, forced_f)
    plan isa _EventPlan || return prob
    return _apply_state_infusion_forcing(prob, plan; forced_f)
end

function EventRunner(prob::ODEProblem, events_data; tspan=prob.tspan, kwargs...)
    schedule = prepare_events(events_data)
    tspan_f = (Float64(tspan[1]), Float64(tspan[2]))
    isempty(schedule) && return EventRunner(prob, prob, prob, nothing, schedule, nothing, :none, tspan_f)

    hasproperty(prob.f, :sys) && prob.f.sys isa MTK.AbstractSystem ||
        error("EventRunner requires an MTK-backed ODEProblem.")

    sys = prob.f.sys
    lowering = _scheduled_event_lowering(sys, schedule)
    if lowering === :runtime_actions
        plan = _try_callback_event_plan(prob, sys, tspan_f, schedule)
        plan === nothing && error("Could not build an event plan for $(typeof(events_data))")
        forced_prob, forced_f = _forced_event_problem(prob, plan)
        return EventRunner(prob, prob, forced_prob, forced_f, schedule, plan, plan.lowering, tspan_f)
    end

    lowering === :structural_actions ||
        error("Unsupported event lowering $(lowering)")
    u0_p_map = extract_u0_p_from_problem(prob)
    plan = _get_structural_operation_event_plan(sys, u0_p_map, tspan_f, schedule; kwargs...)
    plan === nothing && error("Could not build an event plan for $(typeof(events_data))")
    solve_prob = _remake_event_plan_base_problem(plan.cached_prob, sys, u0_p_map, tspan_f)
    forced_prob, forced_f = _forced_event_problem(solve_prob, plan)
    return EventRunner(prob, solve_prob, forced_prob, forced_f, schedule, plan, plan.lowering, tspan_f)
end

function _event_runner_cache_key(prob::ODEProblem, schedule::EventSchedule, tspan)
    sys = prob.f.sys
    return hash((
        :event_runner,
        objectid(sys),
        typeof(prob.f),
        typeof(prob.p),
        length(prob.u0),
        Float64(tspan[1]),
        schedule.signature,
    ))
end

function _event_runner_entry_matches(entry::_EventRunnerCacheEntry, prob::ODEProblem,
                                     schedule::EventSchedule, tspan)
    sys = prob.f.sys
    return entry.sys_id == objectid(sys) &&
        entry.sys === sys &&
        entry.f_type == typeof(prob.f) &&
        entry.p_type == typeof(prob.p) &&
        entry.n_states == length(prob.u0) &&
        entry.tstart == Float64(tspan[1]) &&
        entry.signature == schedule.signature
end

function cached_event_runner(prob::ODEProblem, schedule::EventSchedule; tspan=prob.tspan)
    isempty(schedule) && return EventRunner(prob, schedule; tspan)
    key = _event_runner_cache_key(prob, schedule, tspan)
    cached = lock(CACHE_LOCK) do
        entry = get(EVENT_RUNNER_CACHE, key, nothing)
        entry isa _EventRunnerCacheEntry &&
            _event_runner_entry_matches(entry, prob, schedule, tspan) ?
            entry.runner :
            nothing
    end
    cached === nothing || return cached

    runner = EventRunner(prob, schedule; tspan)
    entry = _EventRunnerCacheEntry(
        objectid(prob.f.sys),
        prob.f.sys,
        typeof(prob.f),
        typeof(prob.p),
        length(prob.u0),
        Float64(tspan[1]),
        schedule.signature,
        runner,
    )
    return lock(CACHE_LOCK) do
        current = get(EVENT_RUNNER_CACHE, key, nothing)
        if current isa _EventRunnerCacheEntry &&
           _event_runner_entry_matches(current, prob, schedule, tspan)
            current.runner
        else
            EVENT_RUNNER_CACHE[key] = entry
            runner
        end
    end
end

function _with_event_tstops(kw::NamedTuple, event_times)
    isempty(event_times) && return kw
    if :tstops in keys(kw)
        existing = getproperty(kw, :tstops)
        existing_vec = existing isa AbstractVector ? collect(existing) : [existing]
        return merge(kw, (tstops = sort!(unique!(vcat(existing_vec, event_times))),))
    end
    return merge(kw, (tstops = event_times,))
end

function _event_times_for_tspan(event_times, tspan, default_tspan)
    isempty(event_times) && return event_times
    tspan == default_tspan && return event_times
    return Float64[t for t in event_times if tspan[1] <= t <= tspan[2]]
end

_solve_verbose(v::Bool) = v ? SciMLLogging.Standard() : SciMLLogging.None()
_solve_verbose(v) = v

function _normalize_solve_kwargs(kwargs::NamedTuple)
    :verbose in keys(kwargs) || return kwargs
    verbose = getproperty(kwargs, :verbose)
    verbose isa Bool || return kwargs
    retained = Tuple(k => getproperty(kwargs, k) for k in keys(kwargs) if k !== :verbose)
    return merge((; retained...), (verbose = _solve_verbose(verbose),))
end

function runner_solve_kwargs(runner::EventRunner, tspan, kwargs::NamedTuple)
    kwargs = _normalize_solve_kwargs(kwargs)
    plan = runner.event_plan
    plan isa _EventPlan || return kwargs
    event_times = _event_times_for_tspan(plan.event_times, tspan, runner.default_tspan)
    return _with_event_tstops(kwargs, event_times)
end

function _solve_no_event_plan(prob::ODEProblem, alg, kw::NamedTuple)
    if :build_initializeprob in keys(kw)
        retained = Tuple(k => getproperty(kw, k) for k in keys(kw) if k !== :build_initializeprob)
        kw = (; retained...)
    end
    if alg === nothing
        return SciMLBase.solve(prob; kw...)
    end
    return SciMLBase.solve(prob, alg; kw...)
end

function _split_remake_solve_kwargs(kw::NamedTuple)
    remake_names = (:build_initializeprob, :u0)
    has_remake = any(name -> name in keys(kw), remake_names)
    has_remake || return NamedTuple(), kw
    remake_pairs = Tuple(name => getproperty(kw, name)
        for name in remake_names if name in keys(kw))
    retained = Tuple(k => getproperty(kw, k)
        for k in keys(kw) if !(k in remake_names))
    return (; remake_pairs...), (; retained...)
end

function _remake_runner_problem_if_needed(prob::ODEProblem; kwargs...)
    isempty(kwargs) && return prob
    kw = NamedTuple(kwargs)
    if :build_initializeprob in keys(kw)
        return SciMLBase.remake(prob; kw...)
    end
    return SciMLBase.remake(prob; build_initializeprob=false, kw...)
end

function _runner_problem_for(runner::EventRunner, prob::ODEProblem; kwargs...)
    if runner.lowering !== :structural_actions
        return _remake_runner_problem_if_needed(prob; kwargs...)
    end
    if hasproperty(prob.f, :sys) && prob.f.sys === runner.solve_prob.f.sys
        return _remake_runner_problem_if_needed(prob; kwargs...)
    end
    hasproperty(prob.f, :sys) && prob.f.sys isa MTK.AbstractSystem ||
        error("Structural event runner requires an MTK-backed ODEProblem.")
    u0_p_map = extract_u0_p_from_problem(prob)
    return _remake_event_plan_base_problem(
        runner.event_plan.cached_prob, prob.f.sys, u0_p_map, prob.tspan; kwargs...)
end

function _runner_forced_problem_for(runner::EventRunner, prob::ODEProblem)
    plan = runner.event_plan
    plan isa _EventPlan || return prob
    isempty(plan.state_infusions) && return prob
    prob === runner.solve_prob && return runner.forced_solve_prob
    return _apply_runner_state_infusion_forcing(prob, plan, runner.forced_f)
end

function _solve_event_plan(runner::EventRunner, prob::ODEProblem, plan::_EventPlan,
                           alg, kw::NamedTuple; apply_initials::Bool=true)
    plan.lowering in (:runtime_actions, :structural_actions) ||
        error("Expected scheduled event plan, got $(plan.lowering)")
    remake_kwargs, kw = _split_remake_solve_kwargs(kw)
    runtime_prob = !apply_initials || isempty(plan.initial_actions) ?
        prob :
        _apply_callback_event_plan(prob, plan; remake_kwargs...)
    runtime_prob = _runner_forced_problem_for(runner, runtime_prob)
    callback = plan.callback
    if :callback in keys(kw)
        user_callback = getproperty(kw, :callback)
        retained = Tuple(k => getproperty(kw, k) for k in keys(kw) if k !== :callback)
        kw = (; retained...)
        if callback !== nothing
            error("InjecKit scheduled events cannot be combined with an arbitrary user callback. Encode same-time behavior as InjecKit events/actions so ordering is owned by one scheduled event program.")
        end
        callback = user_callback
    end
    if callback === nothing
        return _solve_no_event_plan(runtime_prob, alg, kw)
    end
    if alg === nothing
        return SciMLBase.solve(runtime_prob; callback=callback, kw...)
    end
    return SciMLBase.solve(runtime_prob, alg; callback=callback, kw...)
end

"""
    solve_event_runner(runner, [prob], [alg]; kwargs...)

Solve with a prepared [`EventRunner`](@ref). When `prob` is omitted, the
runner's prepared problem is used. `apply_initials=false` is an integration
hook for callers that already applied time-zero event actions.
"""
function solve_event_runner(runner::EventRunner, prob::ODEProblem, alg=nothing;
                            apply_initials::Bool=true, event_plan=runner.event_plan,
                            kwargs...)
    kw = runner_solve_kwargs(runner, prob.tspan, NamedTuple(kwargs))
    remake_kwargs, _ = _split_remake_solve_kwargs(kw)
    solve_prob = _runner_problem_for(runner, prob; remake_kwargs...)
    if event_plan isa _EventPlan
        return _solve_event_plan(runner, solve_prob, event_plan, alg, kw; apply_initials)
    end
    return _solve_no_event_plan(solve_prob, alg, kw)
end

function solve_event_runner(runner::EventRunner, alg=nothing; kwargs...)
    return solve_event_runner(runner, runner.solve_prob, alg; kwargs...)
end

function _prepared_solve_problem(runner::EventRunner, prob::ODEProblem, tspan)
    if runner.lowering === :structural_actions
        hasproperty(prob.f, :sys) && prob.f.sys isa MTK.AbstractSystem ||
            error("Structural prepared event solves require an MTK-backed ODEProblem.")
        u0_p_map = extract_u0_p_from_problem(prob)
        return _remake_event_plan_base_problem(
            runner.event_plan.cached_prob, prob.f.sys, u0_p_map, tspan)
    end
    return tspan == prob.tspan ? prob :
        SciMLBase.remake(prob; tspan=tspan, build_initializeprob=false)
end

_prepared_param_keys(::Nothing) = ()
_prepared_param_keys(params::NamedTuple) = Tuple(keys(params))
_prepared_param_keys(params::Tuple) = params
_prepared_param_keys(params) = Tuple(params)

function PreparedEventSolve(prob::ODEProblem, events_data; params=(), tspan=prob.tspan,
                            base_u0=nothing)
    schedule = prepare_events(events_data)
    tspan_f = (Float64(tspan[1]), Float64(tspan[2]))
    event_runner = cached_event_runner(prob, schedule; tspan=tspan_f)
    solve_prob = _prepared_solve_problem(event_runner, prob, tspan_f)
    raw_keys = _prepared_param_keys(params)
    update_keys = raw_keys
    defer_initial_state_actions = false

    if event_runner.lowering in (:runtime_actions, :structural_actions)
        dummy_values = ntuple(_ -> 0.0, length(raw_keys))
        update_keys, _, _, _ =
            _merge_callback_plan_initials(
                solve_prob, event_runner.event_plan, raw_keys, dummy_values, base_u0;
                defer_state_actions=false)
        defer_initial_state_actions = base_u0 === nothing &&
            ConfigKit.update_keys_affect_initials(solve_prob, update_keys; strict=false)
    end

    update_caches = Any[
        isempty(update_keys) ? nothing : ConfigKit.UpdateCache(solve_prob, update_keys; strict=false)
        for _ in 1:Threads.maxthreadid()
    ]
    value_buffers = [Vector{Any}(undef, length(raw_keys)) for _ in 1:Threads.maxthreadid()]

    return PreparedEventSolve(
        prob,
        solve_prob,
        raw_keys,
        update_keys,
        update_caches,
        value_buffers,
        event_runner,
        defer_initial_state_actions,
        tspan_f,
        base_u0,
    )
end

_prepared_override_value(overrides::NamedTuple, key::Symbol) = getproperty(overrides, key)
_prepared_override_value(overrides, key) = overrides[key]

function _fill_prepared_values!(buffer::Vector{Any}, keys::Tuple, overrides::NamedTuple)
    @inbounds for i in eachindex(keys)
        buffer[i] = _prepared_override_value(overrides, keys[i])
    end
    return buffer
end

function _fill_prepared_values!(buffer::Vector{Any}, keys::Tuple, overrides::Tuple)
    length(overrides) == length(keys) ||
        throw(ArgumentError("Expected $(length(keys)) values for PreparedEventSolve, got $(length(overrides))."))
    @inbounds for i in eachindex(keys)
        buffer[i] = overrides[i]
    end
    return buffer
end

function _fill_prepared_values!(buffer::Vector{Any}, keys::Tuple, overrides::AbstractVector)
    length(overrides) == length(keys) ||
        throw(ArgumentError("Expected $(length(keys)) values for PreparedEventSolve, got $(length(overrides))."))
    @inbounds for i in eachindex(keys)
        buffer[i] = overrides[i]
    end
    return buffer
end

function _fill_prepared_values!(buffer::Vector{Any}, keys::Tuple, overrides)
    @inbounds for i in eachindex(keys)
        buffer[i] = _prepared_override_value(overrides, keys[i])
    end
    return buffer
end

function _prepared_tspan(prepared::PreparedEventSolve, duration, tspan)
    resolved = if tspan !== nothing
        (Float64(tspan[1]), Float64(tspan[2]))
    elseif duration !== nothing
        (prepared.default_tspan[1], prepared.default_tspan[1] + Float64(duration))
    else
        prepared.default_tspan
    end
    resolved[1] == prepared.default_tspan[1] ||
        error("Changing tspan[1] requires a new PreparedEventSolve because event start-time actions are prepared relative to the runner start time.")
    return resolved
end

function _prepared_remake_if_needed(prob::ODEProblem, tspan, u0)
    if u0 === nothing && tspan == prob.tspan
        return prob
    end
    kwargs = (tspan = tspan,)
    u0 === nothing || (kwargs = merge(kwargs, (u0 = u0,)))
    return SciMLBase.remake(prob; build_initializeprob=false, kwargs...)
end

function _tunable_parameter_index(prob::ODEProblem, key)
    idx = SymbolicIndexingInterface.parameter_index(prob, key)
    idx === nothing && error("Event parameter $key is not present in the problem.")
    getfield(idx, :portion) == Tunable() ||
        error("Event parameter $key is not a tunable parameter.")
    flat_idx = getfield(idx, :idx)
    flat_idx isa Integer ||
        error("Event parameter $key is not scalar in the tunable parameter vector.")
    return Int(flat_idx)
end

"""
    tunable_parameter_index(prob, key)

Return the scalar index of `key` in the problem's tunable parameter vector.
Raise an error when the key is absent, non-tunable, or non-scalar.
"""
tunable_parameter_index(prob::ODEProblem, key) = _tunable_parameter_index(prob, key)

function _runtime_action_groups(runtime_actions::Dict{Float64, Vector{_RuntimeAction}})
    times = sort!(collect(keys(runtime_actions)))
    isempty(times) && return nothing
    action_groups = Tuple(_RuntimeActionGroup(runtime_actions[time]) for time in times)
    return times, action_groups
end

struct _ActiveTunableSensitivityBoundary
    indexing_prob
    full_p_template::Vector{Float64}
    active_keys::Tuple
    active_values
    active_to_flat::Vector{Int}
end

function _active_tunable_boundary(indexing_prob::ODEProblem,
                                  flat_solve_prob::ODEProblem,
                                  active_params::NamedTuple)
    active_keys = Tuple(keys(active_params))
    active_values = collect(values(active_params))
    active_to_flat = Vector{Int}(undef, length(active_keys))
    for (j, key) in pairs(active_keys)
        active_to_flat[j] = try
            _tunable_parameter_index(indexing_prob, key)
        catch
            0
        end
    end
    return _ActiveTunableSensitivityBoundary(
        indexing_prob,
        Float64.(collect(flat_solve_prob.p)),
        active_keys,
        active_values,
        active_to_flat)
end

function _active_tunable_problem(flat_solve_prob::ODEProblem,
                                 boundary::_ActiveTunableSensitivityBoundary)
    full_p_ref = Ref(copy(boundary.full_p_template))
    full_p_work = similar(boundary.full_p_template)
    active_to_flat = boundary.active_to_flat
    flat_f = flat_solve_prob.f

    function active_f!(du, u, p_active, t)
        T = promote_type(eltype(full_p_ref[]), eltype(p_active), eltype(u))
        full_p = if T === eltype(full_p_work)
            copyto!(full_p_work, full_p_ref[])
            full_p_work
        else
            p = Vector{T}(undef, length(full_p_ref[]))
            @inbounds for idx in eachindex(full_p_ref[])
                p[idx] = full_p_ref[][idx]
            end
            p
        end
        @inbounds for j in eachindex(active_to_flat)
            flat_idx = active_to_flat[j]
            flat_idx == 0 && continue
            full_p[flat_idx] = p_active[j]
        end
        return flat_f(du, u, full_p, t)
    end

    active_f = SciMLBase.ODEFunction{true}(active_f!)
    active_prob = SciMLBase.remake(
        flat_solve_prob; f=active_f, p=copy(boundary.active_values),
        build_initializeprob=false)
    return active_prob, full_p_ref
end

function _active_tunable_callback_from_actions(runtime_actions,
                                               boundary::_ActiveTunableSensitivityBoundary,
                                               full_p_ref)
    action_groups = _runtime_action_groups(runtime_actions)
    action_groups === nothing && return nothing
    times, groups = action_groups
    active_by_flat = Dict{Int, Int}()
    for (j, flat_idx) in pairs(boundary.active_to_flat)
        flat_idx == 0 && continue
        active_by_flat[flat_idx] = j
    end

    function apply_group!(integrator, group)
        for action in group.state_actions
            if action isa _RuntimeStateAdd
                integrator.u[action.index] += action.amount
            else
                integrator.u[action.index] = action.value
            end
        end
        for action in group.param_adds
            flat_idx = _tunable_parameter_index(boundary.indexing_prob, action.key)
            active_idx = get(active_by_flat, flat_idx, 0)
            if active_idx == 0
                full_p_ref[][flat_idx] += action.amount
            else
                integrator.p[active_idx] += action.amount
                full_p_ref[][flat_idx] += action.amount
            end
        end
        for action in group.param_sets
            flat_idx = _tunable_parameter_index(boundary.indexing_prob, action.key)
            active_idx = get(active_by_flat, flat_idx, 0)
            if active_idx == 0
                full_p_ref[][flat_idx] = action.value
            else
                integrator.p[active_idx] = action.value
                full_p_ref[][flat_idx] = action.value
            end
        end
        return nothing
    end

    return _scheduled_action_callback(
        times, groups, apply_group!; save_positions=(false, false))
end

function _reject_user_callback_for_active_sensitivity(solve_kwargs)
    :callback in keys(solve_kwargs) ||
        return solve_kwargs
    error("InjecKit active sensitivity problems do not accept arbitrary user callbacks. Encode scheduled state/parameter changes as InjecKit events so the active parameter boundary can remap them.")
end

function _merge_user_callback(callback, solve_kwargs)
    if :callback in keys(solve_kwargs)
        user_callback = getproperty(solve_kwargs, :callback)
        retained = Tuple(k => getproperty(solve_kwargs, k)
            for k in keys(solve_kwargs) if k !== :callback)
        solve_kwargs = (; retained...)
        if callback !== nothing
            error("InjecKit scheduled events cannot be combined with an arbitrary user callback. Encode same-time behavior as InjecKit events/actions so ordering is owned by one scheduled event program.")
        end
        callback = user_callback
    end
    return callback, solve_kwargs
end

function _prepared_runtime_problem(prepared::PreparedEventSolve, prob_updated,
                                   solve_event_plan, solve_kwargs)
    remake_kwargs, solve_kwargs = _split_remake_solve_kwargs(solve_kwargs)
    solve_prob = _runner_problem_for(
        prepared.event_runner, prob_updated; remake_kwargs...)
    callback = nothing
    if solve_event_plan isa _EventPlan
        solve_prob = isempty(solve_event_plan.initial_actions) ?
            solve_prob :
            _apply_callback_event_plan(solve_prob, solve_event_plan; remake_kwargs...)
        callback = solve_event_plan.callback
        solve_prob = _runner_forced_problem_for(
            prepared.event_runner, solve_prob)
        callback, solve_kwargs = _merge_user_callback(callback, solve_kwargs)
    end
    return solve_prob, callback, solve_kwargs
end

function _prepared_active_tunable_sensitivity_problem(prepared::PreparedEventSolve,
                                                      prob_updated,
                                                      solve_event_plan,
                                                      solve_kwargs,
                                                      active_params::NamedTuple)
    remake_kwargs, solve_kwargs = _split_remake_solve_kwargs(solve_kwargs)
    solve_kwargs = _reject_user_callback_for_active_sensitivity(solve_kwargs)
    solve_prob = _runner_problem_for(
        prepared.event_runner, prob_updated; remake_kwargs...)
    indexing_prob = solve_prob
    tunable, = canonicalize(Tunable(), solve_prob.p)
    solve_prob = SciMLBase.remake(
        solve_prob; p=collect(tunable), build_initializeprob=false)
    if solve_event_plan isa _EventPlan
        solve_prob = isempty(solve_event_plan.initial_actions) ?
            solve_prob :
            _apply_callback_event_plan(solve_prob, solve_event_plan; remake_kwargs...)
        solve_prob = _apply_runner_state_infusion_forcing(
            solve_prob, solve_event_plan, prepared.event_runner.forced_f)
    end
    boundary = _active_tunable_boundary(indexing_prob, solve_prob, active_params)
    active_prob, full_p_ref = _active_tunable_problem(solve_prob, boundary)
    callback = solve_event_plan isa _EventPlan ?
        _active_tunable_callback_from_actions(
            solve_event_plan.runtime_actions, boundary, full_p_ref) :
        nothing
    return active_prob, callback, solve_kwargs, indexing_prob
end

function _with_prepared_event_context(f::Function, prepared::PreparedEventSolve,
                                      overrides=NamedTuple(); duration=nothing,
                                      tspan=nothing, base_u0=prepared.base_u0,
                                      kwargs...)
    tid = Threads.threadid()
    raw_values = _fill_prepared_values!(
        prepared.value_buffers[tid], prepared.param_keys, overrides)
    update_keys = prepared.update_keys
    update_values = raw_values
    update_u0 = base_u0
    event_plan = prepared.event_runner.event_plan
    solve_event_plan = event_plan

    if prepared.event_runner.lowering in (:runtime_actions, :structural_actions)
        update_keys, update_values, update_u0, solve_events =
            _merge_callback_plan_initials(
                prepared.solve_prob, event_plan, prepared.param_keys, raw_values,
                base_u0;
                defer_state_actions=prepared.defer_initial_state_actions)
        solve_event_plan = solve_events
    end

    solve_tspan = _prepared_tspan(prepared, duration, tspan)
    solve_kwargs = runner_solve_kwargs(
        prepared.event_runner, solve_tspan, NamedTuple(kwargs))
    update_kwargs = (tspan = solve_tspan,)
    update_u0 === nothing || (update_kwargs = merge(update_kwargs, (u0 = update_u0,)))

    if isempty(update_keys)
        prob_updated = _prepared_remake_if_needed(prepared.solve_prob, solve_tspan, update_u0)
        return f(prob_updated, solve_event_plan, solve_kwargs)
    end

    cache = prepared.update_caches[tid]
    return ConfigKit.with_update_cache(cache, update_values; update_kwargs...) do prob_updated
        return f(prob_updated, solve_event_plan, solve_kwargs)
    end
end

"""
    with_prepared_event_problem(f, prepared, overrides=NamedTuple(); kwargs...)

Apply prepared updates/events and call `f(solve_prob, callback, solve_kwargs)`.
The supplied values borrow thread-local preparation storage and should not be
retained after `f` returns.
"""
function with_prepared_event_problem(f::Function, prepared::PreparedEventSolve,
                                     overrides=NamedTuple(); duration=nothing,
                                     tspan=nothing, base_u0=prepared.base_u0,
                                     kwargs...)
    return _with_prepared_event_context(
        prepared, overrides; duration, tspan, base_u0, kwargs...) do prob_updated, solve_event_plan, solve_kwargs
        solve_prob, callback, solve_kwargs = _prepared_runtime_problem(
            prepared, prob_updated, solve_event_plan, solve_kwargs)
        return f(solve_prob, callback, solve_kwargs)
    end
end

"""
    with_prepared_active_tunable_sensitivity_problem(f, prepared, overrides;
                                                      active_params, kwargs...)

Call `f` with an active-parameter sensitivity problem, its scheduled callback,
normalized solve keywords, and the indexing problem. This is a low-level
integration API for sensitivity engines.
"""
function with_prepared_active_tunable_sensitivity_problem(
    f::Function, prepared::PreparedEventSolve, overrides=NamedTuple();
    active_params::NamedTuple=NamedTuple(), duration=nothing, tspan=nothing,
    base_u0=prepared.base_u0, kwargs...)
    return _with_prepared_event_context(
        prepared, overrides; duration, tspan, base_u0, kwargs...) do prob_updated, solve_event_plan, solve_kwargs
        solve_prob, callback, solve_kwargs, indexing_prob =
            _prepared_active_tunable_sensitivity_problem(
                prepared, prob_updated, solve_event_plan, solve_kwargs, active_params)
        return f(solve_prob, callback, solve_kwargs, indexing_prob)
    end
end

"""
    with_prepared_event_solve(f, prepared, overrides=NamedTuple(); kwargs...)

Run a [`PreparedEventSolve`](@ref), then call `f(solution, updated_problem)`.
Calling `prepared(overrides; kwargs...)` is the convenient solution-only form.
"""
function with_prepared_event_solve(f::Function, prepared::PreparedEventSolve,
                                   overrides=NamedTuple(); alg=nothing,
                                   solver=nothing, duration=nothing,
                                   tspan=nothing, base_u0=prepared.base_u0,
                                   kwargs...)
    tid = Threads.threadid()
    raw_values = _fill_prepared_values!(
        prepared.value_buffers[tid], prepared.param_keys, overrides)
    update_keys = prepared.update_keys
    update_values = raw_values
    update_u0 = base_u0
    event_plan = prepared.event_runner.event_plan
    solve_event_plan = event_plan

    if prepared.event_runner.lowering in (:runtime_actions, :structural_actions)
        update_keys, update_values, update_u0, solve_events =
            _merge_callback_plan_initials(
                prepared.solve_prob, event_plan, prepared.param_keys, raw_values,
                base_u0;
                defer_state_actions=prepared.defer_initial_state_actions)
        solve_event_plan = solve_events
    end

    solve_tspan = _prepared_tspan(prepared, duration, tspan)
    solve_alg = solver === nothing ? alg : solver
    solve_kwargs = runner_solve_kwargs(prepared.event_runner, solve_tspan, NamedTuple(kwargs))
    update_kwargs = (tspan = solve_tspan,)
    update_u0 === nothing || (update_kwargs = merge(update_kwargs, (u0 = update_u0,)))

    if isempty(update_keys)
        prob_updated = _prepared_remake_if_needed(prepared.solve_prob, solve_tspan, update_u0)
        sol = solve_event_runner(
            prepared.event_runner, prob_updated, solve_alg; event_plan=solve_event_plan,
            solve_kwargs...)
        return f(sol, prob_updated)
    end

    cache = prepared.update_caches[tid]
    return ConfigKit.with_update_cache(cache, update_values; update_kwargs...) do prob_updated
        sol = solve_event_runner(
            prepared.event_runner, prob_updated, solve_alg; event_plan=solve_event_plan,
            solve_kwargs...)
        return f(sol, prob_updated)
    end
end

function (prepared::PreparedEventSolve)(overrides=NamedTuple(); kwargs...)
    return with_prepared_event_solve(prepared, overrides; kwargs...) do sol, _
        sol
    end
end

function _prepared_update_event_cache_key(source::ConfigKit.PreparedUpdateSource,
                                          schedule::EventSchedule)
    return hash((
        :prepared_update_event_solve,
        objectid(source.base_prob),
        source.raw_keys,
        source.tspan,
        schedule.signature,
    ))
end

function _prepared_update_event_entry_matches(entry::_PreparedUpdateEventSolveCacheEntry,
                                              source::ConfigKit.PreparedUpdateSource,
                                              schedule::EventSchedule)
    return entry.base_prob_id == objectid(source.base_prob) &&
        entry.base_prob === source.base_prob &&
        entry.raw_keys == source.raw_keys &&
        entry.tspan == source.tspan &&
        entry.signature == schedule.signature
end

function _cached_prepared_update_event_solve(source::ConfigKit.PreparedUpdateSource,
                                             schedule::EventSchedule)
    key = _prepared_update_event_cache_key(source, schedule)
    cached = lock(CACHE_LOCK) do
        entry = get(PREPARED_UPDATE_EVENT_SOLVE_CACHE, key, nothing)
        entry isa _PreparedUpdateEventSolveCacheEntry &&
            _prepared_update_event_entry_matches(entry, source, schedule) ?
            entry.prepared :
            nothing
    end
    cached === nothing || return cached

    prepared = PreparedEventSolve(source.base_prob, schedule;
        params=source.raw_keys, tspan=source.tspan)
    entry = _PreparedUpdateEventSolveCacheEntry(
        objectid(source.base_prob),
        source.base_prob,
        source.raw_keys,
        source.tspan,
        schedule.signature,
        prepared,
    )
    return lock(CACHE_LOCK) do
        current = get(PREPARED_UPDATE_EVENT_SOLVE_CACHE, key, nothing)
        if current isa _PreparedUpdateEventSolveCacheEntry &&
           _prepared_update_event_entry_matches(current, source, schedule)
            current.prepared
        else
            PREPARED_UPDATE_EVENT_SOLVE_CACHE[key] = entry
            prepared
        end
    end
end

function _solve_configkit_updated_events(prob::ODEProblem, schedule::EventSchedule,
                                         alg=nothing; kwargs...)
    source = ConfigKit.prepared_update_source(prob)
    source === nothing && return nothing
    source.updated_prob === prob || return nothing

    prepared = _cached_prepared_update_event_solve(source, schedule)
    return prepared(source.raw_values; alg=alg, kwargs...)
end
