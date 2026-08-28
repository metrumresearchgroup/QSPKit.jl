# InjecKit

InjecKit adds scheduled doses, infusions, parameter changes, and state
assignments to ModelingToolkit-backed ODE problems. Event inputs may be
constructed with [`ev`](@ref) and [`setevent`](@ref), or supplied as a
NONMEM-style `DataFrame`.

The package supports these event identifiers:

| EVID | Meaning |
| ---: | --- |
| 1 | Add a bolus dose or run a finite infusion |
| 2 | Change one or more model parameters |
| 8 | Replace one state with an absolute value |

EVID 3 and 4 are recognized when tables are parsed, but whole-system reset
semantics are not implemented and are rejected before a solve.

## Alpha scope

- Problems must be backed by ModelingToolkit system metadata.
- A finite infusion specifies exactly two of amount, rate, and duration.
- Repeats use `ii` plus `addl`; steady-state dosing is not implemented.
- Scheduled InjecKit callbacks cannot be combined with an arbitrary user
  callback when both would control the same solve. Express the behavior as one
  InjecKit event schedule so ordering is deterministic.

See [Getting started](getting_started.md) for a complete solve and
[Event composition](event_composition.md) for regimen helpers.

```@contents
Depth = 2
```
