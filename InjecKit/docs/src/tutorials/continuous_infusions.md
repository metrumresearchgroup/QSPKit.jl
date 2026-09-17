# Continuous Infusions

This tutorial covers the continuous infusion functionality in InjecKit.jl, which allows you to add infusions directly to state variables in your differential equations, similar to how NONMEM and mrgsolve handle continuous infusions.

## Overview

Traditional pharmacokinetic modeling tools like NONMEM and mrgsolve allow you to specify continuous infusions directly to compartments by specifying:
- **RATE > 0**: Infusion rate (amount/time)
- **AMT + DURATION**: Total amount over specified duration
- **AMT + RATE**: Total amount at specified rate (duration calculated automatically)

InjecKit.jl brings this same functionality to Julia, automatically modifying your differential equations to include time-varying infusion terms.

## Basic Concepts

### How Continuous Infusions Work

When you specify a continuous infusion to a state variable (like a compartment), InjecKit.jl:

1. **Creates infusion parameters**: Automatically generates time-varying parameters with unique names
2. **Modifies differential equations**: Adds infusion terms to the target compartment's equation
3. **Creates callbacks**: Sets up start/stop events to control the infusion timing
4. **Handles parameter metadata**: Marks infusion parameters as `input = true` and time-varying

For example, if you have:
```julia
D(C) ~ -k * C / V  # Original equation
```

With a continuous infusion, it becomes:
```julia
D(C) ~ -k * C / V + infusion_rate_C  # Modified with infusion
```

### Event Types

InjecKit.jl detects continuous infusions using the same logic as NONMEM:
- **EVID = 1** (dosing event) AND
- **RATE > 0** OR **(AMT > 0 AND DURATION > 0)**

## DataFrame-Based Infusions

### Basic Example

```julia
using QSPKit.InjecKit, ModelingToolkit, DataFrames, DifferentialEquations

# Define a two-compartment model
@parameters k12 k21 k10 V1 V2
@variables C1(t) C2(t)  
@independent_variables t
D = Differential(t)

eqs = [
    D(C1) ~ -(k12 + k10) * C1 / V1 + k21 * C2 / V1,
    D(C2) ~ k12 * C1 / V2 - k21 * C2 / V2
]

@mtkcompile sys = System(eqs, t)
```

Define infusion events:

```julia
# Mixed bolus and infusion dosing
dosing = DataFrame(
    TIME = [0.0, 0.0, 4.0, 8.0, 12.0],
    EVID = [1, 1, 1, 1, 1],
    CMT = [:C1, :C2, :C1, :C2, :C1],
    AMT = [100.0, missing, 200.0, 150.0, 75.0],
    RATE = [0.0, 10.0, missing, 25.0, 0.0],  # Bolus, infusion, infusion, infusion, bolus
    DURATION = [missing, missing, 2.0, missing, missing]  # Only for AMT+DURATION
)

# Create and solve problem
u0 = [C1 => 0.0, C2 => 0.0]
p = [k12 => 1.0, k21 => 0.5, k10 => 0.1, V1 => 10.0, V2 => 20.0]

prob = ODEProblem(sys, u0, (0.0, 24.0), dosing, p)
sol = solve(prob, Tsit5())
```

### Understanding the Different Infusion Types

1. **Rate-based infusion** (`RATE > 0`):
   ```julia
   # 50 units over 5 hours (RATE=10, AMT=50)
   DataFrame(TIME=[2.0], EVID=[1], CMT=[:C1], AMT=[50.0], RATE=[10.0])
   ```

2. **Duration-based infusion** (`AMT > 0, DURATION > 0`):
   ```julia
   # 60 units over 3 hours (calculated rate = 20)  
   DataFrame(TIME=[4.0], EVID=[1], CMT=[:C1], AMT=[60.0], DURATION=[3.0])
   ```

3. **Bolus dose** (`RATE = 0` or missing):
   ```julia
   # Instantaneous 100 unit dose
   DataFrame(TIME=[0.0], EVID=[1], CMT=[:C1], AMT=[100.0], RATE=[0.0])
   ```

