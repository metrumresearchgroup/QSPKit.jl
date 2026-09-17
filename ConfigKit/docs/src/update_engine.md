# Update Engine

The public repeated-update API consists of `UpdateCache`, `update!`,
`with_update_cache`, `thread_update_cache`, and `with_thread_update_cache`.
Prepared problems can be inspected with `prepared_update_source`, which returns
a `PreparedUpdateSource`; invalid binding updates raise `BindingUpdateError`.

The update engine provides high-performance parameter updates for ODE problems and integrators. This is essential for workflows that require many parameter updates, such as:

- **Parameter estimation / fitting** - Testing thousands of parameter combinations
- **Sensitivity analysis** - Systematically varying parameters
- **Virtual population simulations** - Running models with different patient parameters
- **Monte Carlo simulations** - Sampling from parameter distributions

## The Problem with Naive Updates

In ModelingToolkit, updating parameters typically requires rebuilding the problem:

```julia
# Naive approach - slow!
new_prob = remake(prob, p = [CL => 10.0, V1 => 100.0])
```

This is fine for occasional updates, but in a parameter estimation loop with 10,000+ iterations, the overhead adds up significantly.

## ConfigKit's Solution

ConfigKit's `update()` function uses intelligent caching to make parameter updates ~50x faster:

```julia
using QSPKit.ConfigKit

# First call builds cache (~2ms)
new_prob = update(prob, [CL => 10.0])

# Subsequent calls are fast (~50μs)
new_prob = update(prob, [CL => 15.0])
new_prob = update(prob, [CL => 20.0])
# ... thousands more iterations
```

## Basic Usage

### Updating ODEProblems

```julia
using QSPKit.ConfigKit
using ModelingToolkit
using DifferentialEquations

# After building your problem...
prob = ODEProblem(sys, [], (0.0, 24.0))

# Update single parameter
new_prob = update(prob, [CL => 10.0])

# Update multiple parameters
new_prob = update(prob, [CL => 10.0, V1 => 100.0, ka => 2.0])

# Solve the updated problem
sol = solve(new_prob, Tsit5())
```

### Updating Integrators

For callbacks or real-time parameter changes during simulation:

```julia
# Create integrator
integrator = init(prob, Tsit5())

# Update parameters mid-simulation
update(integrator, [CL => 5.0])

# Continue stepping
step!(integrator)
```

### Flexible Key Types

The `update()` function accepts multiple key formats:

```julia
# Symbolic keys (if you have the variable reference)
update(prob, [CL => 10.0])

# Symbol keys
update(prob, [:CL => 10.0])

# String keys
update(prob, ["CL" => 10.0])
```

## Expression-Valued Parameters (Bindings)

When you define a parameter with an expression value in your keyfile, it becomes a **binding** - a parameter whose value is computed from other parameters:

```yaml
Parameters:
  CL:
    value: 5.0
    unit: L/hr

  V1:
    value: 50.0
    unit: L

  k_el:
    value: CL / V1    # k_el is a binding (expression value)
    unit: 1/hr
```

### What Happens When You Try to Update a Binding?

```julia
# This will error!
update(prob, [:k_el => 2.0])
# ERROR: Cannot update 'k_el' — it is a bound parameter defined as: CL / V1
#        Update the underlying parameters instead.
```

ConfigKit protects you from accidentally breaking the mathematical relationship. Instead, update the base parameters:

```julia
# Correct approach - update base parameters
new_prob = update(prob, [:CL => 10.0])
# k_el will automatically be recomputed as CL/V1 = 10.0/50.0 = 0.2
```

### Why This Matters for QSP

In QSP models, many parameters have physiological relationships:
- `k_el = CL / V` (elimination rate from clearance and volume)
- `half_life = log(2) / k_el` (half-life from rate constant)
- `AUC = Dose / CL` (exposure from dose and clearance)

ConfigKit ensures these relationships are always maintained, preventing inconsistent parameter sets that could produce meaningless results.

## Performance Tips

### 1. Batch Updates

Update all parameters at once rather than one at a time:

```julia
# Good - single call
new_prob = update(prob, [CL => 10.0, V1 => 100.0, ka => 2.0])

# Avoid - multiple calls
prob1 = update(prob, [CL => 10.0])
prob2 = update(prob1, [V1 => 100.0])
prob3 = update(prob2, [ka => 2.0])
```

### 2. Use the Same Problem Reference

The cache is associated with the original problem structure. Reuse the same base problem:

```julia
# Build problem once
prob = ODEProblem(sys, [], (0.0, 24.0))

# All updates reference the same structure
for cl_val in [1.0, 5.0, 10.0, 20.0]
    new_prob = update(prob, [CL => cl_val])  # Uses cached structure
    sol = solve(new_prob, Tsit5())
    # ... process results
end
```

### 3. Parameter Estimation Example

```julia
using Optim

function objective(params)
    cl, v1 = params
    new_prob = update(prob, [CL => cl, V1 => v1])
    sol = solve(new_prob, Tsit5(), saveat=timepoints)

    # Compare to observed data
    predicted = sol[Central]
    return sum((predicted .- observed).^2)
end

# Optimize with fast updates
result = optimize(objective, [5.0, 50.0], BFGS())
```

## Troubleshooting

### "Cannot update binding" Error

**Cause:** You're trying to update a parameter with an expression value (a binding)

**Solution:** Update the base parameters instead. Check your keyfile to see which parameters `k_el` (or the problematic parameter) depends on.

### Cache Invalidation

The cache is keyed by the system structure. If you:
- Modify the system equations
- Add/remove parameters
- Change the model structure

You may need to rebuild the problem. The cache handles this automatically by detecting structural changes.

### Memory Usage

Each unique problem structure maintains its own cache entry. The cache uses an LRU (Least Recently Used) eviction policy with a maximum of 1000 entries, so memory usage is bounded automatically. Old entries are evicted when the cache is full.
