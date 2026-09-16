# Fitting

TargKit provides a `fit()` function that wraps the Optimization.jl ecosystem into a convenient interface for QSP parameter estimation.

## fit()

```julia
result = fit(obj::ObjectiveConfig; kwargs...) -> FitResult
```

### Keyword Arguments

| Argument | Type | Default | Description |
|----------|------|---------|-------------|
| `method` | `Symbol` | `:pso_nm` | Optimization method (see below) |
| `n_restarts` | `Int` | `3` | Number of PSO restarts (for PSO methods) |
| `pso_iters` | `Int` | `75` | Max iterations per PSO restart |
| `nm_iters` | `Int` | `300` | Max NelderMead iterations |
| `lbfgs_iters` | `Int` | `200` | Max L-BFGS iterations |
| `n_particles` | `Int` | `20` | PSO swarm size |
| `x0` | `Vector{Float64}` or `nothing` | `nothing` | Initial point in transform space |
| `verbose` | `Bool` | `true` | Print progress |

### Counter Reset

`fit()` automatically calls `reset!(obj)` at the start, resetting the evaluation counter and best-loss tracker. If an `on_eval` callback is supplied, its progress tracking starts fresh for each `fit()` call.

### Starting Point

If `x0` is not provided, `fit()` starts at the midpoint of the (log-)bounds. If `x0` is provided, it must be in the transform space (i.e., log-space if `transform=:log`).

For warm-starting from a previous result:
```julia
result1 = fit(obj)
result2 = fit(obj; x0=result1.x, method=:nm)  # polish from previous result
```

## Available Methods

### :nm -- NelderMead Only

```julia
result = fit(obj; method=:nm)
```

Derivative-free simplex method. Runs NelderMead from the starting point without bounds enforcement (relies on the objective returning high penalties for out-of-bounds evaluations).

**When to use:**
- Local polishing from a known good starting point
- Quick refinement after a global search
- When the objective is noisy or non-smooth

### :pso_nm -- PSO then NelderMead (default)

```julia
result = fit(obj; method=:pso_nm, n_restarts=3, pso_iters=75, nm_iters=300)
```

Two-stage approach:
1. **PSO (Particle Swarm Optimization)**: Global search with `n_restarts` independent runs. The first restart starts from `x0`; subsequent restarts start from random points within bounds. The best result across all restarts is kept.
2. **NelderMead**: Local polish starting from the best PSO point.

Returns whichever of the PSO or NelderMead result is better.

**When to use:** Default recommendation for most QSP calibrations. The global PSO stage explores the parameter space, while NelderMead refines the solution.

### :lbfgs -- L-BFGS Only

```julia
result = fit(obj; method=:lbfgs, lbfgs_iters=200)
```

Bounded L-BFGS with finite-difference gradients (via `Optimization.AutoFiniteDiff()`). Respects the parameter bounds. The starting point is clamped to bounds.

**When to use:**
- When the objective is smooth and you want gradient-based convergence
- MLE/MAP objectives (which are smooth by construction)
- When you have a good starting point and want fast convergence

**Limitation:** Not suitable for objectives with discontinuities or when `simulate` is very noisy.

### :pso_lbfgs -- PSO then L-BFGS

```julia
result = fit(obj; method=:pso_lbfgs, n_restarts=3, pso_iters=75, lbfgs_iters=200)
```

Two-stage: PSO global search followed by bounded L-BFGS polish. Combines global exploration with gradient-based refinement.

**When to use:** MLE/MAP objectives where you need both global exploration and efficient local convergence. Generally the best choice for MLE/MAP with many parameters.

## Method Selection Guide

| Scenario | Recommended Method | Rationale |
|----------|-------------------|-----------|
| General QSP calibration (LS) | `:pso_nm` | Global + local, no gradients needed |
| Quick local polish | `:nm` | Fast, from known good starting point |
| MLE/MAP with good starting point | `:lbfgs` | Smooth objective, gradient-based |
| MLE/MAP, need global search | `:pso_lbfgs` | Global + gradient polish |
| Many parameters (>15) | `:pso_nm` with more restarts | Increase `n_restarts` and `pso_iters` |

## FitResult

```julia
struct FitResult
    params::Dict{Symbol, Float64}   # fitted parameter values (natural space)
    loss::Float64                    # final objective value
    x::Vector{Float64}              # raw parameter vector in transform space
    report::Union{ScoreReport, Nothing}  # ScoreReport at the solution
    converged::Bool                 # true if optimizer returned Success
    method::Symbol                  # which method was used
end
```

### Inspecting results

```julia
result = fit(obj)

# Fitted parameters (natural space)
result.params           # Dict(:k1 => 1.23, :k2 => 4.56)

# Objective value
result.loss             # 0.0452

# Convergence status
result.converged        # true

# Full ScoreReport
println(result.report)  # pretty-printed OK/MISS table

# Raw vector (for warm-starting)
result.x                # [0.207, 1.516] (log-space if transform=:log)
```

### Verbose output

When `verbose=true` (default), `fit()` prints:

```
TargKit.fit: method=:pso_nm, 12 params, 25 targets
  PSO restart 1/3: loss = 2.345678
  PSO restart 2/3: loss = 1.876543
  PSO restart 3/3: loss = 2.012345
  NelderMead polish from PSO best (loss = 1.876543)
  NelderMead: loss = 0.452100, retcode = Success
  Final loss: 0.4521, converged: true
  Targets met: 25/25
```

Warnings are printed for parameters at bounds:
```
  WARNING: 2 params at bounds
```

## Advanced: Manual Optimization.jl Usage

For power users who need more control, you can use the `ObjectiveConfig` directly with Optimization.jl:

```julia
using Optimization, OptimizationOptimJL

obj = objective(targets; simulate, params, bounds, type=:mle)

# Build Optimization.jl problem manually
f = OptimizationFunction((x, p) -> obj(x), Optimization.AutoFiniteDiff())
prob = OptimizationProblem(f, x0; lb=obj.log_bounds.lb, ub=obj.log_bounds.ub)

# Use any Optimization.jl solver
sol = solve(prob, LBFGS(); maxiters=500)

# Extract results
real_params = exp.(sol.u)  # if transform=:log
```

This gives you access to the full Optimization.jl ecosystem (callbacks, tolerance settings, alternative solvers, etc.) while still using TargKit's objective evaluation.

## Tips

1. **Always optimize in log-space** (`transform=:log`, the default). QSP parameters are positive and often span orders of magnitude.

2. **Start with :pso_nm** for exploration, then switch to `:nm` or `:lbfgs` for final polishing from the best result.

3. **Increase PSO restarts** for high-dimensional problems. With 15+ parameters, use `n_restarts=5` or more.

4. **Check for parameters at bounds.** If `fit()` reports parameters at bounds, your bounds may be too tight or your model may be structurally identifiable only at the boundary.

5. **Use warm starts** to chain optimizations:
   ```julia
   r1 = fit(obj; method=:pso_nm, n_restarts=5)
   r2 = fit(obj; method=:nm, x0=r1.x, nm_iters=1000)
   ```
