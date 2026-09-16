# TargKit Integration

SimKit scan results can be converted directly into condition-keyed simulation
outputs for TargKit:

```julia
simulate_pk(overrides; times=obs_times) =
    result(scan(base_sim, :dose => dose_levels) do ctx, p
        ctx |>
            with(overrides) |>
            events(regimen(p[:dose])) |>
            simulate(t_end; name=:pk, saveat=times)
    end)
```

For curve targets, store each target value as `(t=..., y=...)` and let TargKit
evaluate the returned ODE solutions by convention:

```julia
targets_pk = TargetSet(curve_targets;
    condition = :dose,
    variable = :organ => endpoint_vars,
)

obj = objective(targets_pk;
    simulate = simulate_pk,
    params = param_names,
    bounds = bounds,
)
```

When `sim[condition]` is solution-like, TargKit evaluates series targets as:

```julia
sim[condition](target.value.t; idxs=target.variable)
```

This keeps ODE solution indexing out of model scripts while preserving the
generic `predict=(sim, row) -> ...` escape hatch for nonstandard mappings.

## Naming Convention

Condition values in a `TargetSet` should match the keys returned by SimKit
simulation output:

```julia
# TargetSet has condition = :mepolizumab
drug_response = TargetSet(df; condition = :treatment => Dict("Anti-IL5" => :mepolizumab))

# SimKit branch uses the same name
arms = branch(baseline, :mepolizumab => with(mepo_params) >> events(mepo_events) >> simulate(400.0))

# score() auto-connects them
report = score(drug_response; sim=merge(result(base), result(arms)))
```

## Target Filtering

Use TargKit's row filters to split objectives without rebuilding target tables:

```julia
dupi_targets = drug_response |> where(:condition => :dupilumab)
```
