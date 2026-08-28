# Optics (Accessors.jl Integration)

ConfigKit integrates with [Accessors.jl](https://github.com/JuliaObjects/Accessors.jl) to provide composable lenses for ModelingToolkit parameter access. This enables functional-style parameter manipulation using `set`, `modify`, and standard lens composition.

## MTKParamLens

`MTKParamLens` is an Accessors.jl-compatible lens that wraps `ConfigKit.update` for reading and writing MTK parameters on an `ODEProblem`.

```julia
using ConfigKit, Accessors

lens = MTKParamLens(:CL)

# Read the current value
val = lens(prob)

# Set a new value (returns a new ODEProblem)
prob2 = set(prob, lens, 0.5)

# Modify with a function
prob3 = modify(v -> v * 2, prob, lens)
```

## The `@param` Macro

`@param` is a convenience macro for creating `MTKParamLens` instances:

```julia
lens = @param(CL)        # equivalent to MTKParamLens(:CL)
prob2 = set(prob, lens, 10.0)
```

## `bounds_from` — Extracting Bounds from a Keyfile

`bounds_from` extracts the `(lower, upper)` bounds for a parameter from a loaded keyfile. This is useful for optimization and fitting workflows where you need parameter constraints.

```julia
kf = load_keyfile("keyfile.yml")
lb, ub = bounds_from(kf, :CL)
```

Throws an error if the parameter has no `bounds` defined in the keyfile.

## Examples

### Parameter Sweep

```julia
using ConfigKit, Accessors

cl_lens = @param(CL)

# Sweep over CL values
results = map([1.0, 5.0, 10.0, 20.0]) do cl_val
    prob_i = set(prob, cl_lens, cl_val)
    solve(prob_i, Tsit5())
end
```

### Scaling Parameters

```julia
v1_lens = @param(V1)

# Double the volume
prob_scaled = modify(v -> v * 2, prob, v1_lens)
```

### Optimization with Bounds

```julia
kf = load_keyfile("pk_params.yml")

# Get bounds for fitting
cl_lb, cl_ub = bounds_from(kf, :CL)
v1_lb, v1_ub = bounds_from(kf, :V1)

# Use in an optimization setup
lower = [cl_lb, v1_lb]
upper = [cl_ub, v1_ub]
```
