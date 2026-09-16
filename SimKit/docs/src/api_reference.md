# API Reference

## Types

```@docs
SimContext
Phase
Pipeline
PipelineStep
SimulationError
SimRunner
LazyBranch
Subject
Population
PopulationResult
```

## Pipeline Operations

```@docs
with
events
keep
observe
simulate
simulate_solution
```

## Simulation Options & Periodic Steady State

```@docs
simulation_options
SteadyStateOptions
advance_to_steady_state
has_steady_state
steady_state_regimen
steady_state_solution
```

## Population

```@docs
subjects
to_dataframe
```

## Branching & Results

```@docs
branch
branch_lazy
result
phases
scan
```

## Display

```@docs
inspect
```

## Time Helpers

```@docs
weeks
days
hours
```

## Cache Control

```@docs
disable_cache!
enable_cache!
```
