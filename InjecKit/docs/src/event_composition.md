# Event Composition & Regimen Templates

## Event Composition

Build complex dosing protocols from simpler pieces using `seq` and `combine`.

### `seq(events1, events2)` — Sequential Chaining

Chain events so that `events2` starts after `events1` finishes (including repeat doses from `ii`/`addl`):

```julia
using InjecKit: ev, seq

# Loading dose, then maintenance
loading = [ev(cmt=:DEPOT, amt=600)]
maintenance = [ev(cmt=:DEPOT, amt=300, ii=14, addl=24)]

protocol = seq(loading, maintenance)
# Loading at t=0, maintenance starts at t=0 (offset by loading end time)
```

`seq` computes the end time of `events1` by finding the latest `time + ii * addl` across all events, then offsets all times in `events2` by that amount.

### `combine(events1, events2)` — Simultaneous Combination

Merge two event vectors and sort by time:

```julia
using InjecKit: ev, combine

drug_a = [ev(cmt=:DEPOT_A, amt=100, ii=14, addl=24)]
drug_b = [ev(cmt=:DEPOT_B, amt=200, ii=28, addl=12)]

combo = combine(drug_a, drug_b)
# Both drugs start at t=0, interleaved by time
```

## Regimen Templates

Common dosing shorthand for frequently used schedules.

### `QD(amt, cmt; days=1)` — Once Daily

```julia
using InjecKit: QD

events = QD(100.0, :DEPOT; days=28)
# Equivalent to: ev(cmt=:DEPOT, amt=100.0, ii=1.0, addl=27)
```

### `BID(amt, cmt; days=1)` — Twice Daily

```julia
using InjecKit: BID

events = BID(50.0, :DEPOT; days=14)
# Equivalent to: ev(cmt=:DEPOT, amt=50.0, ii=0.5, addl=27)
```

### `Q4W(amt, cmt; doses=1)` — Every 4 Weeks

```julia
using InjecKit: Q4W

events = Q4W(210.0, :DEPOT; doses=12)
# Equivalent to: ev(cmt=:DEPOT, amt=210.0, ii=28.0, addl=11)
```

### `loading_then(loading_amt, maint_amt, cmt; q, doses)` — Loading + Maintenance

```julia
using InjecKit: loading_then

events = loading_then(600.0, 300.0, :DEPOT; q=14, doses=24)
# Loading dose of 600 at t=0
# Maintenance 300 every 14 days × 24 doses, starting after loading
```

Uses `seq()` internally — the maintenance regimen is chained after the loading dose.

## Combining Templates

Templates and composition work together naturally:

```julia
using InjecKit: QD, Q4W, seq, combine

# Two-phase oral therapy: 7 days loading, then 28 days maintenance
protocol = seq(
    [QD(200.0, :GUT; days=7)],     # loading: 200mg daily × 7
    [QD(100.0, :GUT; days=28)],    # maintenance: 100mg daily × 28
)

# Combination: oral daily + SC monthly
combo = combine(
    [QD(100.0, :GUT; days=365)],       # oral component
    [Q4W(210.0, :DEPOT; doses=12)],    # SC component
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
