# Getting Started

This tutorial will get you up and running with InjecKit.jl for NONMEM-style event handling in Julia's ModelingToolkit ecosystem.

## Installation

```julia
using Pkg
Pkg.add("InjecKit")
```

## Basic Usage

InjecKit.jl integrates seamlessly with ModelingToolkit.jl to add dosing events and parameter changes to your differential equation models.

### Setting Up a Simple Model

```julia
using QSPKit.InjecKit, ModelingToolkit, DataFrames, DifferentialEquations

# Define a simple one-compartment PK model
@parameters k V
@variables C(t)
@independent_variables t
D = Differential(t)

# Simple elimination from compartment
eqs = [D(C) ~ -k * C / V]
@mtkcompile sys = System(eqs, t)
```

### DataFrame-Based Events

The most familiar approach for users coming from NONMEM or Phoenix is to use DataFrames:

```julia
# Create dosing data
dosing_data = DataFrame(
    TIME = [0.0, 8.0, 16.0, 24.0],
    EVID = [1, 1, 1, 1],  # Dosing events
    CMT = [:C, :C, :C, :C],  # Target compartment
    AMT = [100.0, 100.0, 100.0, 100.0]  # Dose amounts
)

# Define initial conditions and parameters together
u0_p = Dict(C => 0.0, k => 0.1, V => 10.0)

# Create ODEProblem with events (4-argument form)
prob = ODEProblem(sys, u0_p, (0.0, 48.0), dosing_data)

# Solve
sol = solve(prob, Tsit5())
```

### Event Types

InjecKit.jl supports the standard NONMEM event types:

#### EVID = 1: Dosing Events
```julia
# Bolus dosing
bolus_data = DataFrame(
    TIME = [0.0, 12.0, 24.0],
    EVID = [1, 1, 1],
    CMT = [:C, :C, :C],
    AMT = [100.0, 75.0, 50.0]
)
```

#### EVID = 2: Parameter Changes
```julia
# Change elimination rate at 12 hours
param_change = DataFrame(
    TIME = [12.0],
    EVID = [2, 2],
    CMT = [:k, :V],
    AMT = [0.05, 15.0]  # New parameter values
)
```

### Combining Event Types

```julia
# Mixed dosing and parameter changes
mixed_events = DataFrame(
    TIME = [0.0, 8.0, 12.0, 16.0, 24.0],
    EVID = [1, 1, 2, 1, 1],
    CMT = [:C, :C, :k, :C, :C],
    AMT = [100.0, 100.0, 0.05, 100.0, 100.0]
)

prob = ODEProblem(sys, u0_p, (0.0, 48.0), mixed_events)
sol = solve(prob, Tsit5())
```

## Multi-Compartment Models

### Two-Compartment Model

```julia
# Define a two-compartment model with absorption
@parameters ka k12 k21 k10 V1 V2
@variables depot(t) central(t) peripheral(t)
D = Differential(t)

eqs = [
    D(depot) ~ -ka * depot,
    D(central) ~ ka * depot - (k12 + k10) * central + k21 * peripheral,
    D(peripheral) ~ k12 * central - k21 * peripheral
]

@mtkcompile sys = System(eqs, t)
```

### Multiple Compartment Dosing

```julia
# Dose to different compartments
multi_dose = DataFrame(
    TIME = [0.0, 0.0, 8.0, 16.0],
    EVID = [1, 1, 1, 1],
    CMT = [:depot, :central, :depot, :central],  # Different target compartments
    AMT = [100.0, 50.0, 100.0, 25.0]
)

u0_p = Dict(
    depot => 0.0, central => 0.0, peripheral => 0.0,
    ka => 1.0, k12 => 0.5, k21 => 0.2, k10 => 0.1, V1 => 10.0, V2 => 20.0
)

prob = ODEProblem(sys, u0_p, (0.0, 48.0), multi_dose)
sol = solve(prob, Tsit5())
```

## Visualization

```julia
using Plots

# Plot compartment concentrations
plot(sol, idxs=[central, peripheral], 
     title="Two-Compartment PK Model",
     xlabel="Time (hours)", 
     ylabel="Concentration",
     label=["Central" "Peripheral"],
     linewidth=2)
```

## Working with Missing Values

DataFrames can contain missing values for optional columns:

```julia
# Mixed complete and incomplete events
mixed_data = DataFrame(
    TIME = [0.0, 8.0, 16.0],
    EVID = [1, 2, 1],
    CMT = [:C, :k, :C],
    AMT = [100.0, missing, 75.0],  # Parameter change has no AMT
    NEW_VALUE = [missing, 0.05, missing]  # Only for EVID=2
)
```

## Best Practices

### 1. Clear Variable Names
```julia
# Good: Descriptive compartment names
@variables plasma(t) tissue(t) urine(t)

# Avoid: Generic names
@variables x(t) y(t) z(t)
```

### 2. Consistent Units
Ensure all quantities use consistent units:
- Time: hours, days, etc.
- Amounts: mg, μg, etc.  
- Rates: amount/time units
- Volumes: L, mL, etc.

### 3. Event Timing Validation
```julia
# Check that events are properly ordered
dosing_data = sort(dosing_data, :TIME)

# Verify no negative times
@assert all(dosing_data.TIME .>= 0.0) "All event times must be non-negative"
```

### 4. Initial Conditions
```julia
# Set meaningful initial conditions
u0 = [
    depot => 0.0,      # No drug initially in depot
    central => 0.0,    # No drug initially in central
    peripheral => 0.0  # No drug initially in peripheral
]
```

## Common Errors and Solutions

### Error: Unknown compartment
```
ERROR: Symbol :X not found in system
```
**Solution**: Ensure compartment names in `CMT` column match variable names in your system.

### Error: Invalid EVID
```
ERROR: EVID must be 1 (dosing) or 2 (parameter change)
```
**Solution**: Check that all `EVID` values are either 1 or 2.

### Error: Missing AMT for dosing
```
ERROR: AMT required for EVID=1 (dosing events)
```
**Solution**: Provide `AMT` values for all dosing events (EVID=1).

## Next Steps

- Learn about [Continuous Infusions](continuous_infusions.md) for rate-controlled dosing
- Explore [Advanced Usage](advanced_usage.md) for complex modeling scenarios
- Check out practical [Examples](../examples.md)
- Browse the complete [API Reference](../api.md)