# Example: MAP with MU Chaining

This example demonstrates the **MU (Modeling Unit) chaining** workflow: fitting baseline parameters first, then using those posteriors as priors when fitting drug response parameters.

## Why MU Chaining?

In QSP modeling, calibration is typically done in stages:

1. **MU1 (Baseline)**: Fit rate constants to match healthy/diseased steady-state biomarkers
2. **MU2 (Drug Response)**: Fit drug-specific parameters to match clinical treatment effects
3. **MU3 (Trajectories)**: Fit time-course dynamics to match longitudinal data

Each stage introduces new parameters while carrying forward parameters from earlier stages. Without priors, the drug-response fit might drift baseline parameters to compensate for poorly constrained drug parameters. MAP estimation with priors from the upstream MU prevents this drift.

## Problem Setup

We have:
- 3 baseline biomarkers (Blood_Eos, FeNO, FEV1)
- 2 baseline parameters to fit (k_eos, k_feno)
- 1 drug with 2 response targets (delta_Eos, delta_FEV1)
- 2 drug parameters to fit (k_drug_eos, k_drug_fev1)

## Step 1: MU1 -- Baseline Fit (LS, no priors)

```julia
using TargKit

# --- Baseline targets ---
baseline = @targetset :baseline begin
    default_predict(ctx, t) = ctx[:baseline][t.name]

    @target Blood_Eos  2.5  range=(1.5, 4.0) error=:lognormal omega=0.3 begin
        source = from_literature(ref="Lou 2021", pmid=33456789)
    end
    @target FeNO  40.0  range=(25.0, 60.0) error=:lognormal omega=0.3 begin
        source = from_literature(ref="Dweik 2011")
    end
    @target FEV1  60.0  range=(50.0, 70.0) error=:additive sigma=5.0 begin
        source = from_literature(ref="Gadkar 2016")
    end
end

# --- Simulate baseline ---
function simulate_mu1(overrides)
    k_eos  = get(overrides, :k_eos, 1.0)
    k_feno = get(overrides, :k_feno, 1.0)
    return Dict(:baseline => Dict(
        :Blood_Eos => 2.5 * k_eos,
        :FeNO      => 40.0 * k_feno^0.5,
        :FEV1      => 60.0 * (1 - 0.05 * (k_eos - 1)),
    ))
end

# --- MU1: Fit baseline with LS (no priors) ---
obj_mu1 = objective(baseline;
    simulate = simulate_mu1,
    params   = [:k_eos, :k_feno],
    bounds   = (lb = [0.1, 0.1], ub = [10.0, 10.0]),
    type     = :ls,
)

result_mu1 = fit(obj_mu1; method=:pso_nm, verbose=true)

println("\n=== MU1 Results ===")
println(result_mu1.report)
for (k, v) in result_mu1.params
    println("  $k = $(round(v; digits=4))")
end
```

## Step 2: Build Priors from MU1

Convert MU1 fitted values into priors for MU2. Use `LogNormalPrior` for positive rate constants:

```julia
# Build priors from MU1 posteriors
# sigma_log = 0.2 means ~20% CV -- allows some movement but prevents drift
mu1_priors = Dict{Symbol, Prior}(
    :k_eos  => LogNormalPrior(log(result_mu1.params[:k_eos]),  0.2),
    :k_feno => LogNormalPrior(log(result_mu1.params[:k_feno]), 0.2),
)

println("\n=== MU1 Priors for MU2 ===")
for (k, p) in mu1_priors
    center = round(exp(p.mu_log); digits=4)
    println("  $k: LogNormal centered at $center, sigma_log=$(p.sigma_log)")
end
```

## Step 3: MU2 -- Drug Response Fit (MAP with priors)

