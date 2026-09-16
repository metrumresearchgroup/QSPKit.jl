# Example: MLE with Error Models

This example demonstrates maximum likelihood estimation with explicit error models, and compares the results to a simple least-squares fit.

## Why MLE?

Least squares treats all targets equally (modulo weights). MLE accounts for the expected variability of each measurement, giving more influence to precise measurements and less to noisy ones. This is especially important when:

- Targets are on very different scales (cell counts vs. percent changes)
- Some measurements have known assay CVs
- You want statistically defensible parameter estimates

## Problem Setup

We have four biomarker targets with different measurement characteristics:

| Biomarker | Value | Measurement Type | Error Spec |
|-----------|-------|-----------------|------------|
| Blood Eos | 2.5 x10^9/L | Cell count (FACS) | CV = 20% |
| FeNO | 40 ppb | Exhaled gas analyzer | SD = 8 ppb |
| IL-5 | 5.0 pg/mL | ELISA | Log-normal, omega = 0.4 |
| FEV1 | 60% predicted | Spirometry | SD = 5% |

## Step 1: Define Targets with Error Models

```julia
using TargKit

targets = @targetset :baseline begin
    default_predict(ctx, t) = ctx[t.name]

    @target Blood_Eos  2.5  range=(1.5, 4.0)  error=:proportional  cv=0.20 begin
        source = from_literature(ref="Lou 2021", pmid=33456789, table="Table 2")
    end

    @target FeNO  40.0  range=(25.0, 60.0)  error=:additive  sigma=8.0 begin
        source = from_literature(ref="Dweik 2011", doi="10.1164/rccm.9120-11ST")
    end

    @target IL5  5.0  range=(2.0, 10.0)  error=:lognormal  omega=0.4 begin
        source = from_literature(ref="Prefontaine 2009", pmid=19187218)
    end

    @target FEV1  60.0  range=(50.0, 70.0)  error=:additive  sigma=5.0 begin
        source = from_literature(ref="Gadkar 2016", doi="10.1002/psp4.12113")
    end
end
```

## Step 2: Simulation Function

```julia
function simulate_baseline(overrides)
    k_eos    = get(overrides, :k_eos, 1.0)
    k_feno   = get(overrides, :k_feno, 1.0)
    k_il5    = get(overrides, :k_il5, 1.0)
    k_fev1   = get(overrides, :k_fev1, 1.0)

    # Simplified model (your real model would solve ODEs here)
    eos  = 2.5 * k_eos
    feno = 40.0 * k_feno^0.5
    il5  = 5.0 * k_il5^1.2
    fev1 = 60.0 * (1.0 - 0.1 * (k_eos - 1.0))

    return Dict(:Blood_Eos => eos, :FeNO => feno, :IL5 => il5, :FEV1 => fev1)
end
```

## Step 3: Compare LS vs MLE

### Least Squares Fit

```julia
obj_ls = objective(targets;
    simulate = simulate_baseline,
    params   = [:k_eos, :k_feno, :k_il5, :k_fev1],
    bounds   = (lb = [0.1, 0.1, 0.1, 0.1], ub = [10.0, 10.0, 10.0, 10.0]),
    type     = :ls,
)

result_ls = fit(obj_ls; method=:pso_nm, verbose=false)
println("=== Least Squares ===")
println("Loss: $(round(result_ls.loss; digits=6))")
println(result_ls.report)
```

### MLE Fit

```julia
obj_mle = objective(targets;
    simulate = simulate_baseline,
    params   = [:k_eos, :k_feno, :k_il5, :k_fev1],
    bounds   = (lb = [0.1, 0.1, 0.1, 0.1], ub = [10.0, 10.0, 10.0, 10.0]),
    type     = :mle,
)

result_mle = fit(obj_mle; method=:pso_lbfgs, verbose=false)
println("\n=== MLE ===")
println("-2LL: $(round(result_mle.loss; digits=6))")
println(result_mle.report)
```

### Compare Parameters

