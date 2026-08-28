# Getting started

## Define and score targets

```julia
using TargKit

observed = targets(
    gain = (0.75, 0.4, 1.2),
    lag = (1.8, 1.1, 2.6),
)

simulation = Dict(:gain => 0.72, :lag => 1.9)
predict = (ctx, row) -> ctx[row.name]
report = score(observed => predict; ctx=simulation)
```

`report.details` contains each prediction, observed value, loss, and range
result. `report.total_loss` is the sum across targets.

## Build an objective

```julia
obj = objective(
    observed => predict;
    simulate = p -> Dict(
        :gain => 0.75p.scale,
        :lag => 1.8p.scale,
    ),
    params = [:scale],
    bounds = (lb=[0.25], ub=[4.0]),
)

# Objectives use transformed coordinates; :log is the default parameter scale.
loss = obj(log.([1.0]))
```

Simulation exceptions propagate. Returning `nothing` explicitly requests the
configured `failure_penalty` for that evaluation.

An opt-in `bounds_penalty` is the other explicit optimization control that may
return a synthetic penalty. Ordinary scoring stays strict: `NaN`/`Inf`,
nonpositive log values, invalid series elements, missing convention lookup
sources, and bounds missing from a `:range_only` target raise descriptive
errors instead.

## Fit directly or as a pipeline

```julia
result = fit(obj; strategy=:nm, x0=[1.0], verbose=false)

state = setup(
    TargetSet(observed);
    simulate=p -> Dict(:gain => 0.75p.scale, :lag => 1.8p.scale),
    predict=predict,
    params=[:scale],
    bounds=(lb=[0.25], ub=[4.0]),
    x0=[1.0],
    verbose=false,
)
result_from_pipeline = state |> fit(NelderMead(); maxiters=50) |> finish
```

Use `where`, `filter_flags`, and `validate` to select and check `TargetSet`
data. `fingerprint` creates a deterministic short hash for target tables.
