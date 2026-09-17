# ConfigKit.jl

*"Config it"* — YAML-based parameter management for QSP modeling with ModelingToolkit.jl

## Why ConfigKit?

QSP scientists face common challenges:
- **Scattered parameters** buried in Julia code
- **Species scaling** requiring multiple files or manual copy-paste
- **Derived parameters** (like `k_el = CL/V`) that need consistent relationships
- **Provenance tracking** for regulatory submissions

ConfigKit solves these with a single YAML "keyfile" that becomes the central source of truth.

## Features

- **YAML Keyfiles**: Human-readable parameter definitions with units, descriptions, and sources
- **Variants**: Multi-species/scenario support in one file (human, mouse, rat)
- **Locked Dependencies**: Derived parameters (`k_el = CL/V`) stay consistent
- **Fast Updates**: ~50x faster parameter updates for fitting loops
- **MTK Integration**: Seamless population of ModelingToolkit systems

## Quick Start

### 1. Create a Keyfile

```yaml
# pk_params.yml
Parameters:
  CL:
    value: 5.0
    unit: L/hr
    description: "Systemic clearance"
    variants:
      human: 5.0
      mouse: 0.5

  V1:
    value: 50.0
    unit: L
    description: "Central volume"
    variants:
      human: 50.0
      mouse: 0.025

  k_el:
    value: CL / V1
    unit: 1/hr
    description: "Elimination rate constant"

Variables:
  Central:
    initial: 0.0
    unit: mg
```

### 2. Load and Populate

```julia
using QSPKit.ConfigKit
using ModelingToolkit
using DifferentialEquations

# Load keyfile with species variant
keyfile = load_keyfile("pk_params.yml", variant=:human)

# Access values
keyfile.Parameters.CL.value        # 5.0
keyfile.Parameters.CL.description  # "Systemic clearance"

# Populate your MTK system
sys_populated = populate(my_system, keyfile)

# Build and solve
sys = mtkcompile(sys_populated)
prob = ODEProblem(sys, [], (0.0, 24.0))
sol = solve(prob, Tsit5())
```

### 3. Update Parameters Efficiently

```julia
# Fast parameter updates for sensitivity analysis
new_prob = update(prob, [CL => 10.0, V1 => 100.0])
sol = solve(new_prob, Tsit5())
```

### 4. Compare Species

```julia
# See what differs between species
diff = get_variant_diff("pk_params.yml"; variant_a=:human, variant_b=:mouse)
for entry in diff
    println("$(entry.name): $(entry.value_a) → $(entry.value_b)")
end
```

## Documentation

- [Getting Started](docs/src/getting_started.md) - Installation and basic usage
- [Keyfile Format](docs/src/keyfile_format.md) - Complete YAML schema reference
- [Variants](docs/src/variants.md) - Multi-species/scenario management
- [Update Engine](docs/src/update_engine.md) - High-performance parameter updates
- [API Reference](docs/src/api_reference.md) - Complete function reference

## Installation

```julia
using Pkg
Pkg.add("ConfigKit")
```

## Key Concepts

### Expression-Valued Parameters (Bindings)

Parameters with expression values become ModelingToolkit bindings:

```yaml
Parameters:
  CL:
    value: 5.0
  V1:
    value: 50.0
  k_el:
    value: CL / V1   # Automatically computed, cannot be directly updated
```

ConfigKit protects these relationships - you cannot accidentally update `k_el` directly.

### Ghost Parameters

If your keyfile defines a parameter not in your model, ConfigKit automatically injects it as a "ghost parameter". This is useful for driving exogenous functions or inputs.

### Strict Mode

By default, `populate()` validates that all required model parameters exist in the keyfile. Use `strict=false` to allow partial population.

## Requirements

- Julia 1.10+
- ModelingToolkit.jl v11+
- DynamicQuantities.jl (for unit handling)
