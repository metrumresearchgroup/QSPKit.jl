"""
Regimen template functions for common dosing schedules.

Provides convenience constructors for QD, BID, Q4W, and loading-then-maintenance regimens.
"""

"""
    QD(amt, cmt; days=1, kwargs...)

Once-daily dosing. Creates an event with `ii=1.0` (days) and `addl=days-1`.
"""
function QD(amt, cmt; days=1, kwargs...)
    ev(; cmt=cmt, amt=amt, ii=1.0, addl=days - 1, kwargs...)
end

"""
    BID(amt, cmt; days=1, kwargs...)

Twice-daily dosing. Creates an event with `ii=0.5` (days) and `addl=2*days-1`.
"""
function BID(amt, cmt; days=1, kwargs...)
    ev(; cmt=cmt, amt=amt, ii=0.5, addl=2 * days - 1, kwargs...)
end

"""
    Q4W(amt, cmt; doses=1, kwargs...)

Every-4-weeks dosing. Creates an event with `ii=28.0` (days) and `addl=doses-1`.
"""
function Q4W(amt, cmt; doses=1, kwargs...)
    ev(; cmt=cmt, amt=amt, ii=28.0, addl=doses - 1, kwargs...)
end

"""
    loading_then(loading_amt, maint_amt, cmt; q, doses, kwargs...)

Loading dose plus `doses` maintenance doses at interval `q`. The loading dose
and first maintenance dose share the same timestamp; later maintenance doses
occur every `q` time units.

Uses `seq()` internally, whose second sequence begins at the first sequence's
terminal event timestamp.
"""
function loading_then(loading_amt, maint_amt, cmt; q, doses, kwargs...)
    loading = [ev(; cmt=cmt, amt=loading_amt, kwargs...)]
    maint = [ev(; cmt=cmt, amt=maint_amt, ii=q, addl=doses - 1, kwargs...)]
    return seq(loading, maint)
end
