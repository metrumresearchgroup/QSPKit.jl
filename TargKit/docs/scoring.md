# Scoring and Reporting

TargKit's scoring system evaluates model predictions against calibration targets and produces structured reports.

## score()

The `score()` function evaluates all targets and returns a `ScoreReport`.

### Scoring a TargetSet

```julia
report = score(ts::TargetSet, ctx)
```

For each target in `ts`:
1. The predict function is resolved: `t.predict` if defined, otherwise `ts.default_predict`
2. The predict function is called as `predict_fn(ctx, t)`
3. The loss is computed based on the target's `loss` type
4. Range membership is checked (if range is defined)

### Scoring a subset of targets

```julia
report = score(targets::Vector{Target}, ctx; default_predict=nothing)
```

Score a plain vector of targets. If a target has no `predict` function, the `default_predict` keyword argument is used as fallback.

### The context object

`ctx` is whatever you pass to `score()`. It flows through to your predict functions unchanged. Common patterns:

```julia
# NamedTuple context
ctx = (sol = ode_solution, drug_sol = drug_solution)
report = score(ts, ctx)

# Dict context
ctx = Dict(:Blood_Eos => 2.5, :FeNO => 40.0)
report = score(ts, ctx)
```

## Loss Types

Each target declares a `loss` type that determines how the prediction-vs-target discrepancy is computed.

### :log (default)

Squared difference in log-space:

$$\ell = w \cdot (\log f - \log y)^2$$

Returns a large penalty ($w \times 10^6$) if either $f \leq 0$ or $y \leq 0$.

**Properties:**
- Symmetric in fold-change: predicting 2x too high and 2x too low give the same loss
- Scale-invariant: works well for targets spanning orders of magnitude
- The default for good reason -- most QSP targets are positive and fold-change matters more than absolute difference

### :squared

Squared difference in natural space:

$$\ell = w \cdot (f - y)^2$$

**Properties:**
- Sensitive to scale: large-valued targets dominate the loss
- Use for targets that can be negative (e.g., percent change)
- Consider adjusting `weight` when mixing with other loss types

### :range_only

Zero loss inside the range, quadratic penalty outside:

$$\ell = \begin{cases} 0 & \text{if } lo \leq f \leq hi \\ w \cdot (lo - f)^2 & \text{if } f < lo \\ w \cdot (f - hi)^2 & \text{if } f > hi \end{cases}$$

Requires a `range` on the target.

**Properties:**
- Does not pull toward the center value -- only penalizes out-of-range predictions
- Useful for soft constraints: "I don't care about the exact value, just keep it in range"

### :series_mse

Mean squared error for vector-valued targets:

$$\ell = w \cdot \frac{1}{n}\sum_{j=1}^{n}(f_j - y_j)^2$$

The target's `value` must be a NamedTuple with a `y` field (a vector). The predicted value must also be a vector of the same length.

**Properties:**
- Used for trajectory/time-series fitting
- Each time point contributes equally to the loss
- The `weight` scales the entire series contribution

### NaN/Inf Handling

If a predict function returns `NaN`, `Inf`, or `-Inf`, `compute_loss` returns `weight * 1e6` instead of propagating the bad value. This prevents a single failed prediction from crashing the loss calculation or producing nonsensical results during optimization.

## Weights

Every target has a `weight` (default `1.0`) that multiplies its loss contribution:

```julia
@target Blood_Eos  2.5  weight=2.0   # counts double
@target FeNO       40.0 weight=0.5   # counts half
```

Weights are applied multiplicatively to the loss, regardless of loss type.

**Practical guidance:**
- Weights are relative -- only ratios matter
- Use weights to prioritize clinically important targets
- For `:log` loss, a target already contributes proportional to its log-deviation, so weights are rarely needed for scale normalization

## ScoreReport

`score()` returns a `ScoreReport`:

```julia
struct ScoreReport
    total_loss::Float64          # sum of all target losses
    n_met::Int                   # targets with prediction inside range
    n_total::Int                 # targets that have a range defined
    details::Vector{TargetResult}
end
```

Each `TargetResult` contains:

```julia
struct TargetResult
    target::Target               # the original target
    predicted::Float64           # predicted value from predict_fn(ctx, t)
    loss::Float64                # loss contribution
    in_range::Union{Bool, Nothing}  # nothing if no range, true/false otherwise
end
```

### Pretty-printing

`ScoreReport` has a custom `show` method that prints a table:

```
ScoreReport: 3/3 targets met, total loss = 0.0234
  Name        Predicted  Target   Range          Loss  Status
  Blood_Eos       2.48    2.5   (1.5, 4.0)    0.0001  OK
  FeNO           41.2    40.0   (25.0, 60.0)  0.0009  OK
  FEV1           59.3    60.0   (50.0, 70.0)  0.0001  OK
```

Status is:
- `OK` -- predicted value is within range
- `MISS` -- predicted value is outside range
- `-` -- no range defined

### Accessing details

```julia
report = score(ts, ctx)

# Summary
report.total_loss    # total loss across all targets
report.n_met         # how many targets are in range
report.n_total       # how many targets have a range

# Individual results
for d in report.details
    println("$(d.target.name): predicted=$(d.predicted), loss=$(d.loss), in_range=$(d.in_range)")
end
```

## Grouping

If a `TargetSet` has `group_by=:field`, you can iterate over groups:

```julia
ts = @targetset :drug group_by=:drug begin
    @target a 1.0 drug=:mepo
    @target b 2.0 drug=:mepo
    @target c 3.0 drug=:dupi
end

for (drug, targets) in groups(ts)
    # Score each group separately
    report = score(targets, ctx; default_predict=my_predict)
    println("$drug: loss=$(report.total_loss)")
end
```

`groups()` returns pairs of `(key, Vector{Target})`, grouped by the metadata field.

## Helper: pct_change

```julia
pct_change(new, old)  # = 100.0 * (new - old) / old
```

Commonly used in drug response predict functions:

```julia
default_predict(ctx, t) = pct_change(
    ctx.drug_sol[t.metadata[:species]][end],
    ctx.base_sol[t.metadata[:species]][end]
)
```
