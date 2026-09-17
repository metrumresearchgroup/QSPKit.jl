# Objective Functions

TargKit provides four objective function types through the `objective()` builder. Each wraps the target scoring machinery into a callable object suitable for optimization.

## Building an Objective

```julia
obj = objective(targets;
    simulate,                          # (overrides::Dict) -> ctx or nothing
    params,                            # Vector{Symbol} of parameter names
    bounds,                            # (lb=Float64[], ub=Float64[])
    type     = :ls,                    # :ls, :wls, :mle, :map
    transform = :log,                  # :log or :none
    priors   = Dict{Symbol,Prior}(),   # for :map only
    failure_penalty = 1e10,            # returned when simulate returns nothing
    on_eval  = nothing,                # optional progress callback
    bounds_penalty = nothing,          # soft quadratic penalty coefficient
)
```

### Arguments

| Argument | Type | Description |
|----------|------|-------------|
| `targets` | `TargetSet` or `Vector{TargetSet}` | Targets to evaluate |
| `simulate` | `Function` | `(overrides::Dict{Symbol,Float64}) -> ctx` or `nothing` on failure |
| `params` | `Vector{Symbol}` | Parameter names (order matches the `x` vector) |
| `bounds` | `NamedTuple{(:lb,:ub)}` | Lower and upper bounds in natural (untransformed) space |
| `type` | `Symbol` | Objective type (see below) |
| `transform` | `Symbol` | `:log` = optimize in log-space (default), `:none` = natural space |
| `priors` | `Dict{Symbol,Prior}` | Prior distributions for MAP estimation |
| `failure_penalty` | `Float64` | Returned when `simulate` returns `nothing` |
| `on_eval` | `Function` or `nothing` | Optional progress callback (see below). Defaults to `nothing` for silent evaluation. |
| `bounds_penalty` | `Float64` or `nothing` | Soft quadratic bounds penalty coefficient. When set, out-of-bounds evaluations return `1e6 + coeff * sum(violation^2)` without calling `simulate`. Useful for NelderMead which is unconstrained. |

### The ObjectiveConfig is callable

The returned `ObjectiveConfig` is a callable struct:

```julia
obj(x)       # evaluate at parameter vector x (in transform space)
obj(x, p)    # same, ignores p (Optimization.jl compatibility)
```

### Parameter Transform

When `transform=:log` (the default), TargKit:
1. Receives `x` in log-space
2. Applies `exp.(x)` to get natural-space parameter values
3. Passes the natural-space Dict to `simulate(overrides)`
4. Bounds are stored as both `bounds` (natural) and `log_bounds` (log-transformed)

Log-space is strongly recommended for QSP parameters, which are typically positive and span orders of magnitude.

### The simulate Function

Your `simulate` function receives a `Dict{Symbol, Float64}` mapping parameter names to values (in natural space) and must return:
- A **context object** (anything) that will be passed to `predict(ctx, t)` functions -- or
- `nothing` to signal simulation failure (e.g., ODE solver error)

On `nothing`, TargKit returns `failure_penalty` instead of trying to score.

## Objective Types

### Least Squares (`:ls`)

```julia
obj = objective(targets; simulate, params, bounds, type=:ls)
```

**Definition:**

$$L(\theta) = \sum_{i} w_i \cdot d(f_i(\theta), y_i)$$

where $d$ is determined by each target's `loss` type:

| `loss` | $d(f, y)$ |
|--------|-----------|
| `:log` | $(\log f - \log y)^2$ |
| `:squared` | $(f - y)^2$ |
| `:range_only` | $0$ if $f \in [\text{lo}, \text{hi}]$; $(\text{boundary} - f)^2$ otherwise |
| `:series_mse` | $\text{mean}((f_j - y_j)^2)$ |

LS delegates directly to `compute_loss()` from the scoring module. No error models are required.

**When to use:** Quick calibration, exploration, and when you don't have error model information. This is the simplest and fastest objective type.

### Weighted Least Squares (`:wls`)

```julia
obj = objective(targets; simulate, params, bounds, type=:wls)
```

**Definition:**

$$L(\theta) = \sum_{i} \frac{(f_i(\theta) - y_i)^2}{\sigma_i^2}$$

where $\sigma_i$ is the effective standard deviation for target $i$, derived from its error model:

| Error Model | $\sigma_i$ |
|-------------|-----------|
| `:additive` | `target.sigma` |
| `:proportional` | $\|f_i\| \cdot \text{CV}$ |
| `:lognormal` | `target.omega` |
| `:combined` | $\sqrt{(f_i \cdot \text{CV})^2 + \sigma^2}$ |
| (none) | $1 / \sqrt{w_i}$ (inverted from weight) |

Every target must have an error model or the fallback weight-to-sigma conversion is used.

**When to use:** When targets are on different scales and you want variance-weighted residuals without full likelihood machinery. Faster than MLE but accounts for heterogeneous uncertainty.

### Maximum Likelihood Estimation (`:mle`)

```julia
obj = objective(targets; simulate, params, bounds, type=:mle)
```

**Definition:**

$$L(\theta) = -2\log\mathcal{L}(\theta) = \sum_{i} -2\log p(y_i \mid f_i(\theta), \text{error}_i)$$

This is the negative twice log-likelihood. Every target must have an `error=` specification. The per-target contributions are:

**Additive:**

$$-2\log p = w_i \left[\frac{(y - f)^2}{\sigma^2} + \log(\sigma^2)\right]$$

**Proportional** (with $\sigma_f = |f| \cdot \text{CV}$):

$$-2\log p = w_i \left[\frac{(y - f)^2}{\sigma_f^2} + \log(\sigma_f^2)\right]$$

