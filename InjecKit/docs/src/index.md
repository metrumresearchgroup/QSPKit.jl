# InjecKit.jl

*Discrete event handling for pharmacokinetic and pharmacodynamic modeling in Julia*

InjecKit.jl provides a comprehensive interface for incorporating dosing events, parameter changes, and continuous infusions into ModelingToolkit.jl systems. The package bridges NONMEM/mrgsolve-style dosing data with modern Julia differential equation solvers, offering both familiar syntax and advanced capabilities.

## Features

- **Multiple Input Formats**: DataFrames (NONMEM-style), IEvent vectors (mrgsolve-style), and SymbolicDiscreteCallbacks
- **Flexible Dosing**: Bolus doses, continuous infusions (rate-based or duration-based), and mixed dosing regimens
- **Parameter Changes**: Time-varying parameter updates with comprehensive dependency validation
- **Repeated Dosing**: Support for `ii` (interdose interval) and `addl` (additional doses) for convenient repeated dosing schedules
- **Simultaneous Events**: Handle multiple events at the same time point (e.g., dose + parameter change)
- **Automatic Validation**: Input metadata validation for infusion parameters and parameter dependency checking
- **Performance Optimized**: Batched event processing for efficient handling of large datasets
- **Modern Julia Integration**: Seamless compatibility with ModelingToolkit.jl and DifferentialEquations.jl

## Quick Start

```julia
using InjecKit, ModelingToolkit, DataFrames, DifferentialEquations

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
# Create dosing data with continuous infusion
df = DataFrame(
    TIME = [0.0, 12.0, 24.0],
    EVID = [1, 1, 1],
    CMT = [:C, :C, :C], 
    AMT = [100.0, 150.0, 200.0],
    RATE = [0.0, 25.0, missing],     # Bolus, infusion, infusion
    DURATION = [missing, missing, 4.0]  # with duration
)

prob = ODEProblem(sys, merge(u0, p), tspan, df)
sol = solve(prob, Tsit5())
```

### IEvent Input (mrgsolve-style)

```julia
# Define events with mrgsolve-like syntax
events = [
    ev(time=0.0, cmt=:C, amt=100.0),          # Bolus dose
    ev(time=12.0, cmt=:C, amt=150.0, rate=25.0), # Infusion with rate
    ev(time=24.0, cmt=:C, amt=200.0, duration=4.0) # Infusion with duration
]

prob = ODEProblem(sys, merge(u0, p), tspan, events)
sol = solve(prob, Tsit5())
```

### Repeated Dosing

```julia
# Use ii/addl for repeated dosing schedules
events = [
    ev(time=0.0, cmt=:C, amt=100.0, ii=8.0, addl=5)  # 6 doses every 8 hours
]

prob = ODEProblem(sys, merge(u0, p), tspan, events)
sol = solve(prob, Tsit5())
```

## Key Advantages

### NONMEM/mrgsolve Compatibility
- Familiar column names (TIME, EVID, CMT, AMT, RATE, DURATION)
- Standard event types (EVID=1 for dosing, EVID=2 for parameter updates)
- Support for both rate-based and duration-based continuous infusions

### Continuous Infusion Innovation
- **Direct to state variables**: Infusions automatically modify differential equations
- **Automatic parameter creation**: Time-varying infusion parameters created with unique names
- **Metadata support**: Parameters marked as `input = true` and time-varying
- **Collision-free naming**: Uses `gensym()` to avoid parameter name conflicts

### Modern Julia Design
- **Multiple dispatch**: Different ODEProblem constructors for DataFrames vs. event vectors
- **Type safety**: Strong typing throughout the pipeline
- **Composable**: Works seamlessly with existing ModelingToolkit workflows
- **Performance**: Optimized callback generation and minimal runtime overhead

## Installation

```julia
using Pkg
Pkg.add("InjecKit")
```

## Manual Outline

```@contents
Pages = [
    "tutorials/getting_started.md",
    "tutorials/continuous_infusions.md",
    "tutorials/advanced_usage.md", 
    "examples.md",
    "api.md"
]
Depth = 2
```