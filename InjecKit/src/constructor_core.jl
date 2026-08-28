"""
Core ODEProblem constructor logic for InjecKit.

This module contains the event-plan builder and ODEProblem application helpers.
"""

using SciMLStructures: Tunable, Initials, canonicalize, replace

"""
    _value_eltype_from_map(d)

Compute the promoted numeric element type from a Dict's values.
Used to determine if Dual numbers are present so buffers can be promoted.
"""
function _value_eltype_from_map(d)
    isempty(d) && return Float64
    T = Float64
    for v in values(d)
        if v isa Number
            T = promote_type(T, typeof(v))
        end
    end
    T
end

"""
    _promote_params(ps, T)

Promote ALL numeric partitions of an MTKParameters object to element type T.
This ensures ForwardDiff Dual numbers don't cause type mismatches during
ODE solve when some partitions are Float64 and others are Dual.
"""
function _promote_params(ps, T)
    # Promote tunable partition
    tunable, = canonicalize(Tunable(), ps)
    buffer_t = T.(tunable)
    ps_new = replace(Tunable(), ps, buffer_t)

    # Promote initials partition (contains initial conditions for states)
    try
        initials, = canonicalize(Initials(), ps_new)
        if eltype(initials) !== T
            buffer_i = T.(initials)
            ps_new = replace(Initials(), ps_new, buffer_i)
        end
    catch
        # Some problems may not have an Initials partition
    end

    ps_new
end

"""
    _name_aware_merge(dicts...)

Merge multiple Dict{Any,Any} maps where keys may represent the same variable
under different object identities (e.g. user-created `C` vs system-internal
`C(t)`).  Later dicts take priority, just like `Base.merge`, but duplicates are
detected by *variable name* (`MTK.getname`) rather than object identity.

This prevents a common footgun: the user passes `Dict(C => 25.0)` while
`MTK.get_initial_conditions(sys)` returns a key for the same variable as a
different `Num` object.  A plain `merge` would keep both entries, and
downstream code that iterates by name could pick up the stale default.
"""
function _name_aware_merge(dicts...)
    result = Dict{Any,Any}()
    name_to_key = Dict{Any,Any}()  # variable name → key currently stored in result

    for d in dicts
        for (key, val) in d
            key_name = try MTK.getname(key) catch; key end
            if haskey(name_to_key, key_name)
                # Remove older entry with the same name
                delete!(result, name_to_key[key_name])
            end
            result[key] = val
            name_to_key[key_name] = key
        end
    end

    return result
end

"""
    _resolve_keys_to_system(u0_p_map, sys)

Re-key a u0/p Dict so that every key that matches a system unknown or
parameter (by name) is replaced with the actual system variable object.
This ensures that `SymbolicIndexingInterface.parameter_index` / `setp`
can find the variable even when the caller used a pre-compilation `Num`
object whose identity differs from the compiled system's variables.
"""
function _resolve_keys_to_system(u0_p_map, sys)
    # Build name → system variable mapping
    sys_vars = Dict{Symbol, Any}()
    for var in MTK.unknowns(sys)
        sys_vars[MTK.getname(var)] = var
    end
    for param in MTK.parameters(sys)
        sys_vars[MTK.getname(param)] = param
    end
    for param in try MTK.bound_parameters(sys) catch; [] end
        sys_vars[MTK.getname(param)] = param
    end

    resolved = Dict{Any, Any}()
    for (key, val) in u0_p_map
        key_name = try MTK.getname(key) catch; nothing end
        if key_name !== nothing && haskey(sys_vars, key_name)
            resolved[sys_vars[key_name]] = val
        else
            resolved[key] = val  # Keep original as fallback
        end
    end
    return resolved
end

function _is_supported_runtime_event(prob::ODEProblem, event::IEvent)
    if event.evid == 1
        rate = missing_to_nothing(event.rate)
        duration = missing_to_nothing(event.duration)
        amt = missing_to_nothing(event.amt)
        amt === nothing && is_bolus_dose(rate, duration) && return true
        if is_bolus_dose(rate, duration)
            return event.cmt !== nothing
        end
        return event.cmt !== nothing &&
            (SciMLBase.variable_index(prob, event.cmt) !== nothing ||
             SymbolicIndexingInterface.parameter_index(prob, event.cmt) !== nothing)
    elseif event.evid == 2
        isempty(event.param_changes) && return false
        return all(param -> SymbolicIndexingInterface.parameter_index(prob, param) !== nothing,
                   keys(event.param_changes))
    elseif event.evid == 8
        return event.cmt !== nothing && event.amt !== nothing &&
            SciMLBase.variable_index(prob, event.cmt) !== nothing
    end
    return false
end

struct _RuntimeStateAdd{K,A}
    index::Int
    key::K
    amount::A
end

struct _RuntimeStateSet{K,V}
    index::Int
    key::K
    value::V
end

struct _RuntimeParamAdd{G,K,A}
    getter::G
    key::K
    amount::A
end

struct _RuntimeParamSet{K,V}
    key::K
    value::V
end

const _RuntimeAction = Union{
    _RuntimeStateAdd,
    _RuntimeStateSet,
    _RuntimeParamAdd,
    _RuntimeParamSet,
}

struct _StateInfusionForcing{R}
    index::Int
    start::Float64
    stop::Float64
    rate::R
end

struct _InfusionForcedODEFunction{F,S,I}
    f::F
    sys::S
    forcings::I
end

function (f::_InfusionForcedODEFunction)(du, u, p, t)
    f.f(du, u, p, t)
    @inbounds for forcing in f.forcings
        if forcing.start <= t < forcing.stop
            du[forcing.index] += forcing.rate
        end
    end
    return nothing
end

struct _RuntimeActionGroup{SA,PA,PS}
    state_actions::SA
    param_adds::PA
    param_sets::PS
end

function _RuntimeActionGroup(actions::Vector{_RuntimeAction})
    state_actions = ()
    param_adds = ()
    param_sets = ()
    for action in actions
        if action isa Union{_RuntimeStateAdd, _RuntimeStateSet}
            state_actions = (state_actions..., action)
        elseif action isa _RuntimeParamAdd
            param_adds = (param_adds..., action)
        else
            param_sets = (param_sets..., action)
        end
    end
    return _RuntimeActionGroup(state_actions, param_adds, param_sets)
end

struct _InitialStateAdd
    index::Int
    variable::Any
    initial_key::Any
    amount::Any
end

struct _InitialStateSet
    index::Int
    variable::Any
    initial_key::Any
    value::Any
end

struct _InitialParamAdd
    getter::Any
    key::Any
    amount::Any
end

struct _InitialParamSet
    key::Any
    value::Any
end

const _InitialAction = Union{
    _InitialStateAdd,
    _InitialStateSet,
    _InitialParamAdd,
    _InitialParamSet,
}

struct _EventPlan
    lowering::Symbol
    signature::Any
    initial_actions::Vector{_InitialAction}
    runtime_actions::Dict{Float64, Vector{_RuntimeAction}}
    state_infusions::Vector{_StateInfusionForcing}
    callback::Any
    cached_prob::Any
    event_times::Vector{Float64}
    expanded_events::Vector{IEvent}
end

struct _EventPlanCacheEntry
    sys_id::UInt
    sys::Any
    f_type::Any
    p_type::Any
    n_states::Int
    tstart::Float64
    init_mode::Any
    signature::Any
    plan::_EventPlan
end

function _add_runtime_action!(actions::Dict{Float64, Vector{_RuntimeAction}}, time, action)
    push!(get!(actions, Float64(time), _RuntimeAction[]), action)
    return actions
end

function _scheduled_action_callback(times::AbstractVector{Float64},
                                    action_groups,
                                    apply_group!::Function;
                                    save_positions=(true, true))
    isempty(times) && return nothing

    callbacks = map(eachindex(times)) do i
        group = action_groups[i]
        function affect!(integrator)
            apply_group!(integrator, group)
            return nothing
        end
        DiffEqCallbacks.PresetTimeCallback(
            times[i], affect!;
            save_positions=save_positions,
            sort_inplace=false)
    end
    return SciMLBase.CallbackSet(callbacks...)
end

