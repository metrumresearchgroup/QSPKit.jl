# ============================================================
# Transparent LRU phase cache
# ============================================================

const _PHASE_CACHE = LRU{UInt, Any}(maxsize=64)
const _RUNNER_CACHE = LRU{UInt, Any}(maxsize=128)
const _CACHE_ENABLED = Threads.Atomic{Bool}(true)
const _PHASE_CACHE_LOCK = ReentrantLock()
const _RUNNER_CACHE_LOCK = ReentrantLock()

struct _PhaseCacheEntry
    prob::Any
    sys::Any
    prob_tspan::Any
    prob_u0::Any
    prob_p::Any
    params::Any
    event_signature::Any
    duration::Any
    t_start::Any
    u0::Any
    solver::Any
    solve_kwargs::Any
    sol::Any
end

struct _RunnerCacheEntry
    prob_id::UInt
    prob::Any
    event_signature::Any
    param_keys::Tuple
    tstart::Float64
    sol_id::UInt
    sol::Any
    runner::Any
end

"""
    disable_cache!()

Disable the transparent phase cache. All `simulate()` calls will perform fresh solves.
"""
function disable_cache!()
    _CACHE_ENABLED[] = false
    lock(_PHASE_CACHE_LOCK) do
        empty!(_PHASE_CACHE)
    end
    lock(_RUNNER_CACHE_LOCK) do
        empty!(_RUNNER_CACHE)
    end
    nothing
end

"""
    enable_cache!()

Re-enable the transparent phase cache (enabled by default).
"""
function enable_cache!()
    _CACHE_ENABLED[] = true
    nothing
end

_cache_enabled() = _CACHE_ENABLED[]

"""
    _cache_key(prob, params, events, duration, t_start, u0, solver, solve_kwargs)

Compute a content-addressed hash key from all solve inputs.
"""
function _cache_key(prob, params, events, duration, t_start, u0, solver, solve_kwargs)
    h = hash(duration)
    h = hash(t_start, h)
    h = hash(prob.tspan, h)
    h = hash(prob.u0, h)
    h = hash(prob.p, h)
    sys = hasproperty(prob.f, :sys) ? prob.f.sys : nothing
    sys === nothing &&
        error("SimKit requires MTK system metadata for phase-cache keys; plain ODEProblem inputs are unsupported.")
    h = hash(objectid(sys), h)
    h = _hash_params(h, params)
    h = _hash_events(h, events)
    if u0 !== nothing
        h = hash(u0, h)
    end
    h = hash(solver, h)
    h = hash(solve_kwargs, h)
    return h
end

_phase_event_signature(events::InjecKit.EventSchedule) = events.signature
_phase_event_signature(events) = events

function _phase_cache_entry(prob, params, events, duration, t_start, u0,
                            solver, solve_kwargs, sol)
    sys = hasproperty(prob.f, :sys) ? prob.f.sys : nothing
    sys === nothing &&
        error("SimKit requires MTK system metadata for phase-cache entries; plain ODEProblem inputs are unsupported.")
    return _PhaseCacheEntry(
        prob,
        sys,
        deepcopy(prob.tspan),
        deepcopy(prob.u0),
        deepcopy(prob.p),
        deepcopy(params),
        deepcopy(_phase_event_signature(events)),
        duration,
        t_start,
        deepcopy(u0),
        solver,
        deepcopy(solve_kwargs),
        sol,
    )
end

function _phase_cache_entry_matches(entry::_PhaseCacheEntry, prob, params, events,
                                    duration, t_start, u0, solver, solve_kwargs)
    sys = hasproperty(prob.f, :sys) ? prob.f.sys : nothing
    return entry.prob === prob &&
        entry.sys === sys &&
        isequal(entry.prob_tspan, prob.tspan) &&
        isequal(entry.prob_u0, prob.u0) &&
        isequal(entry.prob_p, prob.p) &&
        isequal(entry.params, params) &&
        isequal(entry.event_signature, _phase_event_signature(events)) &&
        isequal(entry.duration, duration) &&
        isequal(entry.t_start, t_start) &&
        isequal(entry.u0, u0) &&
        isequal(entry.solver, solver) &&
        isequal(entry.solve_kwargs, solve_kwargs)
