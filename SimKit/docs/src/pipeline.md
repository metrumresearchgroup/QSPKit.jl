# Pipeline API

## Operations

### `with(pairs)`

Stage parameter overrides. Does not solve — just queues changes.

```julia
ctx = sim |> with([:response_gain => 0.7, :decay_rate => 0.09])

# Multiple with() calls merge:
ctx = sim |> with([:response_gain => 0.7]) |>
    with([:decay_rate => 0.09])  # both applied
```

### `events(evs)`

Stage dosing events (InjecKit `IEvent` vectors):

```julia
ctx = sim |> events([ev(time=0.0, cmt=:Input, amt=0.8)])
```

### `keep()`

Persist params through the next `simulate()`:

```julia
# Default: params cleared after simulate
sim |> with(pulse_params) |> events(short_pulses) |> simulate(6.0) |>
    simulate(2.5)  # reset with reference parameters

# With keep: params persist
sim |> with(input_params) |> events(initial_event) |> keep() |> simulate(1.5) |>
    events(repeating_events) |> keep() |> simulate(7.5)
```

### `simulate(duration; name, absolute, solver, kwargs...)`

Solve for `duration` days. The only function that calls the ODE solver.

**Time modes:**
- Relative (default): `t in [0, duration]`
- Absolute: `t in [t_prev_end, t_prev_end + duration]`

```julia
# Per-phase solve keyword overrides
ctx = sim |>
    simulate(12.0; name=:settle, saveat=[12.0]) |>
    with(input_params) |> events(probe_events) |>
    simulate(9.0; name=:trajectory, reltol=1e-6)
```

## Pipeline Composition

The `>>` operator composes pipeline stages into `Pipeline` objects:

```julia
probe = with(input_params) >> events(probe_events) >> simulate(18.0; name=:probe)

# Inspect
inspect(probe)

# Apply
result = probe(baseline)

# Use in branch
arms = branch(baseline, :pulse => probe, :step => other_probe)
```

Note: `|>` has two behaviors depending on the left-hand side:
- `SimContext |> PipelineStep` — **executes** the step
- `PipelineStep |> PipelineStep` — **composes** into a Pipeline (same as `>>`)

## Population Simulation

### `subjects(pop; parallel=true)`

Stage per-subject parameters and dosing events. Returns a `PopulationResult`.

```julia
pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:input_scale])
pr = SimContext(prob) |> subjects(pop)
```

### `simulate()` on PopulationResult

```julia
# Infer duration per-subject from max(obs_times) * 1.05
pr = SimContext(prob) |> subjects(pop) |> simulate()

# Explicit duration for all subjects
pr = SimContext(prob) |> subjects(pop) |> simulate(18.0)
```

Both accept `parallel::Bool=true`. Failed subjects are captured in `pr.errors` — the population doesn't stop.

### `to_dataframe()` on PopulationResult

```julia
# Dense output (all solver time points)
sim_df = to_dataframe(pr; carry_out=[:input_scale])

# Observations only (with DV column)
obs_df = to_dataframe(pr; obsonly=true, carry_out=[:input_scale])
```

Keywords:
- `vars=nothing` — variables to include (default: all state variables)
- `obsonly=false` — only output at observation times, include DV column
- `carry_out=Symbol[]` — covariate names to copy into output rows

## Time Helpers

```julia
weeks(n)  # n * 7.0
days(n)   # Float64(n)
hours(n)  # n / 24.0
```