function _apply_runtime_action_group!(integrator, group::_RuntimeActionGroup)
    for action in group.state_actions
        if action isa _RuntimeStateAdd
            ConfigKit.update(
                integrator,
                (action.key => integrator[action.key] + action.amount,),
            )
        else
            ConfigKit.update(integrator, (action.key => action.value,))
        end
    end
    for action in group.param_adds
        ConfigKit.update(integrator, (action.key => action.getter(integrator) + action.amount,))
    end
    for action in group.param_sets
        ConfigKit.update(integrator, (action.key => action.value,))
    end
    return nothing
end

function _runtime_callback_from_actions(actions::Dict{Float64, Vector{_RuntimeAction}})
    times = sort!(collect(keys(actions)))
    isempty(times) && return nothing

    action_groups = Tuple(_RuntimeActionGroup(actions[time]) for time in times)
    return _scheduled_action_callback(
        times, action_groups, _apply_runtime_action_group!)
end

function _scheduled_event_times(runtime_actions::Dict{Float64, Vector{_RuntimeAction}},
                                state_infusions::Vector{_StateInfusionForcing})
    times = collect(keys(runtime_actions))
    for forcing in state_infusions
        push!(times, forcing.start)
        push!(times, forcing.stop)
    end
    return sort!(unique!(Float64.(times)))
end

_event_scalar_signature(x) =
    x === nothing ? (:nothing,) :
    x === missing ? (:missing,) :
    (typeof(x), x)

function _event_symbol_signature(x)
    x === nothing && return (:nothing,)
    x === missing && return (:missing,)
    x isa Symbol && return (:name, _canonical_reference_symbol(x))
    x isa AbstractString && return (:name, _canonical_reference_symbol(x))
    name = try Symbol(MTK.getname(x)) catch; nothing end
    name === nothing || return (:name, name)
    return (typeof(x), string(x))
end

function _event_param_changes_signature(param_changes)
    isempty(param_changes) && return ()
    pairs = Vector{Any}(undef, length(param_changes))
    i = 1
    for key in sort!(collect(keys(param_changes)); by=string)
        pairs[i] = (_event_symbol_signature(key), _event_scalar_signature(param_changes[key]))
        i += 1
    end
    return Tuple(pairs)
end

function _event_plan_signature(events::Vector{IEvent})
    rows = Vector{Any}(undef, length(events))
    for (i, event) in pairs(events)
        rows[i] = (
            _event_scalar_signature(event.time),
            _event_scalar_signature(event.evid),
            _event_symbol_signature(event.cmt),
            _event_scalar_signature(event.amt),
            _event_scalar_signature(event.rate),
            _event_scalar_signature(event.duration),
            _event_scalar_signature(event.ii),
            _event_scalar_signature(event.addl),
            _event_scalar_signature(event.ss),
            _event_param_changes_signature(event.param_changes),
        )
    end
    return Tuple(rows)
end

_event_plan_signature(schedule::EventSchedule) = schedule.signature

function _snapshot_event(event::IEvent)
    return IEvent(
        event.time,
        event.cmt,
        event.amt,
        event.rate,
        event.duration,
        event.evid,
        event.ii,
        event.addl,
        event.ss,
        copy(event.param_changes),
    )
end

function _normalize_event_data(events_data)
    if events_data isa DataFrame
        return dataframe_to_mrgevents(events_data)
    elseif events_data isa IEvent
        return IEvent[events_data]
    elseif events_data isa Vector{IEvent}
        return collect(IEvent, events_data)
    elseif events_data isa AbstractVector{<:IEvent}
        return collect(IEvent, events_data)
    elseif events_data isa EventSchedule
        return collect(IEvent, events_data.events)
    else
        error("Unsupported events_data type: $(typeof(events_data)). Supported types: DataFrame, Vector{IEvent}, IEvent, Vector{SymbolicDiscreteCallback}")
    end
end

"""
    prepare_events(events_data) -> EventSchedule

Internal event-ingestion helper used by solve/SimKit hot paths. Public APIs
accept raw `IEvent`, `Vector{IEvent}`, and DataFrame inputs directly and retain
this normalized representation where repeated evaluations need it.
"""
prepare_events(schedule::EventSchedule) = schedule

function prepare_events(events_data)
    raw_events_data = _normalize_event_data(events_data)
    snapshot = IEvent[_snapshot_event(event) for event in raw_events_data]
    return EventSchedule(Tuple(snapshot), _event_plan_signature(snapshot))
end

_event_plan_cache_key(lowering::Symbol, sys, tstart, init_mode, signature) =
    hash((:event_plan, lowering, objectid(sys), Float64(tstart), init_mode, signature))

function _event_plan_entry_matches(entry::_EventPlanCacheEntry, lowering::Symbol,
                                   sys, prob, tstart, init_mode, signature)
    prob_matches = if prob === nothing || entry.plan.lowering == :structural_actions
        true
    else
        entry.f_type == typeof(prob.f) &&
            entry.p_type == typeof(prob.p) &&
            entry.n_states == length(prob.u0)
    end
    return entry.sys_id == objectid(sys) &&
        entry.sys === sys &&
        entry.plan.lowering == lowering &&
        prob_matches &&
        entry.tstart == Float64(tstart) &&
        entry.init_mode == init_mode &&
        entry.signature == signature
end

function _initial_state_key(prob::ODEProblem, var)
    initial_key = try MTK.Initial(var) catch; nothing end
    initial_key === nothing && return nothing
    SymbolicIndexingInterface.parameter_index(prob, initial_key) === nothing && return nothing
    return initial_key
end

function _add_event_to_plan!(prob::ODEProblem, tstart, event::IEvent,
                             initial_actions::Vector{_InitialAction},
                             runtime_actions::Dict{Float64, Vector{_RuntimeAction}},
                             state_infusions::Vector{_StateInfusionForcing})
    _is_supported_runtime_event(prob, event) || return false

    time = Float64(event.time)
    time < Float64(tstart) && return false
    at_start = time == Float64(tstart)

    if event.evid == 1
        rate = missing_to_nothing(event.rate)
        duration = missing_to_nothing(event.duration)
        amt = missing_to_nothing(event.amt)
        if amt === nothing && is_bolus_dose(rate, duration)
            return true
        end
        if is_bolus_dose(rate, duration)
            idx = SciMLBase.variable_index(prob, event.cmt)
            idx === nothing && return false
            if at_start
                initial_key = _initial_state_key(prob, event.cmt)
                push!(initial_actions, _InitialStateAdd(idx, event.cmt, initial_key, amt))
            else
                _add_runtime_action!(runtime_actions, time, _RuntimeStateAdd(idx, event.cmt, amt))
            end
            return true
        end

        _, calculated_rate, _ = calculate_infusion_parameters(event.amt, rate, duration)
        stop_time = Float64(calculate_infusion_stop_time(event.time, event.amt, rate, duration))
        state_idx = SciMLBase.variable_index(prob, event.cmt)
        if state_idx !== nothing
            stop_time <= Float64(tstart) && return false
            push!(state_infusions, _StateInfusionForcing(
                Int(state_idx), time, stop_time, calculated_rate))
            return true
        end

        stop_time < Float64(tstart) && return false
        getter = SciMLBase.getp(prob, event.cmt)
        if at_start
            push!(initial_actions, _InitialParamAdd(getter, event.cmt, calculated_rate))
        else
            _add_runtime_action!(runtime_actions, time, _RuntimeParamAdd(getter, event.cmt, calculated_rate))
        end
        if stop_time == Float64(tstart)
            push!(initial_actions, _InitialParamAdd(getter, event.cmt, -calculated_rate))
        else
            _add_runtime_action!(runtime_actions, stop_time, _RuntimeParamAdd(getter, event.cmt, -calculated_rate))
        end
        return true
    elseif event.evid == 2
        for (param, value) in event.param_changes
            if at_start
                push!(initial_actions, _InitialParamSet(param, value))
            else
                _add_runtime_action!(runtime_actions, time, _RuntimeParamSet(param, value))
            end
        end
        return true
    elseif event.evid == 8
        idx = SciMLBase.variable_index(prob, event.cmt)
        idx === nothing && return false
        if at_start
            initial_key = _initial_state_key(prob, event.cmt)
            push!(initial_actions, _InitialStateSet(
                idx, event.cmt, initial_key, event.amt))
        else
            _add_runtime_action!(runtime_actions, time,
                _RuntimeStateSet(idx, event.cmt, event.amt))
        end
        return true
    end

        return false
    end

