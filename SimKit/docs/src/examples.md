# Examples

## Switching Inputs After a Reset Window

```julia
result = sim |>
    with(reference_params) |> simulate(12.0; name=:settle) |>
    with(pulse_params) |> events(short_pulses) |> simulate(6.0; name=:pulse_phase) |>
    simulate(2.5; name=:reset_window) |>
    with(step_params) |> events(step_events) |> simulate(9.0; name=:step_phase)
```

## Combining Independent Event Streams

```julia
using InjecKit: combine

combined_params = merge(channel_a_params, channel_b_params)
combined_events = combine(channel_a_events, channel_b_events)

result = sim |>
    with(reference_params) |> simulate(12.0; name=:settle) |>
    with(combined_params) |> events(combined_events) |> simulate(9.0; name=:combined)
```

## Initialization + Repeating Events

```julia
result = sim |>
    with(reference_params) |> simulate(12.0; name=:settle) |>
    with(input_params) |> events(initial_event) |> keep() |> simulate(1.5; name=:initialize) |>
    events(repeating_events) |> keep() |> simulate(7.5; name=:repeat) |>
    simulate(3.0; name=:observe)
```

## Parameter Sensitivity Sweep

```julia
results = scan(baseline, :decay_rate => [0.03, 0.08, 0.2, 0.6]) do ctx, params
    ctx |> with(params) |> events(probe_events) |> simulate(15.0; name=:sweep)
end
```

## Conditions from DataFrame

```julia
conditions = DataFrame(
    mode = [:quiet, :nominal, :burst],
    input_level = [0.4, 0.9, 1.7],
    schedule = [quiet_events, nominal_events, burst_events],
)

arms = branch(baseline, conditions; name=:mode, params=[:input_level], event_col=:schedule)
```

## Scan Across a Population

Scan a parameter across all subjects in a population. Each scan point simulates the full population with that parameter override:

```julia
pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:input_scale, :initial_offset])

baseline = SimContext(prob)
results = baseline |> scan(:initial_offset => [0.1, 0.6, 1.3]) do ctx, params
    ctx |> with(params) |> subjects(pop) |> simulate()
end

df = to_dataframe(results; carry_out=[:input_scale, :initial_offset])
```

Each entry in `results` is a `(params=Dict, result=PopulationResult)` tuple. `to_dataframe` flattens everything into a single DataFrame with scanned parameter columns added.

## Branch with Nested Scans

Combine `branch` and `scan` for multi-arm, multi-parameter exploration. Each arm can scan different parameter spaces with dynamically generated events:

```julia
levels = [0.25, 0.75, 1.5, 2.5]
baseline = SimContext(prob)

results = branch(baseline,
    :pulse => scan(:input_level => levels, :interval => [1.5, 4.0],
                   :initial_offset => [0.1, 0.6, 1.3]) do c, params
        evs = [ev(time=Float64(t), cmt=:InputA, amt=params[:input_level])
                  for t in 0.0:params[:interval]:18.0]
        c |> with(params) |> events(evs) |> simulate(18.0)
    end,
    :step => scan(:input_level => levels, :interval => [1.5, 4.0],
                  :initial_offset => [0.1, 0.6, 1.3]) do c, params
        evs = [ev(time=Float64(t), cmt=:InputB, amt=params[:input_level])
                  for t in 0.0:params[:interval]:18.0]
        c |> with(params) |> events(evs) |> simulate(18.0)
    end,
)

# to_dataframe adds :ARM column plus all scanned parameter columns
df = to_dataframe(results; carry_out=[:scale, :input_scale, :initial_offset, :interval])
```

The result is a Dict where each arm contains scan results. `to_dataframe`
handles the nesting automatically, producing a single DataFrame with `:ARM`,
`:input_level`, `:interval`, and `:initial_offset` columns alongside state
variables.

## Population Simulation (NONMEM data)

```julia
using CSV, DataFrames

nm = CSV.read("synthetic_population.csv", DataFrame)

pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:input_scale, :initial_offset])

pr = SimContext(prob) |> subjects(pop) |> simulate()

# Dense simulation for plotting
sim_df = to_dataframe(pr; carry_out=[:input_scale])

# Observations only (with DV column)
obs_df = to_dataframe(pr; obsonly=true, carry_out=[:input_scale])

# Check for failures
length(pr.errors) > 0 && @warn "$(length(pr.errors)) subjects failed"
```