```julia
println("\n=== Parameter Comparison ===")
println("Parameter     LS         MLE")
println("-" ^ 40)
for p in [:k_eos, :k_feno, :k_il5, :k_fev1]
    ls_val  = round(result_ls.params[p]; digits=4)
    mle_val = round(result_mle.params[p]; digits=4)
    println("$(rpad(string(p), 14)) $(lpad(string(ls_val), 8))   $(lpad(string(mle_val), 8))")
end
```

## What to Expect

The LS and MLE results will differ because:

1. **LS with `:log` loss** treats all targets symmetrically in log-space -- a 20% miss on Blood_Eos and a 20% miss on IL-5 contribute equally.

2. **MLE** weights each target by its error model:
   - Blood_Eos (CV=20%): a 20% deviation is expected, so it contributes little to -2LL
   - FeNO (sigma=8): an 8 ppb deviation is expected
   - IL-5 (omega=0.4): a 0.4 log-unit deviation is expected
   - FEV1 (sigma=5): the optimizer will try harder to match FEV1 precisely

The MLE fit may sacrifice accuracy on noisy targets (Blood_Eos, IL-5) to better match precise targets (FEV1), because that is the statistically optimal trade-off.

## Using L-BFGS for MLE

MLE objectives are smooth (unlike LS with `:range_only`), making them well-suited for gradient-based optimization:

```julia
# From a known good starting point, L-BFGS converges faster
result_polish = fit(obj_mle; method=:lbfgs, x0=result_mle.x, lbfgs_iters=500)
```

## Complete Script

```julia
using TargKit

# Targets with error models
targets = @targetset :baseline begin
    default_predict(ctx, t) = ctx[t.name]

    @target Blood_Eos  2.5  range=(1.5, 4.0)   error=:proportional  cv=0.20 begin
        source = from_literature(ref="Lou 2021", pmid=33456789)
    end
    @target FeNO  40.0  range=(25.0, 60.0)  error=:additive  sigma=8.0 begin
        source = from_literature(ref="Dweik 2011")
    end
    @target IL5  5.0  range=(2.0, 10.0)  error=:lognormal  omega=0.4 begin
        source = from_literature(ref="Prefontaine 2009")
    end
    @target FEV1  60.0  range=(50.0, 70.0)  error=:additive  sigma=5.0 begin
        source = from_literature(ref="Gadkar 2016")
    end
end

# Simulate
function simulate_baseline(overrides)
    k_eos  = get(overrides, :k_eos, 1.0)
    k_feno = get(overrides, :k_feno, 1.0)
    k_il5  = get(overrides, :k_il5, 1.0)
    k_fev1 = get(overrides, :k_fev1, 1.0)
    return Dict(
        :Blood_Eos => 2.5 * k_eos,
        :FeNO      => 40.0 * k_feno^0.5,
        :IL5       => 5.0 * k_il5^1.2,
        :FEV1      => 60.0 * (1 - 0.1*(k_eos - 1)),
    )
end

# LS fit
obj_ls = objective(targets;
    simulate=simulate_baseline,
    params=[:k_eos, :k_feno, :k_il5, :k_fev1],
    bounds=(lb=[0.1,0.1,0.1,0.1], ub=[10.0,10.0,10.0,10.0]),
    type=:ls)
result_ls = fit(obj_ls; verbose=false)

# MLE fit
obj_mle = objective(targets;
    simulate=simulate_baseline,
    params=[:k_eos, :k_feno, :k_il5, :k_fev1],
    bounds=(lb=[0.1,0.1,0.1,0.1], ub=[10.0,10.0,10.0,10.0]),
    type=:mle)
result_mle = fit(obj_mle; method=:pso_lbfgs, verbose=false)

# Compare
println("LS loss:  $(round(result_ls.loss; digits=4))")
println("MLE -2LL: $(round(result_mle.loss; digits=4))")
println("\nLS Report:")
println(result_ls.report)
println("\nMLE Report:")
println(result_mle.report)
```
