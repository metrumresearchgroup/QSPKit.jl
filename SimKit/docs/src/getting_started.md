# Getting Started

## Installation

SimKit is part of the QSPKit monorepo. Add it via:

```julia
using Pkg
Pkg.develop(path="path/to/QSPKit/SimKit")
```

## Basic Usage

### 1. Create a SimContext

Every pipeline starts from a `SimContext` wrapping an existing ODEProblem:

```julia
using SimKit

sim = SimContext(prob; reltol=1e-6, maxiters=50000)
```

### 2. Stage parameters and events

```julia
# Stage parameter overrides
ctx = sim |> with([:response_gain => 0.7, :decay_rate => 0.09])

# Stage dosing events
using InjecKit: ev
ctx = ctx |> events([ev(time=0.0, cmt=:Input, amt=0.8)])
```

### 3. Solve a phase

```julia
probe_ctx = ctx |> simulate(18.0; name=:probe)
```

### 4. Chain phases

```julia
result_ctx = sim |>
    with(reference_params) |> simulate(12.0; name=:settle) |>
    with(pulse_params) |> events(short_pulses) |> simulate(6.0; name=:perturb) |>
    simulate(2.5; name=:reset)

# Access solutions
sol = SimKit.result(result_ctx, :perturb)
```

### 5. Fork into arms

```julia
baseline = sim |> with(reference_params) |> simulate(12.0; name=:settle)

arms = branch(baseline,
    :pulse => with(pulse_params) >> events(short_pulses) >> simulate(18.0),
    :step => with(step_params) >> events(step_events) >> simulate(18.0),
    :reference => simulate(18.0),
)

sols = result(arms)  # Dict{Symbol, ODESolution}
```

### 6. Population simulation

Simulate a population of subjects from NONMEM-style data:

```julia
using CSV, DataFrames

# Load data and build population
nm = CSV.read("synthetic_population.csv", DataFrame)
pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:input_scale])

# Simulate all subjects — duration inferred from obs_times
pr = SimContext(prob) |> subjects(pop) |> simulate()

# Extract results as DataFrames
sim_df = to_dataframe(pr)                                    # dense output
obs_df = to_dataframe(pr; obsonly=true, carry_out=[:input_scale]) # at observation times only
```
