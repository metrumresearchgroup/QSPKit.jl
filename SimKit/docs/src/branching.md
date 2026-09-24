# Branching & Sweeps

## Branching

### Named arms

```julia
arms = branch(baseline,
    :mepo  => with(mepo_params) >> events(mepo_events) >> simulate(400.0),
    :dupi  => with(dupi_params) >> events(dupi_events) >> simulate(400.0),
    :vehicle => simulate(400.0),
)
```

All arms start from the same baseline state. Mutual exclusion is structural — no need to zero out other interventions.

### From DataFrame

```julia
conditions = DataFrame(
    arm  = [:mepo, :dupi, :teze],
    Emax = [0.99, 0.99, 0.99],
    KA   = [0.2, 0.306, 0.339],
)
arms = branch(baseline, conditions; name=:arm, params=[:Emax, :KA])
```

### Lazy branching

Arms solved only when accessed:

```julia
lazy = branch_lazy(baseline, :mepo => pipeline1, :dupi => pipeline2)
lazy[:mepo]  # runs now, result cached
```

## Result Extraction

```julia
# All phases from a context
sols = result(ctx)

# All arms from a branch
sols = result(arms)

# Specific phase
sol = result(ctx, :treatment)
sol = result(ctx, :treatment, 1)  # first occurrence
```

## Parameter Sweeps

```julia
results = scan(baseline, :dose => [10, 50, 100], :CL => [0.1, 0.5]) do ctx, params
    ctx |> with(params) |> events(evs) |> simulate(400.0)
end
```

Returns `Vector{(params=Dict, result=SimContext)}`.

### Keyword form

When each sweep point is just "stage parameters, add events, simulate", skip the
do-block. Swept names the model knows (parameters, or states as initial
conditions) go through `with`; everything else is passed only to `events`, a
function of the sweep point:

```julia
results = scan(prob, :dose => [10, 50, 100], :CL => [0.1, 0.5];
    events = p -> ev(cmt=:Depot, amt=p.dose),
    duration = 400.0, solver = Rodas5P(), saveat = 1.0)
```

The sweep point is a `NamedTuple` (`p.dose`, `p.CL`). `duration` defaults to the
problem's `tspan`; other keywords go to `simulate`. Without `events`, every swept
name must be a model parameter or state, so a typo fails before anything runs.
