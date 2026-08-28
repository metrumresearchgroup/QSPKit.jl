# Branching & Sweeps

## Branching

### Named arms

```julia
arms = branch(baseline,
    :low_gain => with(low_gain_params) >> events(short_pulses) >> simulate(18.0),
    :high_gain => with(high_gain_params) >> events(sparse_pulses) >> simulate(18.0),
    :reference => simulate(18.0),
)
```

All arms start from the same baseline state. Mutual exclusion is structural — no need to zero out other interventions.

### From DataFrame

```julia
conditions = DataFrame(
    arm = [:low_gain, :mid_gain, :high_gain],
    response_gain = [0.35, 0.70, 1.10],
    decay_rate = [0.04, 0.09, 0.16],
)
arms = branch(baseline, conditions; name=:arm, params=[:response_gain, :decay_rate])
```

### Lazy branching

Arms solved only when accessed:

```julia
lazy = branch_lazy(baseline, :low_gain => pipeline1, :high_gain => pipeline2)
lazy[:low_gain]  # runs now, result cached
```

## Result Extraction

```julia
# All phases from a context
sols = result(ctx)

# All arms from a branch
sols = result(arms)

# Specific phase
sol = result(ctx, :perturb)
sol = result(ctx, :perturb, 1)  # first occurrence
```

## Parameter Sweeps

```julia
results = scan(baseline,
               :input_level => [0.2, 0.7, 1.4],
               :decay_rate => [0.05, 0.15]) do ctx, params
    ctx |> with(params) |> events(evs) |> simulate(18.0)
end
```

Returns `Vector{(params=Dict, result=SimContext)}`.
