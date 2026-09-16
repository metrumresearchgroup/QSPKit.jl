# Example: Basic Calibration

This example shows a complete TargKit workflow: define targets, write a simulation function, fit with least squares, and inspect the results.

## Problem Setup

We have a simple two-compartment model with three observable biomarkers. We want to calibrate two rate constants (`k1`, `k2`) to match published clinical values.

## Step 1: Define Targets

```julia
using TargKit

targets = @targetset :biomarkers begin
    # Default predict: look up the target name in the simulation context
    default_predict(ctx, t) = ctx[t.name]

    @target CellCount 2.5 range=(1.5, 4.0) begin
        source = from_literature(
            ref = "Smith et al. 2020",
            pmid = 12345678,
            table = "Table 1",
        )
    end

    @target Cytokine 10.0 range=(5.0, 20.0) begin
        source = from_literature(
            ref = "Smith et al. 2020",
            pmid = 12345678,
            table = "Table 1",
        )
    end

    @target Biomarker 0.8 range=(0.4, 1.5) loss=:log begin
        source = assumed("Estimated from healthy volunteer data", author="J. Doe")
    end
end

# Inspect
println(targets)
# TargetSet(:biomarkers, 3 targets)
#   Target(:CellCount, value=2.5, range=(1.5, 4.0), loss=:log)
#   Target(:Cytokine, value=10.0, range=(5.0, 20.0), loss=:log)
#   Target(:Biomarker, value=0.8, range=(0.4, 1.5), loss=:log)
```

## Step 2: Write the Simulation Function

The simulate function takes a `Dict{Symbol, Float64}` of parameter overrides and returns a context object (here a Dict). Return `nothing` if the simulation fails.

```julia
function my_simulate(overrides::Dict{Symbol, Float64})
    k1 = get(overrides, :k1, 1.0)
    k2 = get(overrides, :k2, 1.0)

    # Your ODE solve or steady-state computation would go here.
    # For this example, we use simple algebraic relationships:
    cell_count = k1 * 2.5
    cytokine = k2 * 10.0
    biomarker = k1 / (k1 + k2)

    return Dict(
        :CellCount => cell_count,
        :Cytokine  => cytokine,
        :Biomarker => biomarker,
    )
end
```

## Step 3: Score Before Fitting

Check the score at the default parameter values to understand the starting point:

```julia
ctx_default = my_simulate(Dict{Symbol, Float64}())
report = score(targets, ctx_default)
println(report)
```

Output:
```
ScoreReport: 3/3 targets met, total loss = 0.0
  Name        Predicted  Target   Range          Loss  Status
  CellCount       2.5     2.5   (1.5, 4.0)       0.0  OK
  Cytokine       10.0    10.0   (5.0, 20.0)      0.0  OK
  Biomarker       0.5     0.8   (0.4, 1.5)    0.2231  OK
```

## Step 4: Build Objective and Fit

```julia
obj = objective(targets;
    simulate = my_simulate,
    params   = [:k1, :k2],
    bounds   = (lb = [0.1, 0.1], ub = [10.0, 10.0]),
    type     = :ls,
    transform = :log,
)

result = fit(obj; method=:pso_nm, n_restarts=3, verbose=true)
```

Output:
```
TargKit.fit: method=:pso_nm, 2 params, 3 targets
  PSO restart 1/3: loss = 0.001234
  PSO restart 2/3: loss = 0.000567
  PSO restart 3/3: loss = 0.002345
  NelderMead polish from PSO best (loss = 0.000567)
  NelderMead: loss = 0.000012, retcode = Success
  Final loss: 0.000012, converged: true
  Targets met: 3/3
```

## Step 5: Inspect Results

```julia
# Fitted parameters
println("Fitted parameters:")
for (k, v) in result.params
    println("  $k = $(round(v; digits=4))")
end

# Loss
println("Final loss: $(result.loss)")

# Convergence
println("Converged: $(result.converged)")

# Full ScoreReport
println("\nDetailed results:")
println(result.report)
```

## Step 6: Warm-Start Refinement (Optional)

If you want further polishing:

```julia
result2 = fit(obj; method=:nm, x0=result.x, nm_iters=1000)
println("Refined loss: $(result2.loss)")
```

## Complete Script

```julia
using TargKit

# --- Targets ---
targets = @targetset :biomarkers begin
    default_predict(ctx, t) = ctx[t.name]

    @target CellCount 2.5 range=(1.5, 4.0) begin
        source = from_literature(ref="Smith 2020", pmid=12345678, table="Table 1")
    end
    @target Cytokine 10.0 range=(5.0, 20.0) begin
        source = from_literature(ref="Smith 2020", pmid=12345678, table="Table 1")
    end
    @target Biomarker 0.8 range=(0.4, 1.5) begin
        source = assumed("Healthy volunteer estimate")
    end
end

# --- Simulate ---
function my_simulate(overrides)
    k1 = get(overrides, :k1, 1.0)
    k2 = get(overrides, :k2, 1.0)
    return Dict(
        :CellCount => k1 * 2.5,
        :Cytokine  => k2 * 10.0,
        :Biomarker => k1 / (k1 + k2),
    )
end

# --- Fit ---
obj = objective(targets;
    simulate = my_simulate,
    params   = [:k1, :k2],
    bounds   = (lb = [0.1, 0.1], ub = [10.0, 10.0]),
    type     = :ls,
)

result = fit(obj; method=:pso_nm)
println(result.report)
```
