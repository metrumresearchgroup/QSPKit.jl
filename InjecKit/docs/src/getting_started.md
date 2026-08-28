# Getting started

Activate the local alpha workspace before loading InjecKit:

```julia
using Pkg
Pkg.activate("path/to/QSPKit-alpha")
Pkg.instantiate()
```

The following example uses the same ModelingToolkit-backed problem shape as
the package tests:

```julia
using DataFrames
using InjecKit
using ModelingToolkitBase
using OrdinaryDiffEq

@parameters k V
@independent_variables t
@variables Central(t)
D = Differential(t)

@named model = System([D(Central) ~ -(k / V) * Central], t)
sys = mtkcompile(model)
prob = ODEProblem(sys, [Central => 0.0, k => 0.1, V => 10.0], (0.0, 24.0))

schedule = [
    ev(time=0.0, cmt=:Central, amt=100.0),
    ev(time=8.0, cmt=:Central, amt=50.0, rate=10.0),
    setevent(16.0, :Central => 25.0),
]

sol = solve(prob, schedule, Tsit5(); saveat=0.0:1.0:24.0)
```

## Event tables

A table requires numeric `TIME`, integer `EVID`, and event-specific columns.
Column names are uppercase:

```julia
events = DataFrame(
    TIME = [0.0, 12.0],
    EVID = [1, 1],
    CMT = [:Central, :Central],
    AMT = [100.0, 100.0],
)

sol = solve(prob, events, Tsit5())
```

For EVID 2, non-reserved columns name the parameters to update. For EVID 8,
`CMT` names one state and `AMT` is its replacement value. Missing required
values and unsupported event identifiers raise an error before solving.

## Reusing a solve plan

Construct [`EventRunner`](@ref) when the problem and event shape stay fixed:

```julia
runner = EventRunner(prob, schedule)
sol = solve_event_runner(runner, Tsit5(); saveat=0.0:1.0:24.0)
```

[`PreparedEventSolve`](@ref) also prepares a fixed parameter-update layout for
repeated evaluation. Its low-level callback helpers are intended for tools such
as SimKit and sensitivity engines; ordinary scripts can call the prepared value
directly.