```julia
# --- Drug response targets ---
drug_response = @targetset :drug_response begin
    @target delta_Eos  -67.0  range=(-80.0, -50.0) error=:additive sigma=10.0 begin
        source = from_literature(ref="Gadkar 2016", figure="Fig 4")
        predict(ctx, t) = pct_change(ctx[:drug][:Blood_Eos], ctx[:baseline][:Blood_Eos])
    end

    @target delta_FEV1  9.5  range=(5.0, 14.0) error=:additive sigma=3.0 begin
        source = from_literature(ref="Gadkar 2016", figure="Fig 4")
        predict(ctx, t) = ctx[:drug][:FEV1] - ctx[:baseline][:FEV1]
    end
end

# --- Simulate baseline + drug ---
function simulate_mu2(overrides)
    k_eos      = get(overrides, :k_eos, 1.0)
    k_feno     = get(overrides, :k_feno, 1.0)
    k_drug_eos = get(overrides, :k_drug_eos, 0.5)
    k_drug_fev = get(overrides, :k_drug_fev, 0.1)

    base_eos  = 2.5 * k_eos
    base_feno = 40.0 * k_feno^0.5
    base_fev1 = 60.0 * (1 - 0.05 * (k_eos - 1))

    drug_eos  = base_eos * (1 - k_drug_eos)
    drug_fev1 = base_fev1 + k_drug_fev * 100

    return Dict(
        :baseline => Dict(:Blood_Eos => base_eos, :FeNO => base_feno, :FEV1 => base_fev1),
        :drug     => Dict(:Blood_Eos => drug_eos, :FEV1 => drug_fev1),
    )
end

# --- MU2: Fit with MAP (baseline priors + drug targets) ---
obj_mu2 = objective([baseline, drug_response];
    simulate = simulate_mu2,
    params   = [:k_eos, :k_feno, :k_drug_eos, :k_drug_fev],
    bounds   = (lb = [0.1, 0.1, 0.01, 0.01], ub = [10.0, 10.0, 1.0, 1.0]),
    type     = :map,
    priors   = mu1_priors,  # only k_eos, k_feno have priors
)

result_mu2 = fit(obj_mu2; method=:pso_lbfgs, verbose=true)

println("\n=== MU2 Results (MAP) ===")
println(result_mu2.report)
```

## Step 4: Compare with and without Priors

To see the effect of priors, also fit MU2 without them:

```julia
# MU2 without priors (MLE) -- baseline params may drift
obj_mu2_mle = objective([baseline, drug_response];
    simulate = simulate_mu2,
    params   = [:k_eos, :k_feno, :k_drug_eos, :k_drug_fev],
    bounds   = (lb = [0.1, 0.1, 0.01, 0.01], ub = [10.0, 10.0, 1.0, 1.0]),
    type     = :mle,
)

result_mu2_mle = fit(obj_mu2_mle; method=:pso_lbfgs, verbose=false)

# Compare baseline parameter movement
println("\n=== Baseline Parameter Movement ===")
println("Parameter     MU1        MAP        MLE (no prior)")
println("-" ^ 55)
for p in [:k_eos, :k_feno]
    mu1_val = round(result_mu1.params[p]; digits=4)
    map_val = round(result_mu2.params[p]; digits=4)
    mle_val = round(result_mu2_mle.params[p]; digits=4)
    pct_map = round(100 * (result_mu2.params[p] - result_mu1.params[p]) / result_mu1.params[p]; digits=1)
    pct_mle = round(100 * (result_mu2_mle.params[p] - result_mu1.params[p]) / result_mu1.params[p]; digits=1)
    println("$(rpad(string(p), 14)) $(lpad(string(mu1_val), 8))   $(lpad(string(map_val), 8)) ($(pct_map)%)   $(lpad(string(mle_val), 8)) ($(pct_mle)%)")
end
```

## What to Expect

- **MAP (with priors)**: Baseline parameters stay close to MU1 values (within ~20%, controlled by `sigma_log`). Drug parameters absorb the drug-specific signal.
- **MLE (no priors)**: Baseline parameters may shift substantially to jointly optimize baseline + drug targets. This "drift" can produce parameter values that no longer make biological sense for the baseline.

The prior width (`sigma_log`) controls the trade-off:
- Tight (0.1): baseline params barely move -- good when MU1 was well-determined
- Moderate (0.2): allows some adjustment -- recommended default
- Loose (0.5): weak constraint -- use when MU1 had limited data

## Extending to MU3

The same pattern extends to trajectory fitting:

```julia
# Build priors from MU2 posteriors
mu2_priors = Dict{Symbol, Prior}()
for (k, v) in result_mu2.params
    mu2_priors[k] = LogNormalPrior(log(v), 0.2)
end

# MU3: fit trajectory params with MAP, carrying forward all upstream priors
obj_mu3 = objective([baseline, drug_response, trajectory];
    simulate = simulate_mu3,
    params   = [:k_eos, :k_feno, :k_drug_eos, :k_drug_fev, :k_traj1, :k_traj2],
    bounds   = ...,
    type     = :map,
    priors   = mu2_priors,  # all MU2 params have priors; new traj params are free
)
```

Each MU layer adds new parameters (which are unconstrained) while carrying forward priors from all upstream MUs. This creates a principled chain where information flows forward through the calibration stages.
