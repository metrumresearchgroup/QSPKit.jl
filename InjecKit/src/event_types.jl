"""
Event data structures and constructors for InjecKit.

This module defines the IEvent struct and related event constructors,
providing a flexible event system for pharmacokinetic modeling.
"""

"""
    IEvent

An immutable scheduled event. Prefer [`ev`](@ref) for doses and parameter
changes or [`setevent`](@ref) for absolute state assignments.

Supported `evid` values at solve time are 1 (dose or infusion), 2 (parameter
change), and 8 (single-state replacement).
"""
struct IEvent
    time::Float64
    cmt::Union{Symbol, String, MTK.Num, Nothing}  # Can store resolved MTK variables
    amt::Union{Real, Nothing}
    rate::Union{Real, Nothing}
    duration::Union{Real, Nothing}
    evid::Int
    # Add other common fields as needed
    ii::Union{Real, Nothing}         # interdose interval
    addl::Union{Int, Nothing}        # additional doses
    ss::Union{Int, Nothing}          # steady state
    # Parameter changes (for EVID=2) - can store resolved parameters as keys
    param_changes::Dict{Union{Symbol, MTK.Num}, Float64}
    function IEvent(time, cmt, amt, rate, duration, evid, ii, addl, ss, param_changes)
        # Convert BasicSymbolic types to Num for consistent handling
        # Use isa for flexible type checking across SymbolicUtils/Symbolics versions
        if cmt !== nothing && !(cmt isa Union{Symbol, String, MTK.Num, Nothing})
            cmt = MTK.Num(cmt)
        end
        return new(time, cmt, amt, rate, duration, evid, ii, addl, ss, param_changes)
    end
end

"""
    EventSchedule

Internal immutable event snapshot with a stable event-plan signature. Public
solve and simulation APIs accept raw event inputs and normalize them
automatically.
"""
struct EventSchedule
    events::Tuple
    signature::Any
end

Base.length(schedule::EventSchedule) = length(schedule.events)
Base.isempty(schedule::EventSchedule) = isempty(schedule.events)
Base.iterate(schedule::EventSchedule) = iterate(schedule.events)
Base.iterate(schedule::EventSchedule, state) = iterate(schedule.events, state)
Base.getindex(schedule::EventSchedule, i::Int) = schedule.events[i]
Base.firstindex(::EventSchedule) = 1
Base.lastindex(schedule::EventSchedule) = length(schedule.events)
Base.IndexStyle(::Type{EventSchedule}) = Base.IndexLinear()
Base.IteratorEltype(::Type{EventSchedule}) = Base.HasEltype()
Base.eltype(::Type{EventSchedule}) = IEvent
Base.copy(schedule::EventSchedule) = EventSchedule(schedule.events, schedule.signature)

"""
    ev(; time=0.0, cmt=nothing, amt=nothing, rate=nothing, duration=nothing,
         evid=1, ii=nothing, addl=nothing, ss=nothing, kwargs...)

Create a dosing event (similar to mrgsolve's `ev()`).

# Arguments
- `time::Real=0.0` — event time
- `cmt` — target compartment (Symbol, String, or MTK Num). E.g., `:Depot`, `:Central`
- `amt` — dose amount. Required for `evid=1`
- `rate` — infusion rate. If > 0, dose is delivered as infusion over `amt/rate` time units
- `duration` — infusion duration. Alternative to `rate` (specify one, not both)
- `evid::Int=1` — event type: 1=dose, 2=parameter change, 8=state replacement
- `ii` — interdose interval for repeated dosing. Requires `addl > 0`
- `addl` — number of additional doses (total doses = 1 + addl)
- `ss` — steady-state flag: 0=off, 1=advance to steady state before event
- `kwargs...` — additional keyword arguments become parameter changes (for `evid=2`)

# Examples
```julia
# Bolus dose
ev(time=0.0, cmt=:Depot, amt=100.0)

# Infusion
ev(time=0.0, cmt=:Central, amt=500.0, rate=50.0)

# Repeated dosing (daily for 7 days)
ev(time=0.0, cmt=:Depot, amt=100.0, ii=24.0, addl=6)

# Multiple events
events = [
    ev(time=0.0, cmt=:Depot, amt=200.0),       # loading dose
    ev(time=24.0, cmt=:Depot, amt=100.0, ii=24.0, addl=27),  # maintenance
]
```
"""
function ev(; time=0.0, cmt=nothing, amt=nothing, rate=nothing, duration=nothing,
            evid=1, ii=nothing, addl=nothing, ss=nothing, kwargs...)
    # Collect any additional keyword arguments as parameter changes
    param_changes = Dict{Union{Symbol, MTK.Num}, Float64}()
    for (k, v) in kwargs
        if v !== nothing && v !== missing
            param_changes[k] = Float64(v)
        end
    end

    return IEvent(time, cmt, amt, rate, duration, evid, ii, addl, ss, param_changes)
end

function _state_set_event(time, target, value)
    time isa Real || throw(ArgumentError(
        "State-set event time must be a finite real value, got $(repr(time))."))
    isfinite(time) || throw(ArgumentError(
        "State-set event time must be finite, got $(repr(time))."))
    (target === nothing || target === missing) && throw(ArgumentError(
        "State-set event target must identify one model state."))
    target isa Union{Symbol, AbstractString, MTK.Num, Symbolics.BasicSymbolic} ||
        throw(ArgumentError(
            "State-set event target must be a Symbol, string, or scalar MTK symbolic state, got $(typeof(target))."))
    value isa Real && isfinite(value) || throw(ArgumentError(
        "State-set event value must be a finite real scalar, got $(repr(value))."))
    return IEvent(
        Float64(time), target, value, nothing, nothing, 8,
        nothing, nothing, nothing,
        Dict{Union{Symbol, MTK.Num}, Float64}(),
    )
end

"""
    setevent(time, target => value)
    setevent(target => value; time=0.0)
    setevent(; time=0.0, target, value)

Create an absolute state-assignment event. At `time`, the selected state is
replaced by `value`; unlike a dose, the value is not added to the current state.
This is InjecKit's named surface for the mrgsolve-compatible EVID=8 operation.
"""
setevent(time::Real, assignment::Pair) =
    _state_set_event(time, first(assignment), last(assignment))

setevent(assignment::Pair; time::Real=0.0) =
    _state_set_event(time, first(assignment), last(assignment))

setevent(; time::Real=0.0, target=nothing, value=nothing) =
    _state_set_event(time, target, value)