## IEvent-Based Infusions

For a more programmatic approach, use the `ev()` function inspired by mrgsolve:

### Basic IEvent Usage

```julia
# Create events using mrgsolve-like syntax
events = [
    ev(time=0.0, cmt=:C1, amt=100.0),                    # Bolus
    ev(time=2.0, cmt=:C1, amt=50.0, rate=10.0),          # Rate-based infusion
    ev(time=6.0, cmt=:C2, amt=75.0, duration=2.5),       # Duration-based infusion
    ev(time=12.0, cmt=:C1, amt=25.0)                     # Another bolus
]

# Direct ODEProblem creation
prob = ODEProblem(sys, u0, (0.0, 20.0), events, p)
sol = solve(prob, Tsit5())
```

### Advanced IEvent Features

```julia
# Complex dosing regimen
complex_events = [
    # Initial loading dose
    ev(time=0.0, cmt=:C1, amt=200.0),
    
    # Maintenance infusion (rate-based)
    ev(time=1.0, cmt=:C1, amt=480.0, rate=20.0),  # 24-hour infusion
    
    # Concurrent infusion to second compartment
    ev(time=6.0, cmt=:C2, amt=300.0, duration=6.0), # 6-hour infusion
    
    # Rescue bolus
    ev(time=18.0, cmt=:C1, amt=100.0),
    
    # Final maintenance infusion
    ev(time=25.0, cmt=:C1, amt=360.0, rate=15.0)   # 24-hour infusion
]

prob = ODEProblem(sys, u0, (0.0, 72.0), complex_events, p)
```

## Parameter Validation and Calculation

### Automatic Parameter Calculation

InjecKit.jl automatically calculates missing parameters:

```julia
# These are equivalent:
ev(time=0.0, cmt=:C, amt=100.0, rate=20.0)     # duration = 100/20 = 5.0
ev(time=0.0, cmt=:C, amt=100.0, duration=5.0)  # rate = 100/5.0 = 20.0  
ev(time=0.0, cmt=:C, rate=20.0, duration=5.0)  # amt = 20*5 = 100.0 (implicit)
```

### Error Handling

```julia
# These will throw errors:
ev(time=0.0, cmt=:C)                                # No dosing info
ev(time=0.0, cmt=:C, amt=100.0)                     # Missing rate or duration
ev(time=0.0, cmt=:C, amt=100.0, rate=20.0, duration=5.0)  # Over-specified
ev(time=0.0, cmt=:C, amt=0.0, rate=10.0)           # Zero amount
ev(time=0.0, cmt=:C, amt=100.0, rate=0.0)          # Zero rate (use bolus instead)
```

## Infusion to Existing Parameters

### Using Existing Time-Varying Parameters

Instead of creating new infusion parameters, you can infuse directly into existing time-varying parameters:

```julia
# Define model with existing infusion parameter
@parameters k V
@discretes infusion_input(t) [input = true]
@variables C(t)
D = Differential(t)

# Include infusion parameter in the equation
eqs = [D(C) ~ -k * C / V + infusion_input]
@mtkcompile sys = System(eqs, t)

# Now infuse directly to the existing parameter
dosing = DataFrame(
    TIME = [2.0, 8.0],
    EVID = [1, 1], 
    CMT = [:infusion_input, :infusion_input],  # Target existing parameter
    AMT = [100.0, 150.0],
    RATE = [20.0, 25.0]
)

prob = ODEProblem(sys, u0, (0.0, 20.0), dosing, p)
```

### Parameter Validation

When targeting existing parameters, InjecKit.jl validates:
- **Input metadata**: Parameter must have `[input = true]`
- **Time dependence**: Parameter must be time-varying (e.g., `param(t)`)

```julia
# This will work:
@discretes good_param(t) [input = true]

# These will throw errors:
@parameters bad_param1     # Not time-varying
@discretes bad_param2(t)  # Missing input = true metadata
```

## Analyzing Infusion History

### Finding Infusion Parameters

```julia
# After solving with continuous infusions
infusion_params = get_infusion_parameters(sol.prob.f.sys)
println("Found $(length(infusion_params)) infusion parameters")

for param in infusion_params
    println("  - $(param)")
end
```

