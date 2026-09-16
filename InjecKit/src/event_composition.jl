"""
Event composition utilities for InjecKit.

Provides `seq` and `combine` for building complex dosing regimens
from simpler event vectors.
"""

"""
    _end_time(events::Vector{IEvent})

Compute the end time of an event vector, accounting for ii/addl repeats.
"""
function _end_time(events::Vector{IEvent})
    isempty(events) && return 0.0
    t_end = -Inf
    for e in events
        t_last = e.time
        if e.ii !== nothing && e.addl !== nothing && e.addl > 0
            t_last += e.ii * e.addl
        end
        t_end = max(t_end, t_last)
    end
    return t_end
end

"""
    seq(events1::Vector{IEvent}, events2::Vector{IEvent})

Chain `events2` after `events1` sequentially. All times in `events2` are
offset so that the earliest event in `events2` begins at the end time of
`events1` (last event time + ii * addl if applicable).

Returns a combined `Vector{IEvent}`.
"""
function seq(events1::Vector{IEvent}, events2::Vector{IEvent})
    isempty(events1) && return copy(events2)
    isempty(events2) && return copy(events1)

    offset = _end_time(events1)

    shifted = IEvent[
        IEvent(
            e.time + offset,
            e.cmt, e.amt, e.rate, e.duration, e.evid,
            e.ii, e.addl, e.ss, copy(e.param_changes)
        )
        for e in events2
    ]

    return vcat(copy(events1), shifted)
end

"""
    combine(events1::Vector{IEvent}, events2::Vector{IEvent})

Merge two event vectors and sort by time. Returns a `Vector{IEvent}`.
"""
function combine(events1::Vector{IEvent}, events2::Vector{IEvent})
    merged = vcat(copy(events1), copy(events2))
    sort!(merged, by = e -> e.time)
    return merged
end
