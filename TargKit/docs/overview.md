# TargKit Overview

TargKit is a QSPKit subpackage for declaring, loading, and scoring calibration targets. It is **domain-agnostic** -- it knows nothing about QSP, ODEs, drugs, or baselines. You bring the model and simulation; TargKit handles the targets, scoring, objective functions, and fitting.

## Installation

TargKit is part of the QSPKit monorepo. Add it as a dev dependency:

```julia
using Pkg
Pkg.develop(path="path/to/QSPKit/TargKit")
```

### Dependencies

TargKit depends on:
- `CSV` -- for loading data files in `from_data()` sources
- `SHA` -- for integrity checking of data files
- `Optimization`, `OptimizationOptimJL` -- for the `fit()` convenience wrapper

## Package Structure

```
TargKit/
  src/
    TargKit.jl        # module root, exports
    types.jl          # Observed, Source, Prior, Target, TargetSet, ScoreReport, ObjectiveConfig, FitResult
    constructors.jl   # from_literature, from_data, assumed
    macros.jl         # @targetset, @target
    scoring.jl        # score(), compute_loss(), groups(), pct_change()
    display.jl        # Base.show for Target, TargetSet, ScoreReport
    integrity.jl      # lock_hashes!, verify_hashes
    objective.jl      # objective(), _evaluate_objective, _neg2ll
    fit.jl            # fit(), PSO/NelderMead/L-BFGS methods
  test/
    runtests.jl
  docs/
    ...
```

## Quick Start

A complete calibration in under 30 lines:

```julia
using QSPKit.TargKit

# 1. Define your targets
targets = @targetset :demo begin
    default_predict(ctx, t) = ctx[t.name]

    @target A  2.5  range=(1.5, 4.0)
    @target B  10.0 range=(5.0, 15.0)
    @target C  0.8  range=(0.5, 1.2)
end

# 2. Write a simulate function: params Dict -> context (or nothing on failure)
function my_simulate(overrides)
    a = get(overrides, :k1, 1.0) * 2.5
    b = get(overrides, :k2, 1.0) * 10.0
    c = get(overrides, :k1, 1.0) / get(overrides, :k2, 1.0)
    return Dict(:A => a, :B => b, :C => c)
end

# 3. Build an objective and fit
obj = objective(targets;
    simulate = my_simulate,
    params   = [:k1, :k2],
    bounds   = (lb = [0.1, 0.1], ub = [10.0, 10.0]),
    type     = :ls,
)

result = fit(obj; method=:pso_nm)

# 4. Inspect results
println(result.params)    # Dict(:k1 => ..., :k2 => ...)
println(result.report)    # ScoreReport with OK/MISS table
```

## Key Concepts

| Concept | What it does |
|---------|-------------|
| `@target` | Declares a single calibration target with a value, range, loss type, and optional predict function |
| `@targetset` | Groups targets into a named, iterable collection with an optional `default_predict` |
| `score(ts, ctx)` | Evaluates all targets against a simulation context, returns a `ScoreReport` |
| `objective(...)` | Builds a callable objective function for optimization (LS, WLS, MLE, or MAP) |
| `fit(obj)` | Runs optimization (PSO, NelderMead, L-BFGS, or combinations) and returns a `FitResult` |
| `Source` types | Track provenance: where each target value came from (literature, data file, assumption) |
| `Prior` types | Bayesian priors for MAP estimation and MU chaining |
| `lock_hashes!()` | Data integrity: SHA-256 checksums for data source files |

## Further Reading

- [Targets Guide](targets.md) -- `@targetset`, `@target`, sources, metadata
- [Error Models](error_models.md) -- additive, proportional, log-normal, combined
- [Objective Functions](objective_functions.md) -- LS, WLS, MLE, MAP with full derivations
- [Priors](priors.md) -- Normal, LogNormal, Uniform priors for MAP
- [Scoring](scoring.md) -- `score()`, loss types, weights, grouping
- [Fitting](fitting.md) -- `fit()` methods and options
- [Data Integrity](integrity.md) -- `lock_hashes!()` and lockfile verification
- [Examples](examples/) -- worked examples from basic to advanced