Note: because $\sigma_f$ depends on $f(\theta)$, the log-variance term is NOT constant and affects the optimum.

**Log-Normal:**

$$-2\log p = w_i \left[\frac{(\log y - \log f)^2}{\omega^2} + \log(\omega^2) + 2\log(y)\right]$$

The $2\log(y)$ is the Jacobian of the log transform. It is constant w.r.t. $\theta$ but included for correct absolute -2LL values.

**Combined** (with $\sigma_t^2 = (f \cdot \text{CV})^2 + \sigma^2$):

$$-2\log p = w_i \left[\frac{(y - f)^2}{\sigma_t^2} + \log(\sigma_t^2)\right]$$

**When to use:** Proper parameter estimation with statistical grounding. Required if you want to do model comparison (via AIC/BIC) or need principled uncertainty quantification. Recommended when error models are known.

### Maximum A Posteriori (`:map`)

```julia
obj = objective(targets; simulate, params, bounds, type=:map,
    priors = Dict(:k1 => NormalPrior(1.0, 0.5), :k2 => LogNormalPrior(0.0, 0.3))
)
```

**Definition:**

$$L(\theta) = -2\log\mathcal{L}(\theta) + \sum_{j} -2\log\pi(\theta_j)$$

MAP adds a prior penalty to the MLE objective. Every target needs an error model (same as MLE). Priors are optional per-parameter -- parameters without priors have no penalty.

The prior penalty for parameter $\theta_j$ with prior $\pi$ is:

$$-2\log\pi(\theta_j)$$

See [Priors](priors.md) for the specific formulas.

**When to use:**
- **MU chaining**: Use upstream MU posteriors as priors for downstream estimation. This regularizes the fit and prevents drift from well-established baseline values.
- **Regularization**: Soft constraints when bounds alone are too permissive.
- **Small-data regimes**: When you have few targets relative to parameters, priors prevent overfitting.

If you specify `type=:map` with empty priors, TargKit warns that this is equivalent to `:mle`.

## Summary: Choosing an Objective Type

| Scenario | Recommended Type | Why |
|----------|-----------------|-----|
| Quick exploration, no error info | `:ls` | Simplest, fastest, no setup |
| Targets on different scales | `:wls` | Variance weighting normalizes contributions |
| Proper estimation, known errors | `:mle` | Statistically grounded, enables model comparison |
| Chained MU estimation | `:map` | Prior penalties carry upstream information forward |
| Regularized fit, few targets | `:map` | Priors prevent overfitting |

## Validation

`objective()` performs several validations at construction time:

- Bounds dimensions must match `params` length
- For `:mle` and `:map`: every target must have an `error_model`
- For `:wls`: every target must have an error model or at least `sigma`/`cv`/`omega`
- For `:map` with empty priors: a warning is emitted

## Progress Tracking (on_eval)

By default, `objective()` is silent. To print progress every 50 evaluations and whenever a new best loss is found, pass `_default_on_eval` explicitly:

```julia
obj = objective(targets; simulate, params, bounds, on_eval=_default_on_eval)
```

That callback prints lines like:

```
  [eval 1] loss=12.3456 ***
  [eval 50] loss=3.2100
  [eval 51] loss=2.9800 ***
```

The default callback is equivalent to:

```julia
function _default_on_eval(n, loss, params, is_best)
    if is_best || n % 50 == 0
        tag = is_best ? " ***" : ""
        println("  [eval $n] loss=$(round(loss, digits=4))$tag")
        flush(stdout)
    end
end
```

### Custom callback

To customize progress reporting, pass any function with signature `(n::Int, loss::Float64, params::Dict{Symbol,Float64}, is_best::Bool) -> nothing`:

```julia
obj = objective(targets; simulate, params, bounds,
    on_eval = (n, loss, params, is_best) -> begin
        is_best && println("New best at eval $n: $(round(loss, digits=4))")
    end
)
```

The `is_best` flag is tracked automatically by TargKit — no need to maintain your own `Ref(Inf)`.

### Silent evaluation

```julia
obj = objective(targets; simulate, params, bounds, on_eval=nothing)
```

## Soft Bounds Penalty (bounds_penalty)

NelderMead is unconstrained — it can wander outside your parameter bounds. The `bounds_penalty` option adds a soft quadratic wall:

```julia
obj = objective(targets; simulate, params, bounds, bounds_penalty=1e4)
```

When any parameter is out of bounds, TargKit returns `1e6 + coeff * sum(violation^2)` without calling `simulate`. This keeps NelderMead inside the feasible region without needing Fminbox.

PSO and L-BFGS already enforce hard bounds, so `bounds_penalty` is only needed when using NelderMead (`:nm` or the NM polish stage of `:pso_nm`).

## NaN/Inf Handling

If a predict function returns `NaN` or `Inf`, TargKit returns a penalty of `weight * 1e6` for that target instead of propagating the bad value. This prevents a single failed species from crashing the optimization.

## reset!()

```julia
reset!(obj::ObjectiveConfig)
```

Resets the evaluation counter and best-loss tracker to their initial state. Called automatically at the start of `fit()`. Use manually if you're calling the objective directly and want to restart progress tracking.

## Advanced: Manual Objective Evaluation

Since `ObjectiveConfig` is callable, you can use it directly:

```julia
obj = objective(...)

# Evaluate at a specific point (in transform space)
x0 = log.([1.0, 2.0, 3.0])  # if transform=:log
loss = obj(x0)

# Get a full ScoreReport at the current point
using QSPKit.TargKit: _build_fit_report
report = _build_fit_report(obj, x0)
println(report)
```
