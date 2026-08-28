# Event examples

## Bolus and infusion

```julia
events = [
    ev(time=0.0, cmt=:Central, amt=100.0),
    ev(time=4.0, cmt=:Central, amt=60.0, duration=3.0),
]
```

The bolus adds 100 to `Central` at time zero. The second event adds a constant
20 units per time unit over `[4, 7]`.

## Repeated dosing

```julia
events = [ev(time=0.0, cmt=:Depot, amt=100.0, ii=24.0, addl=6)]
expanded = expand_repeated_events(events)
```

`expanded` contains seven doses at times 0 through 144. `addl` counts
additional doses rather than total doses.

## Parameter and state changes

```julia
parameter_change = ev(time=12.0, evid=2, CL=3.5)
state_change = setevent(18.0, :Central => 0.0)
```

A parameter named by an EVID 2 event must be a dynamic/tunable model parameter.
A state assignment uses EVID 8 semantics and replaces rather than increments
the target state.
