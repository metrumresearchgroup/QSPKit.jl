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
using QSPKit.SimKit
using DifferentialEquations

sim = SimContext(prob; solver=CVODE_BDF(), reltol=1e-4, maxiters=200000)
```

### 2. Stage parameters and events

```julia
# Stage parameter overrides
ctx = sim |> with([:ka => 0.5, :CL => 1.0])

# Stage dosing events
using QSPKit.InjecKit: ev
ctx = ctx |> events([ev(time=0.0, cmt=:Depot, amt=100.0)])
```

### 3. Solve a phase

```julia
result = ctx |> simulate(400.0; name=:treatment)
```

### 4. Chain phases

```julia
result = sim |>
    with(disease_context) |> simulate(2000.0; name=:baseline) |>
    with(drug_params) |> events(drug_events) |> simulate(weeks(24); name=:treatment) |>
    simulate(weeks(4); name=:washout)

# Access solutions
sol = result(result_ctx, :treatment)
```

### 5. Fork into arms

```julia
baseline = sim |> with(disease) |> simulate(2000.0; name=:baseline)

arms = branch(baseline,
    :drug_a => with(a_params) >> events(a_events) >> simulate(400.0),
    :drug_b => with(b_params) >> events(b_events) >> simulate(400.0),
    :vehicle => simulate(400.0),
)

sols = result(arms)  # Dict{Symbol, ODESolution}
```

### 6. Population simulation

Simulate a population of subjects from NONMEM-style data:

```julia
using CSV, DataFrames

# Load data and build population
nm = CSV.read("data.csv", DataFrame)
pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:BW])

# Simulate all subjects — duration inferred from obs_times
pr = SimContext(prob) |> subjects(pop) |> simulate()

# Extract results as DataFrames
sim_df = to_dataframe(pr)                                    # dense output
obs_df = to_dataframe(pr; obsonly=true, carry_out=[:BW])     # at observation times only
```
