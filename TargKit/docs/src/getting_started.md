# Getting started

## Define and score targets

```julia
using QSPKit.TargKit

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

## Match targets to simulation output

A `TargetSet` built with `match` and `at` is compared with the simulation output
the way a join matches rows:

- `match` names the target column(s) that pick a simulation: dose, donor, arm.
- `at` picks the point within it along one ordered axis: `:TIME` (a target
  column), `:TIME_hr => :TIME` (a target column matched to a differently named
  axis), or `:TIME => 672.0` (every target at one point). The axis does not have
  to be time; `at = :dose` reads a dose-response table.
- The observed column's name is the simulated variable it is compared with.
  `value = :obs => :simvar` names it explicitly, and a `variable` column gives
  one per row.

```julia
exposure = TargetSet(target_df; match = :dose, value = :Conc, at = :TIME => 24.0)

sim(p) = scan(SimContext(prob) |> with(p), :dose => unique(target_df.dose);
              events = q -> ev(time = 0.0, cmt = :Depot, amt = q.dose),
              duration = 24.0)

result = fit(exposure; simulate = sim, params = [:CL, :V], keyfile = kf)
```

`simulate` may return a DataFrame (or any table), an ODE solution, a SimKit scan
result or `SimContext`, or a Dict keyed by one match value. Each target row must
match exactly one simulation point. Anything else raises a `TargKit.MatchError`
that names the target and lists what the output contains; `setup` evaluates the
objective once, so this happens before optimization starts.

There is no interpolation between saved points. Save the simulation at the
target points, or leave out `saveat` so solutions are evaluated with the
solver's dense output. A target at a dose time is ambiguous (the solution holds
the values before and after the dose) and is an error.

A TargetSet needs a mapping to the simulation output: `match`/`at`, or a
`predict = (sim, row) -> value` function. Without one, `score`, `objective`,
and `fit` raise an error; there is no implicit lookup by condition or target
name.

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
nonpositive log values, invalid series elements, and bounds missing from a
`:range_only` target raise descriptive errors instead.

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