function _build_callback_event_plan(prob::ODEProblem, sys, tspan,
                                    events_data::AbstractVector{<:IEvent},
                                    signature)
    raw_events_data = collect(IEvent, events_data)
    unified_events_data = resolve_mrgevents(raw_events_data, sys)
    expanded_events_data = expand_repeated_events(unified_events_data)
    initial_actions = _InitialAction[]
    runtime_actions = Dict{Float64, Vector{_RuntimeAction}}()
    state_infusions = _StateInfusionForcing[]
    tstart = Float64(tspan[1])
    for event in expanded_events_data
        _add_event_to_plan!(
            prob, tstart, event, initial_actions, runtime_actions, state_infusions) ||
            return nothing
    end
    callback = _runtime_callback_from_actions(runtime_actions)
    event_times = _scheduled_event_times(runtime_actions, state_infusions)
    return _EventPlan(
        :runtime_actions,
        signature,
        initial_actions,
        runtime_actions,
        state_infusions,
        callback,
        nothing,
        event_times,
        expanded_events_data,
    )
end

function _try_callback_event_plan(prob::ODEProblem, sys, tspan, events_data; init_mode=false)
    schedule = prepare_events(events_data)
    isempty(schedule) && return nothing
    signature = schedule.signature
    tstart = Float64(tspan[1])

    key = _event_plan_cache_key(:runtime_actions, sys, tstart, init_mode, signature)
    cached = lock(CACHE_LOCK) do
        get(EVENT_PLAN_CACHE, key, nothing)
    end
    if cached !== nothing && _event_plan_entry_matches(cached, :runtime_actions, sys, prob, tstart, init_mode, signature)
        return cached.plan
    end

    raw_events_data = _normalize_event_data(schedule)
    plan = _build_callback_event_plan(prob, sys, tspan, raw_events_data, signature)
    plan === nothing && return nothing
    entry = _EventPlanCacheEntry(
        objectid(sys), sys, typeof(prob.f), typeof(prob.p), length(prob.u0),
        tstart, init_mode, signature, plan,
    )
    return lock(CACHE_LOCK) do
        current = get(EVENT_PLAN_CACHE, key, nothing)
        if current !== nothing && _event_plan_entry_matches(current, :runtime_actions, sys, prob, tstart, init_mode, signature)
            current.plan
        else
            EVENT_PLAN_CACHE[key] = entry
            plan
        end
    end
end

_try_callback_event_plan(prob::ODEProblem, sys, tspan, event::IEvent; init_mode=false) =
    _try_callback_event_plan(prob, sys, tspan, [event]; init_mode)

function _scheduled_event_lowering(sys, events_data::Vector{IEvent})
    for event in events_data
        if event.evid == 2
            for param_ref in keys(event.param_changes)
                resolved = resolve_variable_to_num(param_ref, sys;
                    expected_type=:parameter, time=event.time)
                _is_time_dependent_parameter(resolved) || return :structural_actions
            end
        end
    end
    return :runtime_actions
end

_scheduled_event_lowering(sys, schedule::EventSchedule) =
    _scheduled_event_lowering(sys, _normalize_event_data(schedule))

function _copy_u0_for_value(prob::ODEProblem, current_u0, value)
    if current_u0 !== nothing
        T = value isa Number ? promote_type(eltype(current_u0), typeof(value)) : eltype(current_u0)
        # `copy` (not `current_u0`): callers pass their own u0 array (e.g. the base
        # problem's u0); mutating it in place at the call site leaks the dose-adjusted
        # initial state back into the shared base problem, making repeated solves of
        # the same subject non-deterministic (drift toward dosing steady state). Always
        # return a private array so the in-place `new_u0[idx] = value` write is local.
        return T === eltype(current_u0) ? copy(current_u0) : T.(current_u0)
    end
    T = value isa Number ? promote_type(eltype(prob.u0), typeof(value)) : eltype(prob.u0)
    return T === eltype(prob.u0) ? copy(prob.u0) : T.(prob.u0)
end

function _initial_get(prob::ODEProblem, getter, key)
    return try
        getter(prob)
    catch
        prob[key]
    end
end

function _set_param_update!(keys::Vector{Any}, vals::Vector{Any}, positions::Dict{Any, Int}, key, value)
    pos = get(positions, key, 0)
    if pos == 0
        push!(keys, key)
        push!(vals, value)
        positions[key] = length(keys)
    else
        vals[pos] = value
    end
    return nothing
end

function _pending_param_value(prob::ODEProblem, getter, key,
                              vals::Vector{Any}, positions::Dict{Any, Int})
    pos = get(positions, key, 0)
    pos == 0 || return vals[pos]
    return _initial_get(prob, getter, key)
end

_event_update_name_key(key::Symbol) = _canonical_reference_symbol(key)
_event_update_name_key(key::AbstractString) = _canonical_reference_symbol(key)
_event_update_name_key(key) = Symbol(MTK.getname(key))

function _seed_event_param_positions!(positions::Dict{Any, Int},
                                      name_positions::Dict{Any, Int},
                                      keys)
    for i in eachindex(keys)
        key = keys[i]
        positions[key] = i
        name_positions[_event_update_name_key(key)] = i
    end
    return nothing
end

function _event_param_position(positions::Dict{Any, Int},
                               name_positions::Dict{Any, Int},
                               key)
    pos = get(positions, key, 0)
    pos != 0 && return pos
    return get(name_positions, _event_update_name_key(key), 0)
end

function _set_event_param_update!(keys::Vector{Any}, vals::Vector{Any},
                                  positions::Dict{Any, Int},
                                  name_positions::Dict{Any, Int},
                                  key, value)
    pos = _event_param_position(positions, name_positions, key)
    if pos == 0
        push!(keys, key)
        push!(vals, value)
        positions[key] = length(keys)
        name_positions[_event_update_name_key(key)] = length(keys)
    else
        vals[pos] = value
    end
    return nothing
end

function _pending_event_param_value(prob::ODEProblem, getter, key,
                                    vals::Vector{Any},
                                    positions::Dict{Any, Int},
                                    name_positions::Dict{Any, Int})
    pos = _event_param_position(positions, name_positions, key)
    pos == 0 || return vals[pos]
    return _initial_get(prob, getter, key)
end

function _event_plan_with_initial_actions(plan::_EventPlan,
                                          initial_actions::Vector{_InitialAction})
    return _EventPlan(
        plan.lowering,
        plan.signature,
        initial_actions,
        plan.runtime_actions,
        plan.state_infusions,
        plan.callback,
        plan.cached_prob,
        plan.event_times,
        plan.expanded_events,
    )
end

function _merge_callback_plan_initials(prob::ODEProblem, plan::_EventPlan,
                                       raw_keys, raw_values, u0;
                                       defer_state_actions::Bool = u0 === nothing)
    plan.lowering in (:runtime_actions, :structural_actions) ||
        error("Expected scheduled event plan, got $(plan.lowering)")
    isempty(plan.initial_actions) && return raw_keys, raw_values, u0, plan

    new_u0 = u0
    keys = collect(Any, raw_keys)
    vals = collect(Any, raw_values)
    positions = Dict{Any, Int}()
    name_positions = Dict{Any, Int}()
    _seed_event_param_positions!(positions, name_positions, keys)
    deferred_initial_actions = _InitialAction[]

    for action in plan.initial_actions
        if action isa Union{_InitialStateAdd, _InitialStateSet}
            if defer_state_actions && new_u0 === nothing
                push!(deferred_initial_actions, action)
                continue
            end
            value = if action isa _InitialStateAdd
                current = new_u0 === nothing ? prob.u0[action.index] : new_u0[action.index]
                current + action.amount
            else
                action.value
            end
            new_u0 = _copy_u0_for_value(prob, new_u0, value)
            new_u0[action.index] = value
        elseif action isa _InitialParamAdd
            current = _pending_event_param_value(prob, action.getter, action.key,
                vals, positions, name_positions)
            _set_event_param_update!(keys, vals, positions, name_positions,
                action.key, current + action.amount)
        else
            _set_event_param_update!(keys, vals, positions, name_positions,
                action.key, action.value)
        end
    end

    return Tuple(keys), Tuple(vals), new_u0,
        _event_plan_with_initial_actions(plan, deferred_initial_actions)
end

