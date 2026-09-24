# TargKit Integration

TargKit matches targets against SimKit results directly. A scan result is
labelled by its scanned values, and a `SimContext` contributes its last phase's
solution (the same phase `to_dataframe` reports):

```julia
simulate_pk(overrides) =
    scan(SimContext(prob) |> with(overrides), :dose => dose_levels;
         events = p -> regimen(p.dose), duration = t_end)

targets_pk = TargetSet(obs_df;      # columns: dose, TIME, Conc
    match = :dose,                  # picks the scan result
    value = :Conc,                  # observed column = simulated variable
    at    = :TIME,                  # evaluates that result's solution at TIME
)

result = fit(targets_pk; simulate = simulate_pk, params = param_names, bounds = bounds)
```

The same targets also match `to_dataframe(scan(...))`, `result(scan(...))`, or a
single `SimContext`. Each target must match exactly one simulation point: a
dose missing from the scan, a scanned parameter the targets do not match on, or
a target at a dose time raises a `TargKit.MatchError` explaining which.

Solutions saved with `saveat` have no dense output, so their targets must sit
at saved times; leave out `saveat` to evaluate targets anywhere in the solved
span.

## Target Filtering

Use TargKit's row filters to split objectives without rebuilding target tables:

```julia
low_dose_targets = targets_pk |> where(:dose => 10.0)
```
