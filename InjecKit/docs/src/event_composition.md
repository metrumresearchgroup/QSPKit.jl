# Event Composition & Regimen Templates

## Event Composition

Build complex dosing protocols from simpler pieces using `seq` and `combine`.

### `seq(events1, events2)` — Sequential Chaining

Chain events so that `events2` starts at the terminal event timestamp of
`events1` (including repeat doses from `ii`/`addl`):

```julia
using InjecKit: ev, seq

# One initialization pulse followed by a short repeating sequence
initial = [ev(cmt=:INPUT, amt=7.25)]
repeating = [ev(cmt=:INPUT, amt=1.5, ii=3.0, addl=4)]

protocol = seq(initial, repeating)
# The initial and first repeating events are both at t=0
```

`seq` computes the end time of `events1` by finding the latest `time + ii * addl` across all events, then offsets all times in `events2` by that amount.

### `combine(events1, events2)` — Simultaneous Combination

Merge two event vectors and sort by time:

```julia
using InjecKit: ev, combine

channel_a = [ev(cmt=:INPUT_A, amt=1.25, ii=3.0, addl=4)]
channel_b = [ev(cmt=:INPUT_B, amt=0.4, ii=5.0, addl=2)]

combined = combine(channel_a, channel_b)
# Both channels start at t=0 and are interleaved by time
```

## Regimen Templates

Common dosing shorthand for frequently used schedules.

### `QD(amt, cmt; days=1)` — Once Daily

```julia
using InjecKit: QD

events = QD(3.5, :INPUT; days=9)
# Equivalent to: ev(cmt=:INPUT, amt=3.5, ii=1.0, addl=8)
```

### `BID(amt, cmt; days=1)` — Twice Daily

```julia
using InjecKit: BID

events = BID(1.25, :INPUT; days=6)
# Equivalent to: ev(cmt=:INPUT, amt=1.25, ii=0.5, addl=11)
```

### `Q4W(amt, cmt; doses=1)` — Every 4 Weeks

```julia
using InjecKit: Q4W

events = Q4W(12.0, :INPUT; doses=3)
# Equivalent to: ev(cmt=:INPUT, amt=12.0, ii=28.0, addl=2)
```

### `loading_then(loading_amt, maint_amt, cmt; q, doses)` — Loading + Maintenance

```julia
using InjecKit: loading_then

events = loading_then(7.25, 1.5, :INPUT; q=3.0, doses=5)
# Initialization event of 7.25 at t=0
# The first repeating event shares t=0; later events are three time units apart
```

Uses `seq()` internally, so the loading and first maintenance dose share the
loading dose's timestamp. Use an event with `time=q` directly when maintenance
should begin one full interval later.

## Combining Templates

Templates and composition work together naturally:

```julia
using InjecKit: QD, Q4W, seq, combine

# Two synthetic phases with deliberately small, non-clinical values
protocol = seq(
    [QD(2.75, :INPUT; days=3)],
    [QD(0.8, :INPUT; days=5)],
)

# Combine two independent example channels
combo = combine(
    [QD(0.6, :INPUT_A; days=8)],
    [Q4W(4.25, :INPUT_B; doses=2)],
)
```

## API Reference

```@docs
seq
combine
QD
BID
Q4W
loading_then
```