function _apply_callback_event_plan(prob::ODEProblem, plan::_EventPlan; kwargs...)
    plan.lowering in (:runtime_actions, :structural_actions) ||
        error("Expected scheduled event plan, got $(plan.lowering)")
    isempty(plan.initial_actions) && return prob

    new_u0 = nothing
    p_keys = Any[]
    p_vals = Any[]
    p_positions = Dict{Any, Int}()

    for action in plan.initial_actions
        if action isa _InitialStateAdd
            current = new_u0 === nothing ? prob.u0[action.index] : new_u0[action.index]
            value = current + action.amount
            new_u0 = _copy_u0_for_value(prob, new_u0, value)
            new_u0[action.index] = value
            action.initial_key === nothing || _set_param_update!(
                p_keys, p_vals, p_positions, action.initial_key, value)
        elseif action isa _InitialStateSet
            new_u0 = _copy_u0_for_value(prob, new_u0, action.value)
            new_u0[action.index] = action.value
            action.initial_key === nothing || _set_param_update!(
                p_keys, p_vals, p_positions, action.initial_key, action.value)
        elseif action isa _InitialParamAdd
            current = _pending_param_value(prob, action.getter, action.key, p_vals, p_positions)
            _set_param_update!(p_keys, p_vals, p_positions, action.key, current + action.amount)
        else
            _set_param_update!(p_keys, p_vals, p_positions, action.key, action.value)
        end
    end

    p_new = isempty(p_keys) ? nothing :
        SymbolicIndexingInterface.remake_buffer(prob, prob.p, p_keys, p_vals)
    remake_kwargs = Dict{Symbol, Any}(kwargs)
    get!(remake_kwargs, :build_initializeprob, false)
    new_u0 === nothing || (remake_kwargs[:u0] = new_u0)
    p_new === nothing || (remake_kwargs[:p] = p_new)
    return SciMLBase.remake(prob; pairs(remake_kwargs)...)
end

function _state_infusion_forced_f(prob::ODEProblem, plan::_EventPlan)
    isempty(plan.state_infusions) && return prob
    return _InfusionForcedODEFunction(
        prob.f,
        hasproperty(prob.f, :sys) ? prob.f.sys : nothing,
        Tuple(plan.state_infusions))
end

function _apply_state_infusion_forcing(prob::ODEProblem, plan::_EventPlan; forced_f=nothing)
    isempty(plan.state_infusions) && return prob
    forced_f = forced_f === nothing ? _state_infusion_forced_f(prob, plan) : forced_f
    return SciMLBase.remake(prob; f=forced_f, build_initializeprob=false)
end

function _without_initial_actions(plan::_EventPlan)
    isempty(plan.initial_actions) && return plan
    return _event_plan_with_initial_actions(plan, _InitialAction[])
end

function _sync_initial_parameter_values(prob; build_initializeprob=false)
    sys = prob.f.sys
    keys = Any[]
    vals = Any[]
    for var in MTK.unknowns(sys)
        initial_key = try MTK.Initial(var) catch; nothing end
        initial_key === nothing && continue
        SymbolicIndexingInterface.parameter_index(prob, initial_key) === nothing && continue
        val = try
            prob[var]
        catch
            continue
        end
        push!(keys, initial_key)
        push!(vals, val)
    end
    isempty(keys) && return prob
    ps_new = SymbolicIndexingInterface.remake_buffer(prob, prob.p, keys, vals)
    return SciMLBase.remake(prob; p=ps_new, build_initializeprob=build_initializeprob)
end

function _remake_with_explicit_state_values(prob, u0_p_map; build_initializeprob=false)
    sys = prob.f.sys
    resolved_u0_p = _resolve_keys_to_system(u0_p_map, sys)
    V = _value_eltype_from_map(resolved_u0_p)
    T_u = promote_type(eltype(prob.u0), V)
    new_u0 = T_u === eltype(prob.u0) ? copy(prob.u0) : T_u.(prob.u0)
    initial_keys = Any[]
    initial_vals = Any[]
    changed = false

    for (key, value) in resolved_u0_p
        value isa Number || continue
        state_idx = try SciMLBase.variable_index(prob, key) catch; nothing end
        state_idx === nothing && continue
        new_u0[state_idx] = value
        initial_key = try MTK.Initial(key) catch; nothing end
        if initial_key !== nothing &&
           SymbolicIndexingInterface.parameter_index(prob, initial_key) !== nothing
            push!(initial_keys, initial_key)
            push!(initial_vals, value)
        end
        changed = true
    end

    changed || return prob
    ps_new = isempty(initial_keys) ? prob.p :
        SymbolicIndexingInterface.remake_buffer(prob, prob.p, initial_keys, initial_vals)
    return SciMLBase.remake(prob; u0=new_u0, p=ps_new, build_initializeprob=build_initializeprob)
end

"""
    create_extended_system_upfront(base_sys, dynamic_param_targets)

Create an extended system for ordinary parameters that need to become
time-dependent inputs. State-targeted infusions are handled as RHS forcing
intervals and do not modify the symbolic system.
"""
function create_extended_system_upfront(base_sys, dynamic_param_targets=Set{Symbol}())
    if isempty(dynamic_param_targets)
        return base_sys
    end

    sorted_dynamic = Tuple(sort(collect(dynamic_param_targets); by=string))
    cache_key = hash((objectid(base_sys), sorted_dynamic))

    cached = lock(CACHE_LOCK) do
        get(EXTENDED_SYSTEM_CACHE, cache_key, nothing)
    end
    cached !== nothing && cached.base_sys === base_sys &&
        return cached.extended_sys

    return QSPKitCore.with_symbolic_compilation_lock() do
        cached = lock(CACHE_LOCK) do
            get(EXTENDED_SYSTEM_CACHE, cache_key, nothing)
        end
        cached !== nothing && cached.base_sys === base_sys &&
            return cached.extended_sys

        extended_sys = _create_extended_system_impl(base_sys, collect(sorted_dynamic))
        lock(CACHE_LOCK) do
            EXTENDED_SYSTEM_CACHE[cache_key] = (
                base_sys = base_sys,
                extended_sys = extended_sys,
            )
        end
        return extended_sys
    end
end

"""
    _create_extended_system_impl(base_sys, dynamic_param_targets)

Internal implementation that creates the extended system. Called by cache miss.
"""
# Restore algebraic unknowns that mtkcompile moved from unknowns to observed.
# After mtkcompile, algebraic variables (algebraic_a(t), algebraic_b(t)) are moved from
# unknowns to observed, and their defining equations are removed from equations().
# But the ODE equations still reference them. When rebuilding, we re-add these as
# equations + unknowns so mtkcompile can process them again.
# Distinguishes algebraic unknowns (time-dependent, iscall) from parameter bindings
# (bare symbols like V2).
# Returns (augmented_eqs, extra_unknowns, clean_observed).
# Restore data that mtkcompile strips from a compiled system.
#
# After mtkcompile:
#   - equations() missing algebraic equations (moved to observed)
#   - unknowns() missing algebraic variables (moved to observed)
#   - parameters() missing bound parameters (eliminated, bindings survive)
#   - observed() has all three types mixed in
#   - binding keys are different symbolic objects than equation variables (identity mismatch)
#
# Returns (all_eqs, all_vars, all_params, clean_observed, reconciled_bindings).
function _restore_compiled_system(base_sys, eqs)
    observed = try MTK.observed(base_sys) catch; Equation[] end
    raw_bindings = try Dict{Any,Any}(MTK.bindings(base_sys)) catch; Dict{Any,Any}() end
    bound_names = Set(Symbol(MTK.getname(v)) for v in
        try MTK.bound_parameters(base_sys) catch; [] end)

    # 1. Separate observed into algebraic unknowns, bound params, and real observed
    extra_eqs = Equation[]
    extra_vars = []
    clean_observed = Equation[]
    for eq in observed
        lhs_u = Symbolics.unwrap(eq.lhs)
        lhs_name = Symbol(MTK.getname(eq.lhs))
        if SymbolicUtils.iscall(lhs_u) && !MTK.isdifferential(lhs_u)
            push!(extra_eqs, eq)
            push!(extra_vars, eq.lhs)
        elseif lhs_name in bound_names
            continue  # handled via bindings
        else
            push!(clean_observed, eq)
        end
    end

    all_eqs = vcat(eqs, extra_eqs)
    all_vars = vcat(collect(MTK.unknowns(base_sys)), extra_vars)

    # 2. Re-add bound parameters to parameter list
    bound_ps = try collect(MTK.bound_parameters(base_sys)) catch; [] end
    all_params = vcat(collect(MTK.parameters(base_sys)), bound_ps)

    # 3. Reconcile binding keys with equation variables.
    # After mtkcompile, binding keys are different symbolic objects than the variables
    # in equations(). mtkcompile uses isequal to match them — if they don't match,
    # bound parameters show up as undefined symbols in generated code.
    # Fix: build a name→variable map from the equations, then rewrite binding keys.
    eq_var_map = Dict{Symbol, Any}()
    for eq in all_eqs
        for v in Symbolics.get_variables(eq.rhs)
            nm = try Symbol(MTK.getname(v)) catch; continue end
            eq_var_map[nm] = v
        end
        for v in try Symbolics.get_variables(eq.lhs) catch; [] end
            nm = try Symbol(MTK.getname(v)) catch; continue end
            eq_var_map[nm] = v
        end
    end

    reconciled_bindings = Dict{Any,Any}()
    for (k, v) in raw_bindings
        k_name = try Symbol(MTK.getname(k)) catch; nothing end
        if k_name !== nothing
            reconciled_key = get(eq_var_map, k_name, k)
            reconciled_bindings[reconciled_key] = v
        else
            reconciled_bindings[k] = v
        end
    end

    return all_eqs, all_vars, all_params, clean_observed, reconciled_bindings
