# Pipeline API

## Operations

### `with(pairs)`

Stage parameter overrides. Does not solve — just queues changes.

```julia
ctx = sim |> with([:ka => 0.5, :CL => 1.0])

# Multiple with() calls merge:
ctx = sim |> with([:ka => 0.5]) |> with([:CL => 1.0])  # both applied
```

### `events(evs)`

Stage dosing events (InjecKit `IEvent` vectors):

```julia
ctx = sim |> events([ev(time=0.0, cmt=:Depot, amt=100.0)])
```

### `keep()`

Persist params through the next `simulate()`:

```julia
# Default: params cleared after simulate
sim |> with(drug) |> events(evs) |> simulate(weeks(24)) |> simulate(weeks(4))  # washout

# With keep: params persist
sim |> with(drug) |> events(loading) |> keep() |> simulate(weeks(2)) |>
    events(maintenance) |> keep() |> simulate(weeks(50))
```

### `observe(vars...)`

Declare output variables of interest:

```julia
ctx = sim |> observe(:Blood_Eos, :FeNO, :FEV1) |> simulate(400.0)
```

### `simulate(duration; name, absolute, solver, kwargs...)`

Solve for `duration` days. The only function that calls the ODE solver.

**Time modes:**
- Relative (default): `t in [0, duration]`
- Absolute: `t in [t_prev_end, t_prev_end + duration]`

```julia
# Per-phase solver overrides
ctx = sim |>
    simulate(2000.0; name=:baseline, solver=CVODE_BDF(), saveat=[2000.0]) |>
    with(drug) |> events(evs) |>
    simulate(weeks(52); name=:trajectory, solver=AutoTsit5(Rosenbrock23()), reltol=1e-6)
```

## Pipeline Composition

The `>>` operator composes pipeline stages into `Pipeline` objects:

```julia
treatment = with(drug_params) >> events(drug_events) >> simulate(400.0; name=:treatment)

# Inspect
inspect(treatment)

# Apply
result = treatment(baseline)

# Use in branch
arms = branch(baseline, :mepo => treatment, :dupi => other_treatment)
```

Note: `|>` has two behaviors depending on the left-hand side:
- `SimContext |> PipelineStep` — **executes** the step
- `PipelineStep |> PipelineStep` — **composes** into a Pipeline (same as `>>`)

## Population Simulation

### `subjects(pop; parallel=true)`

Stage per-subject parameters and dosing events. Returns a `PopulationResult`.

```julia
pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:BW])
pr = SimContext(prob) |> subjects(pop)
```

### `simulate()` on PopulationResult

```julia
# Infer duration per-subject from max(obs_times) * 1.05
pr = SimContext(prob) |> subjects(pop) |> simulate()

# Explicit duration for all subjects
pr = SimContext(prob) |> subjects(pop) |> simulate(100.0)
```

Both accept `parallel::Bool=true`. Failed subjects are captured in `pr.errors` — the population doesn't stop.

### `to_dataframe()` on PopulationResult

```julia
# Dense output (all solver time points)
sim_df = to_dataframe(pr; carry_out=[:BW])

# Observations only (with DV column)
obs_df = to_dataframe(pr; obsonly=true, carry_out=[:BW])
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
