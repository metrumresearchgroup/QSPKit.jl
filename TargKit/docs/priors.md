# Priors

TargKit provides built-in prior distributions for MAP estimation. Priors are passed to `objective()` via the `priors` keyword argument as a `Dict{Symbol, Prior}` mapping parameter names to prior objects.

## Built-in Prior Types

### NormalPrior

```julia
NormalPrior(mu, sigma)
```

A normal (Gaussian) prior on the parameter value in natural space.

$$\pi(\theta) = \frac{1}{\sigma\sqrt{2\pi}} \exp\left(-\frac{(\theta - \mu)^2}{2\sigma^2}\right)$$

$$\log\pi(\theta) = -\frac{(\theta - \mu)^2}{2\sigma^2} - \log\sigma - \frac{1}{2}\log(2\pi)$$

**MAP penalty** ($-2\log\pi$): proportional to $\frac{(\theta - \mu)^2}{\sigma^2}$ plus constant terms.

**When to use:** Unconstrained parameters that can be negative (e.g., percent changes, log-transformed parameters when you want to specify the prior in log-space yourself).

```julia
priors = Dict(:k1 => NormalPrior(1.0, 0.5))
# Centers k1 around 1.0 with SD 0.5
```

### LogNormalPrior

```julia
LogNormalPrior(mu_log, sigma_log)
```

A log-normal prior: the log of the parameter follows a normal distribution.

$$\pi(\theta) = \frac{1}{\theta \cdot \sigma_\text{log}\sqrt{2\pi}} \exp\left(-\frac{(\log\theta - \mu_\text{log})^2}{2\sigma_\text{log}^2}\right), \quad \theta > 0$$

$$\log\pi(\theta) = -\frac{(\log\theta - \mu_\text{log})^2}{2\sigma_\text{log}^2} - \log(\theta \cdot \sigma_\text{log}) - \frac{1}{2}\log(2\pi)$$

Returns $-\infty$ for $\theta \leq 0$.

**When to use:** Most PK/PD and QSP rate constants, which are strictly positive and often span orders of magnitude. This is the standard choice in NLME modeling.

```julia
# Prior centered at exp(0.5) = 1.65 with ~30% CV in log-space
priors = Dict(:k_rate => LogNormalPrior(0.5, 0.3))
```

**Practical note:** `mu_log` and `sigma_log` are the mean and SD in log-space. To center the prior at a natural-space value $m$ with log-space SD $\omega$:
```julia
LogNormalPrior(log(m), omega)
```

### UniformPrior

```julia
UniformPrior(lb, ub)
```

A flat (non-informative) prior within bounds.

$$\pi(\theta) = \frac{1}{ub - lb}, \quad lb \leq \theta \leq ub$$

Returns $-\infty$ outside the bounds.

**When to use:** Non-informative prior when you want MAP to reduce to MLE within bounds. Also useful as a placeholder when chaining MUs and you have no upstream information for a parameter.

```julia
priors = Dict(:k_new => UniformPrior(0.01, 100.0))
```

## Using Priors with objective()

```julia
obj = objective(targets;
    simulate = my_sim,
    params   = [:k1, :k2, :k3],
    bounds   = (lb = [0.01, 0.01, 0.01], ub = [100.0, 100.0, 100.0]),
    type     = :map,
    priors   = Dict(
        :k1 => LogNormalPrior(log(1.0), 0.3),
        :k2 => LogNormalPrior(log(5.0), 0.5),
        # k3 has no prior -- no penalty added
    ),
)
```

Only parameters listed in `priors` receive a penalty. Parameters without priors are effectively unconstrained (within bounds).

## Duck Typing: Custom Priors

TargKit's prior system uses duck typing. Any object that implements `logpdf(prior, x)` works as a prior:

```julia
# Using Distributions.jl
using Distributions
d = Normal(1.0, 0.5)

# Define the logpdf bridge
TargKit.logpdf(d::Distribution, x) = Distributions.logpdf(d, x)

# Use it
priors = Dict(:k1 => d)
```

This means you can use any prior distribution from Distributions.jl or define your own.

## MU Chaining with Priors

The primary use case for MAP in QSP modeling is **MU (modeling unit) chaining**: using the posterior from one estimation step as the prior for the next.

### Workflow

1. **MU1** (baseline): Fit baseline parameters with `:ls` or `:mle` (no priors needed)
2. **MU2** (drug response): Fit drug-specific parameters with `:map`, using MU1 posteriors as priors for shared baseline parameters

This prevents baseline parameters from drifting when fitting drug response data.

### Example

```julia
# MU1 result: fitted baseline parameters
mu1_params = Dict(:k1 => 1.23, :k2 => 4.56)

# Build priors from MU1 posteriors
# Use LogNormalPrior centered at the fitted value with some uncertainty
mu1_priors = Dict(
    :k1 => LogNormalPrior(log(mu1_params[:k1]), 0.2),  # ~20% CV
    :k2 => LogNormalPrior(log(mu1_params[:k2]), 0.2),
)

# MU2: fit drug response with baseline priors
obj_mu2 = objective(drug_targets;
    simulate = my_drug_sim,
    params   = [:k1, :k2, :k_drug1, :k_drug2],  # baseline + drug params
    bounds   = ...,
    type     = :map,
    priors   = mu1_priors,  # only k1, k2 have priors; k_drug1, k_drug2 are free
)

result_mu2 = fit(obj_mu2)
```

### Choosing Prior Widths

The `sigma_log` (or `sigma`) in the prior controls how much the parameter can move from the upstream estimate:

| `sigma_log` | Approximate CV | Interpretation |
|-------------|---------------|----------------|
| 0.1 | ~10% | Tight: strong confidence in upstream estimate |
| 0.2 | ~20% | Moderate: allows some adjustment |
| 0.3 | ~30% | Loose: allows substantial movement |
| 0.5 | ~53% | Very loose: weak prior, mostly data-driven |
| 1.0 | ~100% | Nearly uninformative |

For QSP MU chaining, `sigma_log = 0.2` to `0.3` is typical -- tight enough to prevent drift but loose enough to allow the data to pull if needed.
