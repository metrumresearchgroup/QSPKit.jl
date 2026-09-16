# Error Models

Error models describe the statistical relationship between model predictions $f(\theta)$ and observed data $y$. TargKit supports four error models, specified per-target with the `error=` keyword.

Error models are used by:
- **WLS** (`:wls`) -- to compute per-target variance weights
- **MLE** (`:mle`) and **MAP** (`:map`) -- to compute the log-likelihood

For simple least-squares (`:ls`), error models are not required.

## Additive Normal

**Specification:** `error=:additive sigma=X`

**Statistical model:**

$$y = f(\theta) + \varepsilon, \quad \varepsilon \sim N(0, \sigma^2)$$

The observation error has constant variance regardless of the predicted value. The standard deviation $\sigma$ is specified directly.

**Likelihood:**

$$p(y \mid f, \sigma) = \frac{1}{\sigma\sqrt{2\pi}} \exp\left(-\frac{(y - f)^2}{2\sigma^2}\right)$$

**-2 log-likelihood contribution:**

$$-2\log p = \frac{(y - f)^2}{\sigma^2} + \log(\sigma^2) + \log(2\pi)$$

TargKit drops the constant $\log(2\pi)$ since it does not affect optimization.

**When to use:**
- Biomarkers measured on an absolute scale (e.g., FEV1 in percent predicted, absolute cell counts after transformation)
- When measurement error is roughly the same size regardless of the value being measured
- When you have a published standard deviation for the assay

**Example:**
```julia
@target FEV1 60.0 range=(50.0, 70.0) error=:additive sigma=5.0
```

## Proportional Normal

**Specification:** `error=:proportional cv=X`

**Statistical model:**

$$y = f(\theta) \cdot (1 + \varepsilon), \quad \varepsilon \sim N(0, \text{CV}^2)$$

Equivalently, the standard deviation scales with the predicted value:

$$y \sim N(f, (f \cdot \text{CV})^2)$$

**Likelihood (with $\sigma_f = |f| \cdot \text{CV}$):**

$$p(y \mid f, \text{CV}) = \frac{1}{\sigma_f\sqrt{2\pi}} \exp\left(-\frac{(y - f)^2}{2\sigma_f^2}\right)$$

**-2 log-likelihood contribution:**

$$-2\log p = \frac{(y - f)^2}{\sigma_f^2} + \log(\sigma_f^2)$$

Note: $\sigma_f = |f| \cdot \text{CV}$ depends on the current prediction, so the log-variance term matters for optimization (it is not constant).

**When to use:**
- PK concentrations (where assay CV is typically 15-25%)
- Cell counts and cytokine concentrations in BAL/blood
- Any biomarker where measurement error is proportional to the signal

**Example:**
```julia
@target Blood_Eos 2.5 range=(1.5, 4.0) error=:proportional cv=0.25
```

## Log-Normal

**Specification:** `error=:lognormal omega=X`

**Statistical model:**

$$\log(y) = \log(f(\theta)) + \varepsilon, \quad \varepsilon \sim N(0, \omega^2)$$

Equivalently, $y/f$ follows a log-normal distribution. This is the standard NLME error model for positive-valued biomarkers with right-skewed distributions.

**Likelihood:**

$$p(y \mid f, \omega) = \frac{1}{y \cdot \omega\sqrt{2\pi}} \exp\left(-\frac{(\log y - \log f)^2}{2\omega^2}\right)$$

**-2 log-likelihood contribution:**

$$-2\log p = \frac{(\log y - \log f)^2}{\omega^2} + \log(\omega^2) + 2\log(y)$$

The $2\log(y)$ term is the Jacobian from the log transformation. It is constant with respect to $\theta$ but is included for correct absolute likelihood values (important for model comparison).

**When to use:**
- Positive-valued biomarkers (concentrations, cell counts, cytokine levels)
- When the ratio of observed-to-predicted is more meaningful than the difference
- When data spans multiple orders of magnitude
- Standard choice in NLME/PopPK modeling

**Example:**
```julia
@target IL5 5.0 range=(2.0, 10.0) error=:lognormal omega=0.3
```

**Practical note:** $\omega = 0.3$ corresponds to roughly 30% CV on the original scale (the approximation $\text{CV} \approx \omega$ is accurate for small $\omega$). For $\omega = 0.5$, the CV is about 53%.

## Combined (Additive + Proportional)

**Specification:** `error=:combined sigma=X cv=Y`

**Statistical model:**

$$y = f(\theta) + \varepsilon, \quad \varepsilon \sim N(0, \sigma_\text{total}^2)$$

where:

$$\sigma_\text{total}^2 = (f \cdot \text{CV})^2 + \sigma^2$$

This combines a proportional component (dominant at high concentrations) with an additive floor (dominant near the limit of quantification).

**-2 log-likelihood contribution:**

$$-2\log p = \frac{(y - f)^2}{\sigma_\text{total}^2} + \log(\sigma_\text{total}^2)$$

**When to use:**
- PK data with a non-negligible LLOQ
- Bioassays that have both a proportional error at high concentrations and a constant noise floor
- When proportional-only would give unrealistically small variance near zero

**Example:**
```julia
@target drug_conc 100.0 error=:combined sigma=1.0 cv=0.15
```

## Summary Table

| Error Model | Keyword | Required Params | Variance | Best For |
|------------|---------|----------------|----------|----------|
| Additive | `error=:additive` | `sigma` | $\sigma^2$ (constant) | Absolute-scale biomarkers |
| Proportional | `error=:proportional` | `cv` | $(f \cdot \text{CV})^2$ | Cell counts, cytokines |
| Log-Normal | `error=:lognormal` | `omega` | Defined in log-space | Positive, skewed data |
| Combined | `error=:combined` | `sigma`, `cv` | $(f \cdot \text{CV})^2 + \sigma^2$ | PK with LLOQ |

## Choosing an Error Model for QSP Calibration

**Quick guidance:**

1. **You have few targets and just want something reasonable:** Use `:lognormal` with `omega=0.3` for positive biomarkers. This gives symmetric errors in log-space and naturally handles fold-change targets.

2. **You have published assay CVs:** Use `:proportional` with `cv=` set to the assay CV (e.g., 0.15 for a 15% CV ELISA).

3. **You have percent-change targets (e.g., drug response):** Use `:additive` with `sigma` set to the clinical standard deviation. Percent changes can be negative, so log-normal is not appropriate.

4. **You want proper NLME-style estimation:** Use `:lognormal` for PK/PD data, `:combined` when you have data near the LLOQ.

5. **You're doing LS calibration and don't care about error models:** Just skip the `error=` keyword entirely. LS uses the `loss=` type directly.
