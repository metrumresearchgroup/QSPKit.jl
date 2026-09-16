# InjecKit.jl

[![Build Status](https://github.com/knabt/InjecKit.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/knabt/InjecKit.jl/actions/workflows/CI.yml?query=branch%3Amain)

A Julia package for discrete event handling in pharmacokinetic and pharmacodynamic modeling, designed to work seamlessly with [ModelingToolkit.jl](https://github.com/SciML/ModelingToolkit.jl) and [DifferentialEquations.jl](https://github.com/SciML/DifferentialEquations.jl). InjecKit provides NONMEM/mrgsolve-style event syntax for dosing events, parameter changes, and continuous infusions.

## Features

- **Multiple Input Formats**: DataFrames (NONMEM-style), IEvent vectors (mrgsolve-style), and SymbolicDiscreteCallbacks
- **Flexible Dosing**: Bolus doses, continuous infusions (rate-based or duration-based), and mixed dosing regimens
- **Parameter Changes**: Time-varying parameter updates with dependency validation
- **Repeated Dosing**: Support for `ii` (interdose interval) and `addl` (additional doses) for convenient repeated dosing schedules
- **Simultaneous Events**: Handle multiple events at the same time point (e.g., dose + parameter change)
- **Automatic Validation**: Input metadata validation for infusion parameters and parameter dependency checking
- **Performance Optimized**: Batched event processing for efficient handling of large datasets

## Quick Start

```julia
using InjecKit
using ModelingToolkit
using DifferentialEquations

# Define a simple PK model
@independent_variables t
@variables C(t)
@parameters CL V
D = Differential(t)

eqs = [D(C) ~ -(CL/V) * C]
@mtkcompile sys = System(eqs, t)

# Set initial conditions and parameters
u0 = Dict(C => 0.0)
p = Dict(CL => 2.0, V => 10.0)
tspan = (0.0, 48.0)
```

### DataFrame Input (NONMEM-style)

```julia
using DataFrames

# Create dosing schedule with NONMEM-style DataFrame
df = DataFrame(
    TIME = [0.0, 12.0, 24.0, 36.0],
    EVID = [1, 1, 1, 1],          # 1 = dose
    CMT = [:C, :C, :C, :C],      # Compartment
    AMT = [100.0, 100.0, 100.0, 100.0],
    RATE = [0.0, 0.0, 0.0, 0.0]  # 0 = bolus dose
)

prob = ODEProblem(sys, merge(u0, p), tspan, df)
sol = solve(prob, Tsit5())
```

### IEvent Input (mrgsolve-style)

```julia
# Create the same dosing schedule with mrgsolve-style events
events = [
    ev(time=0.0, cmt=:C, amt=100.0),
    ev(time=12.0, cmt=:C, amt=100.0),
    ev(time=24.0, cmt=:C, amt=100.0),
    ev(time=36.0, cmt=:C, amt=100.0)
]

prob = ODEProblem(sys, merge(u0, p), tspan, events)
sol = solve(prob, Tsit5())
```

### Repeated Dosing with ii/addl

```julia
# Same schedule using repeated dosing syntax
events = [
    ev(time=0.0, cmt=:C, amt=100.0, ii=12.0, addl=3)  # 4 doses total at 0, 12, 24, 36
]

prob = ODEProblem(sys, merge(u0, p), tspan, events)
sol = solve(prob, Tsit5())
```

## Advanced Examples

### Continuous Infusions

```julia
# Rate-based infusion
events = [
    ev(time=0.0, cmt=:C, rate=10.0, amt=100.0),  # 10 mg/hr for 10 hours
    ev(time=24.0, cmt=:C, amt=50.0, duration=2.0)  # 25 mg/hr for 2 hours
]

prob = ODEProblem(sys, merge(u0, p), tspan, events)
sol = solve(prob, Tsit5())
```

### Parameter Changes

```julia
# Model with time-varying clearance
@discretes CL_td(t)
@parameters V_static
eqs = [D(C) ~ -(CL_td/V_static) * C]
@mtkcompile sys_tv = System(eqs, t)

# Mixed dosing and parameter changes
df = DataFrame(
    TIME = [0.0, 12.0, 24.0],
    EVID = [1, 2, 1],              # 1 = dose, 2 = parameter change
    CMT = [:C, missing, :C],
    AMT = [100.0, missing, 100.0],
    CL_td = [missing, 5.0, missing]  # Increase clearance at t=12
)

u0_tv = Dict(C => 0.0)
p_tv = Dict(CL_td => 2.0, V_static => 10.0)

prob = ODEProblem(sys_tv, merge(u0_tv, p_tv), tspan, df)
sol = solve(prob, Tsit5())
```

### Simultaneous Events

```julia
# Parameter change and infusion starting at the same time
df = DataFrame(
    TIME = [0.0, 5.0, 5.0, 15.0],
    EVID = [1, 2, 1, 1],
    CMT = [:C, missing, :C, :C],
    AMT = [100.0, missing, missing, missing],
    RATE = [0.0, missing, 25.0, 0.0],
    DURATION = [missing, missing, 10.0, missing],
    CL_td = [missing, 5.0, missing, missing]
)

prob = ODEProblem(sys_tv, merge(u0_tv, p_tv), tspan, df)
sol = solve(prob, Tsit5())
```

### Event Composition

InjecKit provides `seq` and `combine` for building complex regimens from simpler event vectors.

**`seq(events1, events2)`** — Chain events sequentially. All times in `events2` are offset so they begin after `events1` ends (accounting for ii/addl repeats):

```julia
loading = [ev(time=0.0, cmt=:Depot, amt=600.0)]
maintenance = [ev(time=0.0, cmt=:Depot, amt=300.0, ii=14.0, addl=11)]

full_regimen = seq(loading, maintenance)  # maintenance starts after loading
```

**`combine(events1, events2)`** — Merge and sort by time. For combination therapy where two drugs are given concurrently:

```julia
drug_a = [ev(time=0.0, cmt=:Depot_A, amt=100.0, ii=24.0, addl=6)]
drug_b = [ev(time=0.0, cmt=:Depot_B, amt=50.0, ii=12.0, addl=13)]

combo = combine(drug_a, drug_b)  # interleaved by time
```

### Regimen Templates

Convenience constructors for common dosing schedules:

```julia
# Once daily for 7 days
events = QD(100.0, :Depot; days=7)

# Twice daily for 14 days
events = BID(50.0, :Depot; days=14)

# Every 4 weeks, 6 doses
events = Q4W(300.0, :Central; doses=6)

# Loading dose then maintenance: 600mg loading, then 300mg Q2W for 12 doses
events = loading_then(600.0, 300.0, :Depot; q=14.0, doses=12)
```

All time units are in days (matching SimKit conventions: `QD` uses `ii=1.0`, `BID` uses `ii=0.5`, `Q4W` uses `ii=28.0`).

### Utility Functions

```julia
# Expand ii/addl into individual events
expanded = expand_repeated_events(events)

# Get infusion parameters from a compiled system
infusion_params = get_infusion_parameters(sys)
```

## Event Types (EVID)

- **EVID = 1**: Dosing events (bolus or infusion)
- **EVID = 2**: Parameter change events
- **EVID = 3**: Reset events (reset state variables to specified values)
- **EVID = 4**: Reset + dose events (reset then dose)

## Key Features in Detail

### Automatic Infusion Parameter Creation

InjecKit automatically creates time-dependent infusion parameters when continuous infusions are detected:

```julia
# This automatically creates an infusion parameter with [input=true] metadata
events = [ev(time=0.0, cmt=:C, rate=10.0, amt=100.0)]

prob = ODEProblem(sys, merge(u0, p), tspan, events)
infusion_params = InjecKit.get_infusion_parameters(prob.f.sys)
```

### Validation and Error Checking

- Input metadata validation for infusion parameters
- Parameter dependency checking for time-varying parameters
- Comprehensive error messages for common mistakes
- System completeness validation

### Performance Optimizations

- Batched event processing for efficient callbacks
- Automatic system extension and compilation
- Metadata caching to avoid recompilation
- Smart t=0 event handling through initial condition modification

## Installation

```julia
using Pkg
Pkg.add("InjecKit")
```

## Documentation

For detailed documentation, examples, and tutorials, see the [documentation](https://knabt.github.io/InjecKit.jl/).

## Related Packages

- [ModelingToolkit.jl](https://github.com/SciML/ModelingToolkit.jl) - Symbolic modeling framework
- [DifferentialEquations.jl](https://github.com/SciML/DifferentialEquations.jl) - ODE solving
- [mrgsolve](https://github.com/metrumresearchgroup/mrgsolve) - R package for pharmacometric modeling
