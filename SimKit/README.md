# SimKit.jl

*"Simulate it"* — Composable simulation pipelines for multi-phase ODE models.

## Features

- **Composable pipelines** — `SimContext(prob) |> with |> events |> simulate` reads like a protocol
- **Population simulation** — `subjects(pop) |> simulate() |> to_dataframe` for NONMEM-style data
- **Branching** — fork from a common baseline into multiple intervention arms
- **Transparent caching** — identical inputs served from an LRU cache automatically
- **Parameter sweeps** — `scan()` for Cartesian product exploration
- **Time helpers** — `weeks(4)`, `days(7)`, `hours(12)`

## Quick Start

```julia
using QSPKit.SimKit, DifferentialEquations
using QSPKit.InjecKit: ev

# Build a SimContext from an ODEProblem
sim = SimContext(prob; solver=CVODE_BDF(), reltol=1e-4)

# Single-subject: baseline → treatment → washout
result = sim |>
    with(disease_params) |> simulate(2000.0; name=:baseline) |>
    with(drug_params) |> events(drug_events) |> simulate(weeks(24); name=:treatment) |>
    simulate(weeks(4); name=:washout)

# Branch into multiple arms
arms = branch(baseline,
    :drug_a => with(a_params) >> events(a_events) >> simulate(400.0),
    :drug_b => with(b_params) >> events(b_events) >> simulate(400.0),
    :vehicle => simulate(400.0),
)

# Parameter sweep
results = scan(baseline, :CL => [0.1, 0.5, 1.0, 2.0]) do ctx, params
    ctx |> with(params) |> events(drug_events) |> simulate(weeks(52))
end
df = to_dataframe(results)

# Dose sweep, keyword form: `events` maps each sweep point to its dosing
results = scan(prob, :dose => [10, 50, 100];
    events = p -> ev(cmt=:Depot, amt=p.dose), duration = weeks(4), saveat = 1.0)

# Population simulation from NONMEM data
pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:BW])
obs_df = SimContext(prob) |> subjects(pop) |> simulate() |> to_dataframe(; obsonly=true)
```

## Pipeline Verbs

| Verb | Purpose |
|------|---------|
| `SimContext(prob; solver, kwargs...)` | Create pipeline context from ODEProblem |
| `with(pairs)` | Stage parameter overrides |
| `events(evs)` | Stage dosing events (InjecKit IEvents) |
| `keep()` | Persist params through next simulate |
| `observe(vars...)` | Declare output variables |
| `simulate(duration; name, absolute, solver)` | Solve ODE phase |
| `subjects(pop)` | Stage per-subject parameters and events |
| `simulate()` | Simulate population (infer duration from obs_times) |
| `to_dataframe(; obsonly, carry_out)` | Extract tidy DataFrame |
| `branch(base, arms...)` | Fork into named arms |
| `scan(fn, base, ranges...)` | Parameter sweep |
| `scan(base, ranges...; events, duration)` | Sweep without a pipeline body |

## Population Pipeline

```julia
using CSV, DataFrames

nm = CSV.read("data.csv", DataFrame)
pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:BW, :igg_baseline])

pr = SimContext(prob) |> subjects(pop) |> simulate()

# Dense output for plotting
sim_df = to_dataframe(pr; carry_out=[:BW])

# Observations only with DV column
obs_df = to_dataframe(pr; obsonly=true, carry_out=[:BW])

# Check failures
println("$(length(pr.contexts)) succeeded, $(length(pr.errors)) failed")
```

### Population Constructor

Three construction paths:

```julia
# 1. NONMEM event-level data
pop = Population(df; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:BW, :AGE])

# 2. idata + shared events
pop = Population(idata; id=:ID, parameters=[:WT], events=shared_events)

# 3. Combined (data + idata)
pop = Population(data; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 idata=idata_df, parameters=[:WT])
```

Use `parameters=:auto` to auto-detect non-reserved columns.

## Installation

```julia
using Pkg
Pkg.develop(path="path/to/QSPKit/SimKit")
```

## License

MIT
