# SimKit.jl

*"Simulate it"* — Composable simulation pipelines for multi-phase ODE models.

## What is SimKit?

SimKit provides a pipeline API that chains parameter updates, dosing events, and ODE solves into readable, composable simulation workflows. It eliminates the manual `remake() → update() → solve()` boilerplate that every QSP project reimplements.

## The Kit Family

| Package | Tagline | Purpose |
|---------|---------|---------|
| **ConfigKit** | "Config it" | Parameter management, YAML keyfiles, fast updates |
| **InjecKit** | "Inject it" | Dosing events, event composition |
| **SimKit** | "Simulate it" | Simulation orchestration, pipelines, caching |
| **TargKit** | "Track it" | Calibration targets and optimization |
| **TracKit** | "Track it" | Experiment caching and provenance |

SimKit is domain-agnostic — it works with any ModelingToolkit ODE model, not just pharmacology.

## Quick Example

```julia
using QSPKit.SimKit
using DifferentialEquations

sim = SimContext(prob; solver=CVODE_BDF(), reltol=1e-4)

# Baseline → treatment → washout
result = sim |>
    with(disease_params) |> simulate(2000.0; name=:baseline) |>
    with(drug_params) |> events(drug_events) |> simulate(weeks(24); name=:treatment) |>
    simulate(weeks(4); name=:washout)

# Fork into multiple drug arms
arms = branch(baseline,
    :drug_a => with(a_params) >> events(a_events) >> simulate(400.0),
    :drug_b => with(b_params) >> events(b_events) >> simulate(400.0),
)

# Population simulation from NONMEM data
pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:BW])
obs_df = SimContext(prob) |> subjects(pop) |> simulate() |> to_dataframe(; obsonly=true)
```

## Key Features

- **Composable pipelines** — `SimContext |> with |> events |> simulate` chains read like a protocol
- **Population simulation** — `subjects(pop) |> simulate() |> to_dataframe` for NONMEM-style data
- **Branching** — fork from a common baseline into multiple intervention arms
- **Transparent caching** — identical inputs are served from an LRU cache automatically
- **First-class Pipeline objects** — inspectable, not opaque closures
- **Time flexibility** — relative (each phase t=0) or absolute (cumulative)
- **Parameter sweeps** — `scan()` for Cartesian product exploration
- **Error context** — `SimulationError` tells you which phase failed and why
- **TargKit integration** — `to_simulate()` wraps pipelines for optimization