end


function _symbol_name(x)
    return try Symbol(MTK.getname(x)) catch; nothing end
end

function _is_time_dependent_parameter(p)
    source = try Symbolics.getmetadata(Symbolics.unwrap(p), MTK.VariableSource, nothing) catch; nothing end
    return source !== nothing && source[1] === :discretes
end

function _binding_parameter_names(sys)
    names = Set{Symbol}()
    for p in try MTK.bound_parameters(sys) catch; [] end
        name = _symbol_name(p)
        name === nothing || push!(names, name)
    end
    for (p, _) in try MTK.bindings(sys) catch; Dict() end
        name = _symbol_name(p)
        name === nothing || push!(names, name)
    end
    return names
end

function _runtime_binding_parameter_names(sys)
    state_names = Set{Symbol}()
    for var in try MTK.unknowns(sys) catch; [] end
        name = _symbol_name(var)
        name === nothing || push!(state_names, name)
    end

    names = Set{Symbol}()
    for p in try MTK.bound_parameters(sys) catch; [] end
        name = _symbol_name(p)
        name === nothing && continue
        name in state_names && continue
        push!(names, name)
    end
    for (p, _) in try MTK.bindings(sys) catch; Dict() end
        name = _symbol_name(p)
        name === nothing && continue
        name in state_names && continue
        push!(names, name)
    end
    return names
end

function _state_binding_names(sys)
    state_names = Set{Symbol}()
    for var in try MTK.unknowns(sys) catch; [] end
        name = _symbol_name(var)
        name === nothing || push!(state_names, name)
    end

    names = Set{Symbol}()
    for (var, _) in try MTK.bindings(sys) catch; Dict() end
        name = _symbol_name(var)
        name === nothing && continue
        name in state_names || continue
        push!(names, name)
    end
    return names
end

function _without_state_binding_initials(u0_p_map, sys)
    binding_names = _state_binding_names(sys)
    isempty(binding_names) && return u0_p_map
    filtered = Dict{Any,Any}()
    for (k, v) in u0_p_map
        name = _symbol_name(k)
        if name === nothing || !(name in binding_names)
            filtered[k] = v
        end
    end
    return filtered
end

function _without_runtime_binding_parameters(u0_p_map, sys)
    binding_names = _runtime_binding_parameter_names(sys)
    filtered = Dict{Any,Any}()
    for (k, v) in u0_p_map
        name = _symbol_name(k)
        if name === nothing || !(name in binding_names)
            filtered[k] = v
        end
    end
    return filtered
end

function _find_parameter_by_name(sys, target::Symbol)
    for coll in (
        try MTK.parameters(sys) catch; [] end,
        try MTK.bound_parameters(sys) catch; [] end,
    )
        for p in coll
            _symbol_name(p) == target && return p
        end
    end
    return nothing
end

function _initial_value_by_name(sys, target::Symbol, default=0.0)
    ics = try Dict{Any,Any}(MTK.initial_conditions(sys)) catch; Dict{Any,Any}() end
    for (k, v) in ics
        _symbol_name(k) == target && return v
    end
    return default
end

function _create_dynamic_parameter_extensions(base_sys, dynamic_param_targets)
    isempty(dynamic_param_targets) && return Pair{Any, Any}[], Dict{Any, Any}(), Dict{Any, Any}()

    iv = MTK.get_iv(base_sys)
    binding_names = _binding_parameter_names(base_sys)
    dynamic_pairs = Pair{Any, Any}[]
    substitutions = Dict{Any, Any}()
    dynamic_defaults = Dict{Any, Any}()

    for target in sort(Symbol.(dynamic_param_targets); by=string)
        old_param = _find_parameter_by_name(base_sys, target)
        if old_param === nothing
            var_to_name_map = MTK.get_var_to_name(base_sys)
            candidate = get(var_to_name_map, target, nothing)
            if candidate !== nothing && candidate in buildSet(MTK.unknowns(base_sys))
                error("Expected '$target' to be a parameter, but it's a state variable. State variables should be dosed using EVID=1 with CMT column.")
            end
            error("$target not found in system. Available quantities: $(keys(var_to_name_map))")
        end
        target_name = _symbol_name(old_param)
        target_name in binding_names && error("Cannot modify EVID=2 parameter '$target' because it is a computed/dependent parameter. Modify its source parameters instead.")

        if _is_time_dependent_parameter(old_param)
            continue
        end

        default_value = _initial_value_by_name(base_sys, target_name, 0.0)
        dynamic_param = (@discretes $(target_name)($(iv)) = 0.0 [input=true])[1]
        substitutions[old_param] = dynamic_param
        dynamic_defaults[dynamic_param] = default_value
        push!(dynamic_pairs, old_param => dynamic_param)
    end

    return dynamic_pairs, substitutions, dynamic_defaults
end

_substitute_dynamic(x, substitutions) = isempty(substitutions) ? x : Symbolics.substitute(x, substitutions)

function _substitute_dynamic_equations(eqs, substitutions)
    isempty(substitutions) && return eqs
    return [_substitute_dynamic(eq, substitutions) for eq in eqs]
end

function _substitute_dynamic_bindings(bindings, substitutions)
    isempty(substitutions) && return bindings
    reconciled = Dict{Any, Any}()
    for (k, v) in bindings
        reconciled[_substitute_dynamic(k, substitutions)] = _substitute_dynamic(v, substitutions)
    end
    return reconciled
end

function _substitute_dynamic_initial_conditions(ics, substitutions)
    isempty(substitutions) && return ics
    updated = Dict{Any, Any}()
    for (k, v) in ics
        updated[_substitute_dynamic(k, substitutions)] = _substitute_dynamic(v, substitutions)
    end
    return updated
end

function _drop_dynamic_source_parameters(params, dynamic_pairs)
    isempty(dynamic_pairs) && return params
    drop_names = Set{Symbol}()
    for (old_param, _) in dynamic_pairs
        name = _symbol_name(old_param)
        name === nothing || push!(drop_names, name)
    end
    return [p for p in params if !(_symbol_name(p) in drop_names)]
end

function _apply_dynamic_parameter_initials!(base_ics, dynamic_pairs, dynamic_defaults, dynamic_substitutions)
    isempty(dynamic_pairs) && return base_ics
    for (old_param, dynamic_param) in dynamic_pairs
        old_name = _symbol_name(old_param)
        for key in collect(keys(base_ics))
            _symbol_name(key) == old_name && delete!(base_ics, key)
        end
        base_ics[dynamic_param] = get(dynamic_defaults, dynamic_param, 0.0)
    end
    return _substitute_dynamic_initial_conditions(base_ics, dynamic_substitutions)
end

