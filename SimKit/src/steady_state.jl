"""
    SteadyStateOptions(; abstol=1e-8, reltol=1e-6, min_cycles=10, max_cycles=10000)

Convergence settings for periodic dosing, separate from the ODE solver tolerances.
Every state must satisfy `abs(new-old) ≤ abstol + reltol*abs(new)` at the end
of the dosing interval and, for an infusion, at the end of the infusion.
Failure to converge within `max_cycles` raises an error.
"""
struct SteadyStateOptions
    abstol::Float64
    reltol::Float64
    min_cycles::Int
    max_cycles::Int
    function SteadyStateOptions(; abstol=1e-8, reltol=1e-6,
                                  min_cycles::Integer=10, max_cycles::Integer=10000)
        isfinite(abstol) && abstol > 0 || throw(ArgumentError("SS abstol must be finite and positive"))
        isfinite(reltol) && reltol > 0 || throw(ArgumentError("SS reltol must be finite and positive"))
        2 <= min_cycles <= max_cycles || throw(ArgumentError("Require 2 ≤ min_cycles ≤ max_cycles"))
        new(abstol, reltol, min_cycles, max_cycles)
    end
end

"""
    advance_to_steady_state(cycle, u0; options=SteadyStateOptions())

Backend interface for periodic steady state. `cycle(u)` advances one complete
interval from the pre-dose state `u`, applies one dose, and returns a matrix
of states at the convergence checkpoints (interval end must be last).
The model and its parameters must repeat identically over each interval.
Returns `state` (before the next dose), `cycles`, and `error` (maximum scaled
change; at most one on success). Input states are not modified.
"""
function advance_to_steady_state(cycle, u0; options::SteadyStateOptions=SteadyStateOptions())
    state = copy(u0)
    previous = nothing
    change = Inf
    for n in 1:options.max_cycles
        current = cycle(copy(state))
        current isa AbstractMatrix && size(current, 1) == length(u0) && size(current, 2) > 0 ||
            error("Steady-state cycle must return a state-by-checkpoint matrix")
        all(isfinite, current) || error("Non-finite state during steady-state advancement (cycle $n)")
        if previous !== nothing
            size(current) == size(previous) || error("Steady-state checkpoints changed between cycles")
            change = maximum(abs.(current .- previous) ./
                (options.abstol .+ options.reltol .* abs.(current)))
            if n >= options.min_cycles && change <= 1
                return (; state=copy(current[:, end]), cycles=n, error=change)
            end
        end
        state = copy(current[:, end])
        previous = copy(current)
    end
    error("Steady state did not converge after $(options.max_cycles) cycles (scaled change=$change)")
end

"""
    has_steady_state(events)

Return `true` when any event requests steady-state initialization through a
nonzero `SS` value.
"""
has_steady_state(events) = any(e -> e.ss !== nothing && e.ss != 0, events)

"""
    steady_state_regimen(events, t0)

Validate and separate an initial `SS=1` dose from the forward event schedule.
Supports one initial bolus or finite infusion with `0 < duration < II`.
`SS=2`, later resets, overlapping infusions, and constant infusions are
rejected explicitly. `ADDL` applies only to forward doses, which do not reset
the state again. Other forward events remain unchanged.
"""
function steady_state_regimen(events, t0)
    ss_events = filter(e -> e.ss !== nothing && e.ss != 0, collect(events))
    isempty(ss_events) && return nothing
    length(ss_events) == 1 || throw(ArgumentError("Simulation supports one initial SS=1 record"))
    e = only(ss_events)
    e.ss == 1 && e.evid == 1 || throw(ArgumentError("Only dosing records with SS=1 are supported"))
    e.time == t0 || throw(ArgumentError("SS=1 must be at the start of the simulation"))
    count(x -> x.time <= t0, events) == 1 ||
        throw(ArgumentError("SS=1 must be the only event at or before the simulation start"))
    e.ii !== nothing && isfinite(e.ii) && e.ii > 0 || throw(ArgumentError("SS=1 requires a positive II"))
    e.amt !== nothing && isfinite(e.amt) && e.amt > 0 || throw(ArgumentError("SS=1 requires a positive AMT"))
    e.cmt !== nothing || throw(ArgumentError("SS=1 requires CMT"))
    isempty(e.param_changes) || throw(ArgumentError("SS=1 does not support simultaneous parameter changes"))
    e.addl === nothing || e.addl >= 0 || throw(ArgumentError("ADDL must be nonnegative"))
    e.rate === nothing || (isfinite(e.rate) && e.rate >= 0) ||
        throw(ArgumentError("SS=1 requires a nonnegative numeric RATE"))
    e.duration === nothing || (isfinite(e.duration) && e.duration >= 0) ||
        throw(ArgumentError("SS=1 requires a nonnegative numeric DURATION"))
    duration = e.rate !== nothing && e.rate > 0 ? e.amt / e.rate : something(e.duration, 0.0)
    duration < e.ii || throw(ArgumentError("SS=1 currently requires infusion duration < II"))
    if e.rate !== nothing && e.rate > 0 && e.duration !== nothing && e.duration > 0
        isapprox(duration, e.duration) || throw(ArgumentError("SS RATE and DURATION are inconsistent"))
    end
    dose = InjecKit.IEvent(e.time, e.cmt, e.amt, e.rate, e.duration, 1,
        nothing, nothing, nothing, copy(e.param_changes))
    forward = [x === e ? InjecKit.IEvent(e.time, e.cmt, e.amt, e.rate, e.duration,
        1, e.ii, e.addl, nothing, copy(e.param_changes)) : x for x in events]
    checkpoints = duration > 0 ? [t0 + duration, t0 + e.ii] : [t0 + e.ii]
    return (; dose, forward, checkpoints, interval=e.ii)
end