### Plotting Infusion Rates

```julia
using Plots

# Plot the infusion rate over time for compartment C1
plot_infusion_history(sol, :C1)

# Or manually access infusion parameters
infusion_params = get_infusion_parameters(sol.prob.f.sys)
for param in infusion_params
    if contains(string(param), "C1")
        plot!(sol, idxs=param, label="Infusion rate to C1")
    end
end
```

## Performance Considerations

### Efficient Infusion Handling

InjecKit.jl is designed for efficiency:

- **Unique parameter names**: Uses `gensym()` to avoid collisions without checking
- **Minimal equation modification**: Only modifies equations for targeted compartments  
- **Optimized callbacks**: Efficient start/stop event generation
- **Type stability**: All operations are type-stable for performance

### Large Datasets

For datasets with many infusion events:

```julia
# Generate large infusion dataset
n_events = 1000
large_dosing = DataFrame(
    TIME = sort(rand(n_events) * 168.0),  # Over 1 week
    EVID = fill(1, n_events),
    CMT = rand([:C1, :C2], n_events),
    AMT = rand(10.0:200.0, n_events),
    RATE = rand(1.0:50.0, n_events)
)

# Efficient processing
@time prob = ODEProblem(sys, u0, (0.0, 168.0), large_dosing, p)
```

## Best Practices

### 1. Clear Compartment Naming
```julia
# Good: Clear compartment names
@variables plasma(t) tissue(t) urine(t)

# Avoid: Generic names that might conflict
@variables x(t) y(t) z(t)
```

### 2. Consistent Units
```julia
# Ensure consistent units throughout
# If AMT is in mg and TIME is in hours, RATE should be mg/hour
dosing = DataFrame(
    TIME = [0.0, 4.0],      # hours
    AMT = [100.0, 200.0],   # mg  
    RATE = [25.0, 50.0]     # mg/hour
)
```

### 3. Validation of Complex Regimens
```julia
# For complex dosing, validate timing and amounts
events = [
    ev(time=0.0, cmt=:C, amt=100.0),
    ev(time=2.0, cmt=:C, amt=150.0, rate=25.0),  # 6-hour infusion
    ev(time=8.0, cmt=:C, amt=100.0),             # Starts after infusion ends
]

# Check timing: second infusion ends at 2.0 + 150/25 = 8.0 hours ✓
```

### 4. Monitoring Infusion Parameters
```julia
# After solving, inspect infusion parameters
sol = solve(prob, Tsit5(), saveat=0.5)
infusion_params = get_infusion_parameters(sol.prob.f.sys)

# Plot all infusion rates
p_infusion = plot()
for param in infusion_params
    plot!(p_infusion, sol, idxs=param, 
          label="$(param)", linewidth=2)
end
```

## Common Patterns

### Loading Dose + Maintenance Infusion
```julia
maintenance_dosing = [
    ev(time=0.0, cmt=:plasma, amt=100.0),              # Loading bolus
    ev(time=0.5, cmt=:plasma, amt=480.0, rate=20.0),   # 24h maintenance  
]
```

### Multiple Compartment Infusions  
```julia
multi_compartment = [
    ev(time=0.0, cmt=:central, amt=200.0),
    ev(time=2.0, cmt=:central, amt=300.0, rate=50.0),  # Central infusion
    ev(time=4.0, cmt=:peripheral, amt=100.0, rate=10.0), # Peripheral infusion
]
```

### Sequential Infusions
```julia
sequential = [
    ev(time=0.0, cmt=:C, amt=200.0, rate=40.0),   # 0-5h: high rate
    ev(time=5.0, cmt=:C, amt=600.0, rate=20.0),   # 5-35h: maintenance rate  
    ev(time=35.0, cmt=:C, amt=100.0, rate=5.0),   # 35-55h: low rate
]
```

This comprehensive continuous infusion system makes InjecKit.jl a powerful tool for pharmacokinetic modeling with the familiar NONMEM/mrgsolve workflow but in modern, performant Julia.