function _create_extended_system_impl(base_sys, dynamic_param_targets=Set{Symbol}())
    iv = MTK.get_iv(base_sys)

    used_names = Set{Symbol}()
    for coll in (
        try MTK.unknowns(base_sys) catch; [] end,
        try MTK.parameters(base_sys) catch; [] end,
        try MTK.bound_parameters(base_sys) catch; [] end,
    )
        for sym in coll
            push!(used_names, Symbol(MTK.getname(sym)))
        end
    end
    for eq in try MTK.observed(base_sys) catch; [] end
        push!(used_names, Symbol(MTK.getname(eq.lhs)))
    end

    dynamic_param_pairs, dynamic_substitutions, dynamic_defaults =
        _create_dynamic_parameter_extensions(base_sys, dynamic_param_targets)
    for (_, dynamic_param) in dynamic_param_pairs
        push!(used_names, Symbol(MTK.getname(dynamic_param)))
    end

    eqs = MTK.equations(base_sys)
    new_eqs = _substitute_dynamic_equations(copy(eqs), dynamic_substitutions)

    # Detect if system was compiled (only differential eqs remain) vs pre-compiled (has algebraic eqs)
    has_algebraic = any(eq -> !MTK.isdifferential(Symbolics.unwrap(eq.lhs)), new_eqs)

    if has_algebraic
        # Pre-compiled system: equations, unknowns, params are complete.
        # Don't pass bindings — mtkcompile's TearingState loses iscomplete after flatten(),
        # so bound parameters aren't recognized in ps. Without bindings, bound params
        # must be in the parameter list as regular (unbound) tunable parameters.
        # MTK.parameters() only returns tunable params, so we add bound_parameters() too.
        all_eqs = new_eqs
        all_vars = collect(MTK.unknowns(base_sys))
        bound_ps = try collect(MTK.bound_parameters(base_sys)) catch; [] end
        base_params = _drop_dynamic_source_parameters(vcat(collect(MTK.parameters(base_sys)), bound_ps), dynamic_param_pairs)
        all_params = vcat(base_params, last.(dynamic_param_pairs))
        observed = _substitute_dynamic_equations(try MTK.observed(base_sys) catch; Equation[] end, dynamic_substitutions)
        reconciled_bindings = Dict()
    else
        # Compiled system: restore stripped algebraic unknowns, bound params, binding keys
        all_eqs, all_vars, all_params, observed, reconciled_bindings = _restore_compiled_system(base_sys, new_eqs)
        all_params = _drop_dynamic_source_parameters(all_params, dynamic_param_pairs)
        all_params = vcat(all_params, last.(dynamic_param_pairs))
        observed = _substitute_dynamic_equations(observed, dynamic_substitutions)
        reconciled_bindings = _substitute_dynamic_bindings(reconciled_bindings, dynamic_substitutions)
    end

    continuous_events = try MTK.continuous_events(base_sys) catch; [] end
    existing_discrete_events = try MTK.discrete_events(base_sys) catch; [] end
    base_ics = try Dict{Any,Any}(MTK.initial_conditions(base_sys)) catch; Dict{Any,Any}() end
    base_ics = _apply_dynamic_parameter_initials!(base_ics, dynamic_param_pairs, dynamic_defaults, dynamic_substitutions)
    base_guesses = try MTK.guesses(base_sys) catch; Dict() end
    base_init_eqs = try MTK.initialization_equations(base_sys) catch; [] end

    extended_sys = MTK.System(
        all_eqs, iv, all_vars, all_params;
        name = MTK.getname(base_sys),
        observed = observed,
        bindings = reconciled_bindings,
        initial_conditions = base_ics,
        guesses = base_guesses,
        initialization_eqs = base_init_eqs,
        checks = false,
        continuous_events = continuous_events,
        discrete_events = existing_discrete_events
    )

    return complete(extended_sys)
end


"""
    separate_t0_events(events_data::Vector{IEvent}, u0_p_map, tstart, sys)

Separate events at t=tstart from runtime events, applying t=0 doses to initial conditions.
Returns (modified_u0_p, runtime_events_data).
Note: events_data should contain already-resolved entities (from resolve_mrgevents).
The system is needed for resolving variable keys in u0_p_map to their canonical form.
"""
function separate_t0_events(events_data::Vector{IEvent}, u0_p_map, tstart, sys)
    modified_u0_p = copy(u0_p_map)
    runtime_events_data = IEvent[]

    for event in events_data
        if event.time == tstart
            if event.evid == 1  # Dose at start time
                resolved_cmt = event.cmt  # Already resolved by resolve_mrgevents
                amt = event.amt
                rate = missing_to_nothing(event.rate)
                duration = missing_to_nothing(event.duration)

                # Only apply bolus doses to initial conditions (not infusions)
                if is_bolus_dose(rate, duration)
                    # Use simple helper function to update state variable (already resolved)
                    if !simple_t0_update!(modified_u0_p, u0_p_map, resolved_cmt, amt, true, sys)
                        error("State variable $(resolved_cmt) not found in system at time $(event.time)")
                    end
                else
                    # Infusions at t=0 still need callbacks, keep as runtime event
                    push!(runtime_events_data, event)
                end
            elseif event.evid == 2  # Parameter change at start time
                # Handle parameter changes by modifying initial parameter values
                # param_changes already contains resolved parameters as keys
                for (resolved_param, param_value) in event.param_changes
                    if !simple_t0_update!(modified_u0_p, u0_p_map, resolved_param, param_value, false, sys)
                        error("Parameter $(resolved_param) not found in system at time $(event.time)")
                    end
                end
            elseif event.evid == 8  # Absolute state replacement at start time
                if !simple_t0_update!(
                        modified_u0_p, u0_p_map, event.cmt,
                        event.amt, false, sys)
                    error("State variable $(event.cmt) not found in system at time $(event.time)")
                end
            else
                # Other EVID values, keep as runtime event
                push!(runtime_events_data, event)
            end
        else
            # Keep as runtime event
            push!(runtime_events_data, event)
        end
    end

    return modified_u0_p, runtime_events_data
end

function _structural_base_problem(sys, u0_p_map, tspan, raw_events_data::Vector{IEvent};
                                  kwargs...)
    if u0_p_map isa Vector{<:Pair}
        u0_p_map = Dict(u0_p_map)
    end
    sys_defaults = try Dict{Any,Any}(MTK.get_initial_conditions(sys)) catch; Dict{Any,Any}() end
    sys_bindings = try Dict{Any,Any}(MTK.bindings(sys)) catch; Dict{Any,Any}() end
    u0_p_map = _name_aware_merge(sys_defaults, sys_bindings, u0_p_map)

    dynamic_param_targets = analyze_events_for_parameter_changes(raw_events_data)
    extended_sys = create_extended_system_upfront(sys, dynamic_param_targets)

    extended_u0_p = _without_runtime_binding_parameters(u0_p_map, sys)
    constructor_u0_p = _without_state_binding_initials(extended_u0_p, extended_sys)
    V = _value_eltype_from_map(extended_u0_p)
    zero_value = V === Float64 ? 0.0 : zero(V)
    for param in MTK.parameters(extended_sys)
        if _is_time_dependent_parameter(param)
            pname = _symbol_name(param)
            has_initial_value = any(k -> _symbol_name(k) == pname, keys(constructor_u0_p))
            if !has_initial_value
                constructor_u0_p[param] = _initial_value_by_name(extended_sys, pname, zero_value)
            end
        end
    end

    updated_kwargs = Dict{Symbol, Any}(kwargs)
    get!(updated_kwargs, :build_initializeprob, false)
    constructor_u0_p = _resolve_keys_to_system(constructor_u0_p, extended_sys)
    build_initializeprob = get(updated_kwargs, :build_initializeprob, false)
    prob = QSPKitCore.with_symbolic_compilation_lock() do
        MTK.ODEProblem(extended_sys, constructor_u0_p, tspan; pairs(updated_kwargs)...)
    end
    prob = _sync_initial_parameter_values(prob; build_initializeprob)
    prob = _remake_with_explicit_state_values(
        prob, extended_u0_p; build_initializeprob)
    return prob
end