end

function _hash_events(h, events)
    for event in events
        h = hash(event, h)
    end
    return h
end

function _hash_events(h, events::InjecKit.EventSchedule)
    return hash(events.signature, h)
end

function _hash_params(h, params)
    for k in sort!(collect(keys(params)); by=string)
        h = hash(k, h)
        h = hash(params[k], h)
    end
    return h
end

function _hash_params(h, params::NamedTuple)
    for (k, v) in pairs(params)
        h = hash(k, h)
        h = hash(v, h)
    end
    return h
end

function _cache_get(key::UInt, prob, params, events, duration, t_start, u0,
                    solver, solve_kwargs)
    return lock(_PHASE_CACHE_LOCK) do
        _CACHE_ENABLED[] || return nothing
        entry = get(_PHASE_CACHE, key, nothing)
        entry isa _PhaseCacheEntry &&
            _phase_cache_entry_matches(entry, prob, params, events, duration,
                t_start, u0, solver, solve_kwargs) ?
            entry.sol :
            nothing
    end
end

function _cache_put!(key::UInt, prob, params, events, duration, t_start, u0,
                     solver, solve_kwargs, sol)
    entry = _phase_cache_entry(prob, params, events, duration, t_start, u0,
        solver, solve_kwargs, sol)
    lock(_PHASE_CACHE_LOCK) do
        _CACHE_ENABLED[] && (_PHASE_CACHE[key] = entry)
    end
    return sol
end

_simrunner_sol_id(::Nothing) = UInt(0)
_simrunner_sol_id(sol) = objectid(sol)

function _simrunner_cache_key(prob, events::InjecKit.EventSchedule,
                              param_keys::Tuple, tstart::Real, sol)
    return hash((
        :simrunner,
        objectid(prob),
        events.signature,
        param_keys,
        Float64(tstart),
        _simrunner_sol_id(sol),
    ))
end

function _simrunner_entry_matches(entry::_RunnerCacheEntry, prob,
                                  events::InjecKit.EventSchedule,
                                  param_keys::Tuple, tstart::Real, sol)
    return entry.prob_id == objectid(prob) &&
        entry.prob === prob &&
        entry.event_signature == events.signature &&
        entry.param_keys == param_keys &&
        entry.tstart == Float64(tstart) &&
        entry.sol_id == _simrunner_sol_id(sol) &&
        entry.sol === sol
end

function _simrunner_cache_get(key::UInt, prob, events::InjecKit.EventSchedule,
                              param_keys::Tuple, tstart::Real, sol)
    return lock(_RUNNER_CACHE_LOCK) do
        entry = get(_RUNNER_CACHE, key, nothing)
        entry isa _RunnerCacheEntry &&
            _simrunner_entry_matches(entry, prob, events, param_keys, tstart, sol) ?
            entry.runner :
            nothing
    end
end

function _simrunner_cache_put!(key::UInt, prob, events::InjecKit.EventSchedule,
                               param_keys::Tuple, tstart::Real, sol, runner)
    entry = _RunnerCacheEntry(
        objectid(prob),
        prob,
        events.signature,
        param_keys,
        Float64(tstart),
        _simrunner_sol_id(sol),
        sol,
        runner,
    )
    return lock(_RUNNER_CACHE_LOCK) do
        current = get(_RUNNER_CACHE, key, nothing)
        if current isa _RunnerCacheEntry &&
           _simrunner_entry_matches(current, prob, events, param_keys, tstart, sol)
            current.runner
        else
            _RUNNER_CACHE[key] = entry
            runner
        end
    end
end
