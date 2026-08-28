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

SimKit is domain-agnostic — it works with any ModelingToolkit ODE model, not just pharmacology.

## Quick Example

```julia
using SimKit

sim = SimContext(prob; reltol=1e-4)

# Settle → perturb → reset
result = sim |>
    with(reference_params) |> simulate(12.0; name=:settle) |>
    with(pulse_params) |> events(short_pulses) |> simulate(6.0; name=:perturb) |>
    simulate(2.5; name=:reset)

# Fork into multiple synthetic input modes
arms = branch(baseline,
    :pulse => with(pulse_params) >> events(short_pulses) >> simulate(18.0),
    :step => with(step_params) >> events(step_events) >> simulate(18.0),
)

# Population simulation from NONMEM data
pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:input_scale])
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