function _get_structural_operation_event_plan(sys, u0_p_map, tspan, events_data; kwargs...)
    schedule = prepare_events(events_data)
    isempty(schedule) && return nothing
    signature = schedule.signature
    tstart = Float64(tspan[1])
    init_mode = get(Dict{Symbol, Any}(kwargs), :build_initializeprob, false)
    key = _event_plan_cache_key(:structural_actions, sys, tstart, init_mode, signature)
    cached = lock(CACHE_LOCK) do
        get(EVENT_PLAN_CACHE, key, nothing)
    end
    if cached !== nothing && _event_plan_entry_matches(cached, :structural_actions, sys, nothing, tstart, init_mode, signature) &&
       !isnothing(cached.plan.callback)
        return cached.plan
    end

    raw_events_data = _normalize_event_data(schedule)
    return QSPKitCore.with_symbolic_compilation_lock() do
        cached = lock(CACHE_LOCK) do
            get(EVENT_PLAN_CACHE, key, nothing)
        end
        if cached !== nothing && _event_plan_entry_matches(cached, :structural_actions, sys, nothing, tstart, init_mode, signature) &&
           !isnothing(cached.plan.callback)
            return cached.plan
        end

        prob = _structural_base_problem(sys, u0_p_map, tspan, raw_events_data; kwargs...)
        extended_sys = prob.f.sys
        unified_events_data = resolve_mrgevents(raw_events_data, extended_sys)
        expanded_events_data = expand_repeated_events(unified_events_data)
        callback_plan = _build_callback_event_plan(prob, extended_sys, tspan, expanded_events_data, signature)
        callback_plan === nothing && return nothing
        event_times = _extract_all_event_times(callback_plan.expanded_events)
        plan = _EventPlan(
            :structural_actions,
            signature,
            callback_plan.initial_actions,
            callback_plan.runtime_actions,
            callback_plan.state_infusions,
            callback_plan.callback,
            prob,
            event_times,
            callback_plan.expanded_events,
        )
        entry = _EventPlanCacheEntry(
            objectid(sys), sys, Any, Any, length(prob.u0), tstart, init_mode, signature, plan,
        )
        lock(CACHE_LOCK) do
            EVENT_PLAN_CACHE[key] = entry
        end
        return plan
    end
end

function _event_problem_kwargs(kwargs, callback, event_times)
    problem_kwargs = Dict{Symbol, Any}(kwargs)
    user_callback = pop!(problem_kwargs, :callback, nothing)
    if callback !== nothing
        user_callback === nothing ||
            error("InjecKit scheduled events cannot be combined with an arbitrary user callback. Encode same-time behavior as InjecKit events/actions so ordering is owned by one scheduled event program.")
        problem_kwargs[:callback] = callback
    elseif user_callback !== nothing
        problem_kwargs[:callback] = user_callback
    end
    if !isempty(event_times)
        existing = get(problem_kwargs, :tstops, Float64[])
        existing_vec = existing isa AbstractVector ? collect(existing) : [existing]
        problem_kwargs[:tstops] = sort!(unique!(vcat(existing_vec, event_times)))
    end
    return problem_kwargs
end

function _base_problem_from_map(sys, u0_p_map, tspan; kwargs...)
    if u0_p_map isa Vector{<:Pair}
        u0_p_map = Dict(u0_p_map)
    end
    sys_defaults = try Dict{Any,Any}(MTK.get_initial_conditions(sys)) catch; Dict{Any,Any}() end
    sys_bindings = try Dict{Any,Any}(MTK.bindings(sys)) catch; Dict{Any,Any}() end
    u0_p_map = _name_aware_merge(sys_defaults, sys_bindings, u0_p_map)
    u0_p_map = _without_runtime_binding_parameters(u0_p_map, sys)
    constructor_u0_p = _without_state_binding_initials(u0_p_map, sys)
    constructor_u0_p = _resolve_keys_to_system(constructor_u0_p, sys)
    constructor_kwargs = Dict{Symbol, Any}(kwargs)
    build_initializeprob = get(constructor_kwargs, :build_initializeprob, false)
    prob = QSPKitCore.with_symbolic_compilation_lock() do
        MTK.ODEProblem(sys, constructor_u0_p, tspan; pairs(constructor_kwargs)...)
    end
    prob = _sync_initial_parameter_values(prob; build_initializeprob)
    return _remake_with_explicit_state_values(prob, u0_p_map; build_initializeprob)
end

function _remake_event_plan_base_problem(cached_prob, sys, u0_p_map, tspan; kwargs...)
    if u0_p_map isa Vector{<:Pair}
        u0_p_map = Dict(u0_p_map)
    end
    sys_defaults = try Dict{Any,Any}(MTK.get_initial_conditions(sys)) catch; Dict{Any,Any}() end
    sys_bindings = try Dict{Any,Any}(MTK.bindings(sys)) catch; Dict{Any,Any}() end
    u0_p_map = _name_aware_merge(sys_defaults, sys_bindings, u0_p_map)
    u0_p_map = _without_runtime_binding_parameters(u0_p_map, sys)
    resolved_u0_p = _resolve_keys_to_system(u0_p_map, cached_prob.f.sys)

    valid_idxs = Any[]
    valid_vals = Any[]
    for (key, value) in resolved_u0_p
        value isa Number || continue
        if SymbolicIndexingInterface.parameter_index(cached_prob, key) !== nothing
            push!(valid_idxs, key)
            push!(valid_vals, value)
            continue
        end
        initial_key = try MTK.Initial(key) catch; nothing end
        if initial_key !== nothing &&
           SymbolicIndexingInterface.parameter_index(cached_prob, initial_key) !== nothing
            push!(valid_idxs, initial_key)
            push!(valid_vals, value)
        end
    end

    V = _value_eltype_from_map(resolved_u0_p)
    pnew = if isempty(valid_idxs)
        copy(cached_prob.p)
    elseif V === Float64 && eltype(cached_prob.p.tunable) === Float64 &&
           _keys_are_plain_tunable_parameters(cached_prob, valid_idxs)
        tunable, = canonicalize(Tunable(), cached_prob.p)
        # copy(cached_prob.p): replace(Tunable(),…) shares non-tunable partitions (.initials)
        # with the CACHED base problem; solving mutates .initials in place, leaking across the
        # cached event-plan solves reused every call. (The isempty branch above already copies.)
        p_copy = replace(Tunable(), copy(cached_prob.p), copy(tunable))
        for (key, value) in zip(valid_idxs, valid_vals)
            SymbolicIndexingInterface.setp(cached_prob, key)(p_copy, value)
        end
        p_copy
    else
        SymbolicIndexingInterface.remake_buffer(cached_prob.f.sys, cached_prob.p, valid_idxs, valid_vals)
    end

    T_u = promote_type(eltype(cached_prob.u0), V)
    new_u0 = T_u === eltype(cached_prob.u0) ? copy(cached_prob.u0) : T_u.(cached_prob.u0)
    for (key, value) in resolved_u0_p
        value isa Number || continue
        state_idx = try SciMLBase.variable_index(cached_prob, key) catch; nothing end
        state_idx === nothing && continue
        new_u0[state_idx] = value
    end

    remake_kwargs = Dict{Symbol, Any}(kwargs)
    return SciMLBase.remake(cached_prob; p=pnew, u0=new_u0, tspan=tspan, pairs(remake_kwargs)...)
end

function _problem_with_event_plan(sys, u0_p_map, tspan, plan::_EventPlan; kwargs...)
    plan.lowering in (:runtime_actions, :structural_actions) ||
        error("Unsupported event lowering $(plan.lowering)")
    problem_kwargs = _event_problem_kwargs(kwargs, plan.callback, plan.event_times)
    base_prob = if plan.lowering === :structural_actions
        _remake_event_plan_base_problem(plan.cached_prob, sys, u0_p_map, tspan; pairs(problem_kwargs)...)
    else
        _base_problem_from_map(sys, u0_p_map, tspan; pairs(problem_kwargs)...)
    end
    build_initializeprob = get(problem_kwargs, :build_initializeprob, false)
    runtime_prob = isempty(plan.initial_actions) ? base_prob :
        _apply_callback_event_plan(base_prob, plan; build_initializeprob)
    return _apply_state_infusion_forcing(runtime_prob, plan)
end

