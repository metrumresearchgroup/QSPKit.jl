# Getting Started

This guide walks you through setting up ConfigKit and using it to manage parameters for a QSP model.

## Installation

```julia
using Pkg
Pkg.develop(path="path/to/QSPKit/ConfigKit")
```

## Your First Keyfile

A **keyfile** is a YAML file that contains all your model parameters, initial conditions, and constants. Instead of scattering values throughout your Julia code, you define them once in a readable format.

### Step 1: Create the Keyfile

Create a file called `pk_params.yml`:

```yaml
# pk_params.yml
# Parameters for a simple one-compartment PK model

Parameters:
  CL:
    value: 5.0
    unit: L/hr
    description: "Systemic clearance"

  V1:
    value: 50.0
    unit: L
    description: "Volume of distribution"

  ka:
    value: 1.5
    unit: 1/hr
    description: "Absorption rate constant"
    bounds: [0.1, 10.0]

Variables:
  Depot:
    initial: 100.0
    unit: mg
    description: "Initial dose in depot compartment"

  Central:
    initial: 0.0
    unit: mg
    description: "Drug in central compartment"
```

### Step 2: Load the Keyfile

```julia
using ConfigKit

keyfile = load_keyfile("pk_params.yml")
```

### Step 3: Access Values

ConfigKit provides an ergonomic property-based API:

```julia
# Get parameter values
CL = keyfile.Parameters.CL.value        # 5.0
V1 = keyfile.Parameters.V1.value        # 50.0

# Get initial conditions (variables also use .value)
depot_init = keyfile.Variables.Depot.value      # 100.0

# Get metadata (stored in .metadata dict)
keyfile.Parameters.CL.metadata[:description]    # "Systemic clearance"
keyfile.Parameters.CL.unit                      # L/hr (as DynamicQuantities)
keyfile.Parameters.ka.metadata[:bounds]         # (0.1, 10.0)

# Iterate over all parameters
for param in keyfile.Parameters
    println("$(param.name): $(param.value) $(param.unit)")
end
```

## Populating a ModelingToolkit Model

The real power comes when you connect your keyfile to a ModelingToolkit system.

### Step 1: Define Your Model

Write your ModelingToolkit model as usual:

```julia
using ModelingToolkit
using DifferentialEquations
using ConfigKit

# Define the model structure
@variables t
@variables Central(t) Depot(t)
@parameters CL V1 ka

D = Differential(t)

eqs = [
    D(Depot) ~ -ka * Depot,
    D(Central) ~ ka * Depot - (CL/V1) * Central
]

@named pk_model = System(eqs, t)
```

### Step 2: Load and Populate

```julia
# Load keyfile
keyfile = load_keyfile("pk_params.yml")

# Populate the system with keyfile values
# This sets initial conditions, parameter defaults, and handles units
sys_populated = populate(pk_model, keyfile)

# Compile and build
sys_final = mtkcompile(sys_populated)
prob = ODEProblem(sys_final, [], (0.0, 24.0))
```

### Step 3: Solve and Analyze

```julia
sol = solve(prob, Tsit5())

# Plot results
using Plots
plot(sol, idxs=[Central], xlabel="Time (hr)", ylabel="Amount (mg)")
```

## Updating Parameters

Once you have a problem, you can efficiently update parameters:

```julia
# Update clearance
new_prob = update(prob, [CL => 10.0])
new_sol = solve(new_prob, Tsit5())

# Update multiple parameters
new_prob = update(prob, [CL => 10.0, V1 => 100.0])
```

This is much faster than rebuilding the problem from scratch, especially when you need to run many simulations with different parameters.

## Using Variants for Species Scaling

Variants let you define different parameter sets in the same file:

```yaml
# pk_params_species.yml

Parameters:
  CL:
    unit: L/hr
    description: "Systemic clearance"
    variants:
      human: 5.0
      mouse: 0.5
      rat: 2.5
    source: "Allometric scaling"

  V1:
    unit: L
    description: "Volume of distribution"
    variants:
      human: 50.0
      mouse: 0.025
      rat: 0.25
```

Load the variant you need:

```julia
# Load human parameters
keyfile_human = load_keyfile("pk_params_species.yml", variant=:human)

# Load mouse parameters
keyfile_mouse = load_keyfile("pk_params_species.yml", variant=:mouse)

# Compare variants
diff = get_variant_diff("pk_params_species.yml"; variant_a=:human, variant_b=:mouse)
for entry in diff
    println("$(entry.name): human=$(entry.value_a), mouse=$(entry.value_b), ratio=$(entry.ratio)")
end
```

## Expression-Valued Parameters

Define parameters that are computed from other parameters by using expressions as values:

```yaml
Parameters:
  CL:
    value: 5.0
    unit: L/hr

  V1:
    value: 50.0
    unit: L

  k_el:
    value: CL / V1    # Expression - automatically computed!
    unit: 1/hr
    description: "Elimination rate constant"

  half_life:
    value: log(2) / k_el
    unit: hr
    description: "Terminal half-life"
```

When you populate the system:
- `k_el` becomes a **binding** (MTK v11+ terminology)
- Its value is always computed as `CL / V1`
- You cannot directly update `k_el`; update `CL` or `V1` instead

This ensures physiological relationships are always maintained.

## Next Steps

- [Keyfile Format](keyfile_format.md) - Complete reference for all keyfile options
- [Variants](variants.md) - Deep dive into multi-species/scenario management
- [Update Engine](update_engine.md) - Optimizing parameter update performance
- [API Reference](api_reference.md) - Full function documentation

## Common Workflow

Here's a typical QSP workflow with ConfigKit:

```julia
using ConfigKit
using ModelingToolkit
using DifferentialEquations

# 1. Load parameters for your species
keyfile = load_keyfile("model_params.yml", variant=:human)

# 2. Build and populate model
include("model_definition.jl")  # Your MTK model
sys = populate(pk_model, keyfile)
sys = structural_simplify(sys)
prob = ODEProblem(sys, [], (0.0, 168.0))  # 1 week simulation

# 3. Run baseline simulation
sol_baseline = solve(prob, Tsit5())

# 4. Parameter sensitivity analysis
for cl_factor in [0.5, 1.0, 2.0]
    new_prob = update(prob, [CL => keyfile.Parameters.CL.value * cl_factor])
    sol = solve(new_prob, Tsit5())
    # ... analyze results
end

# 5. Compare to preclinical species
keyfile_mouse = load_keyfile("model_params.yml", variant=:mouse)
sys_mouse = populate(pk_model, keyfile_mouse)
# ... run mouse simulations
```
