# ConfigKit.jl Documentation

*"Config it"* — YAML-based parameter management for QSP modeling with ModelingToolkit.jl

## Why Use ConfigKit?

As a QSP scientist, you've probably experienced these challenges:

**Scattered Parameters**: Parameter values are buried in Julia code, making it hard to:
- Find and update values
- Share configurations with collaborators
- Track which values were used for a specific simulation

**Species Scaling**: Running the same model for mouse, rat, and human requires:
- Maintaining multiple files
- Manual copy-paste of values
- Risk of inconsistent parameter sets

**Derived Parameters**: When `k_el = CL / V`, you want:
- The relationship to be documented alongside the values
- Automatic recalculation when base parameters change
- Protection from accidentally breaking the relationship

**Parameter Provenance**: For regulatory submissions, you need:
- Documentation of where values came from
- Literature citations
- Clear descriptions of what each parameter means

**ConfigKit solves all of these problems** with a single YAML "keyfile" that becomes the central source of truth for your model parameters.

## Contents

- [Getting Started](getting_started.md) - Installation and basic usage
- [Keyfile Format](keyfile_format.md) - Complete YAML schema reference
- [Variants](variants.md) - Multi-species/scenario parameter management
- [Update Engine](update_engine.md) - High-performance parameter updates
- [API Reference](api_reference.md) - Complete function reference

## Quick Example

### 1. Create a Keyfile

All your parameters in one readable file:

```yaml
# pk_model.yml - Two-compartment PK model parameters

Parameters:
  # Absorption
  ka:
    value: 1.5
    unit: 1/hr
    description: "First-order absorption rate constant"
    source: "Synthetic literature example"
    bounds: [0.1, 10.0]

  # Clearance - varies by species
  CL:
    unit: L/hr
    description: "Systemic clearance"
    variants:
      human: 5.0
      mouse: 0.5
      rat: 2.5
    source: "Allometric scaling, BW^0.75"

  # Volume - varies by species
  V1:
    unit: L
    description: "Central compartment volume"
    variants:
      human: 50.0
      mouse: 0.025
      rat: 0.25
    source: "Allometric scaling, BW^1.0"

  # Derived parameter - automatically computed
  k_el:
    value: CL / V1
    unit: 1/hr
    description: "Elimination rate constant"

Variables:
  Depot:
    initial: 0.0
    unit: mg
    description: "Drug in absorption compartment"

  Central:
    initial: 0.0
    unit: mg
    description: "Drug in central compartment"
```

### 2. Load and Use

```julia
using ConfigKit
using ModelingToolkit
using DifferentialEquations

# Load keyfile with specific species variant
keyfile = load_keyfile("pk_model.yml", variant=:human)

# Access values with nice property syntax
keyfile.Parameters.CL.value        # 5.0
keyfile.Parameters.CL.description  # "Systemic clearance"
keyfile.Parameters.CL.source       # "Allometric scaling, BW^0.75"

# Populate your ModelingToolkit system
sys_populated = populate(sys, keyfile)

# Build and solve
sys_simplified = structural_simplify(sys_populated)
prob = ODEProblem(sys_simplified, [], (0.0, 24.0))
sol = solve(prob, Tsit5())
```

### 3. Switch Species Easily

```julia
# Same model, different species - just change the variant
keyfile_mouse = load_keyfile("pk_model.yml", variant=:mouse)
sys_mouse = populate(sys, keyfile_mouse)

# Compare species parameters
diff = get_variant_diff("pk_model.yml"; variant_a=:human, variant_b=:mouse)
for entry in diff
    println("$(entry.name): human=$(entry.value_a), mouse=$(entry.value_b)")
end
```

### 4. Update Parameters Efficiently

```julia
# Fast parameter updates for sensitivity analysis
for cl_scale in [0.5, 1.0, 2.0]
    scaled_cl = 5.0 * cl_scale
    new_prob = update(prob, [CL => scaled_cl])
    sol = solve(new_prob, Tsit5())
    # ... analyze results
end
```

## Key Features

| Feature | Benefit |
|---------|---------|
| **YAML keyfiles** | Human-readable, version-controllable parameter files |
| **Variants** | One file for all species/scenarios |
| **Locked dependencies** | Derived parameters (`k_el = CL/V`) stay consistent |
| **Units** | Automatic unit handling with DynamicQuantities |
| **Metadata** | Descriptions, sources, citations alongside values |
| **Bounds** | Parameter limits for optimization/fitting |
| **Reusable updates** | Cache symbolic lookup work across repeated parameter updates |

## Design Philosophy

1. **Central Source of Truth**: All parameter values, units, and metadata in one place
2. **Separation of Concerns**: Parameter definitions (YAML) separate from model code (Julia)
3. **Ergonomic Access**: Property-based API (`keyfile.Parameters.CL.value`) feels natural
4. **Safety**: Locked dependencies prevent inconsistent parameter sets
5. **Performance**: Reusable update caches reduce repeated symbolic setup work