"""
    optimized_ode_constructor(sys, u0_p_map, tspan, events_data; kwargs...)

Build an eventful ODEProblem through the unified event-plan path. IEvent and
DataFrame inputs become `_EventPlan`s with runtime actions/RHS forcing, with
structural dynamic-parameter promotion only when ordinary MTK parameters must
change over time. The returned problem stores runtime callbacks in `prob.kwargs`
for SciML solve.
"""
function optimized_ode_constructor(sys, u0_p_map, tspan, events_data; kwargs...)
    if !(sys isa MTK.AbstractSystem)
        throw(ErrorException("First argument must be an MTK System, got $(typeof(sys))"))
    end
    if !MTK.iscomplete(sys)
        throw(ArgumentError("System must be complete. Use `complete(sys)` or `@mtkcompile sys = System(...)` to complete the system before creating ODEProblem."))
    end
    if events_data isa MTK.SymbolicDiscreteCallback ||
       events_data isa Vector{<:MTK.SymbolicDiscreteCallback}
        if u0_p_map isa Vector{<:Pair}
            u0_p_map = Dict(u0_p_map)
        end
        sys_defaults = try Dict{Any,Any}(MTK.get_initial_conditions(sys)) catch; Dict{Any,Any}() end
        sys_bindings = try Dict{Any,Any}(MTK.bindings(sys)) catch; Dict{Any,Any}() end
        u0_p_map = _name_aware_merge(sys_defaults, sys_bindings, u0_p_map)
        return optimized_symbolic_callback_constructor(sys, u0_p_map, tspan, events_data; kwargs...)
    end

    base_kwargs = Dict{Symbol, Any}(kwargs)
    user_callback = pop!(base_kwargs, :callback, nothing)
    schedule = prepare_events(events_data)
    if isempty(schedule)
        constructor_kwargs = user_callback === nothing ? base_kwargs : merge(base_kwargs, Dict(:callback => user_callback))
        return _base_problem_from_map(sys, u0_p_map, tspan; pairs(constructor_kwargs)...)
    end
    lowering = _scheduled_event_lowering(sys, schedule)
    plan = if lowering === :runtime_actions
        base_prob = _base_problem_from_map(sys, u0_p_map, tspan; pairs(base_kwargs)...)
        _try_callback_event_plan(base_prob, sys, tspan, schedule)
    elseif lowering === :structural_actions
        _get_structural_operation_event_plan(sys, u0_p_map, tspan, schedule; pairs(base_kwargs)...)
    else
        error("Unsupported event lowering $(lowering)")
    end
    plan === nothing && error("Could not build an event plan for $(typeof(events_data))")
    full_kwargs = user_callback === nothing ? base_kwargs : merge(base_kwargs, Dict(:callback => user_callback))
    return _problem_with_event_plan(sys, u0_p_map, tspan, plan; pairs(full_kwargs)...)
end

function _keys_are_plain_tunable_parameters(prob, keys)
    for key in keys
        idx = SymbolicIndexingInterface.parameter_index(prob, key)
        idx isa MTK.ParameterIndex{Tunable} ||
            return false
    end
    return true
end

"""
    separate_t0_symbolic_callbacks(events, u0_p_map, tstart, sys)

Separate SymbolicDiscreteCallbacks that occur at t=tstart and apply them to initial conditions.
Returns (modified_u0_p, runtime_events) where runtime_events only contains callbacks at t > tstart.
The system is needed for resolving variable keys in u0_p_map to their canonical form.
"""
function separate_t0_symbolic_callbacks(events::Vector{<:MTK.SymbolicDiscreteCallback}, u0_p_map, tstart, sys)
    modified_u0_p = copy(u0_p_map)
    runtime_events = MTK.SymbolicDiscreteCallback[]

    for event in events
        # Extract event information
        event_time, target_var, effect_amount, is_additive = _extract_event_info(event)

        if event_time !== nothing && isapprox(event_time, tstart, atol=1e-10)
            # This is a t=0 event - apply to initial conditions
            if target_var !== nothing
                if !simple_t0_update!(modified_u0_p, u0_p_map, target_var, effect_amount, is_additive, sys)
                    @warn "Could not apply t=$tstart event for $(target_var) - variable not found in initial conditions"
                end
            end
        else
            # This is a runtime event - keep for callback creation
            push!(runtime_events, event)
        end
    end

    return modified_u0_p, runtime_events
end

"""
    optimized_symbolic_callback_constructor(sys, u0_p_map, tspan, events; kwargs...)

Optimized constructor for SymbolicDiscreteCallback that uses them directly.
Separates events at t=tspan[1] to modify initial conditions instead of creating callbacks.
"""
function optimized_symbolic_callback_constructor(sys, u0_p_map, tspan, events::Vector{<:MTK.SymbolicDiscreteCallback}; kwargs...)
    # Validate that sys is an MTK System
    if !(sys isa MTK.AbstractSystem)
        throw(ErrorException("First argument must be an MTK System, got $(typeof(sys))"))
    end

    # Ensure the system is complete for consistent parameter resolution
    if !MTK.iscomplete(sys)
        throw(ArgumentError("System must be complete. Use `complete(sys)` or `@mtkcompile sys = System(...)` to complete the system before creating ODEProblem."))
    end

    # Merge system defaults with user-provided values (user values take precedence)
    # Convert Vector{Pair} to Dict if needed
    if u0_p_map isa Vector{<:Pair}
        u0_p_map = Dict(u0_p_map)
    end
    # MTK v11+: defaults replaced by get_initial_conditions
    sys_defaults = try Dict{Any,Any}(MTK.get_initial_conditions(sys)) catch; Dict{Any,Any}() end
    # Also include bindings (computed initial conditions like state => derived_initial)
    sys_bindings = try Dict{Any,Any}(MTK.bindings(sys)) catch; Dict{Any,Any}() end
    u0_p_map = _name_aware_merge(sys_defaults, sys_bindings, u0_p_map)

    # Separate events at t=tspan[1] and apply them to initial conditions
    tstart = tspan[1]
    modified_u0_p, runtime_events = separate_t0_symbolic_callbacks(events, u0_p_map, tstart, sys)

    # Extract event times from runtime events for tstops
    event_times = Float64[]
    for event in runtime_events
        event_time, _, _, _ = _extract_event_info(event)
        if event_time !== nothing
            push!(event_times, event_time)
        end
    end


    # Add event times to tstops for accurate event handling
    updated_kwargs = Dict{Symbol, Any}(kwargs)
    if !isempty(event_times)
        existing_tstops = get(updated_kwargs, :tstops, Float64[])
        all_tstops = sort(unique(vcat(existing_tstops, event_times)))
        updated_kwargs[:tstops] = all_tstops
    end
    get!(updated_kwargs, :build_initializeprob, false)

    # Create system with callbacks if needed
    # Use build_initializeprob=false to avoid InitializationProblem calling mtkcompile()
    # which fails on systems with parameter bindings (e.g., derived_rate => expr)
    # Lock to protect MTK/Symbolics internal state during system creation/compilation
    compiled_sys = QSPKitCore.with_symbolic_compilation_lock() do
        # Update system ICs with t=0 event modifications so the compiled system's
        # initial_conditions reflect doses applied at tstart
        base_ics = try Dict{Any,Any}(MTK.initial_conditions(sys)) catch; Dict{Any,Any}() end
        for (override_key, override_val) in modified_u0_p
            override_val isa Number || continue
            override_name = try MTK.getname(override_key) catch; continue end
            for (ic_key, _) in base_ics
                ic_name = try MTK.getname(ic_key) catch; continue end
                if ic_name == override_name
                    base_ics[ic_key] = override_val
                    break
                end
            end
        end

        # Restore everything mtkcompile stripped + reconcile binding keys
        all_eqs, all_vars, all_params, clean_observed, reconciled_bindings = _restore_compiled_system(sys, MTK.equations(sys))

        sys_rebuilt = MTK.System(
            all_eqs,
            MTK.get_iv(sys),
            all_vars,
            all_params;
            name = MTK.getname(sys),
            observed = clean_observed,
            bindings = reconciled_bindings,
            initial_conditions = base_ics,
            guesses = try MTK.guesses(sys) catch; Dict() end,
            initialization_eqs = try MTK.initialization_equations(sys) catch; [] end,
            continuous_events = try MTK.continuous_events(sys) catch; [] end,
            discrete_events = runtime_events,
            checks = false
        )
        complete(sys_rebuilt)
    end

    modified_u0_p = _resolve_keys_to_system(modified_u0_p, compiled_sys)
    build_initializeprob = get(updated_kwargs, :build_initializeprob, false)
    prob = QSPKitCore.with_symbolic_compilation_lock() do
        MTK.ODEProblem(compiled_sys, modified_u0_p, tspan; updated_kwargs...)
    end
    prob = _sync_initial_parameter_values(prob; build_initializeprob)
    return _remake_with_explicit_state_values(
        prob, modified_u0_p; build_initializeprob)
end
