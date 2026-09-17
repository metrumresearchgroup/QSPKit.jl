# Examples

## Dose Switching with Washout

```julia
result = sim |>
    with(disease) |> simulate(2000.0; name=:baseline) |>
    with(drug_a) |> events(drug_a_events) |> simulate(weeks(24); name=:on_drug_a) |>
    simulate(weeks(4); name=:washout) |>
    with(drug_b) |> events(drug_b_events) |> simulate(weeks(24); name=:on_drug_b)
```

## Combination Therapy

```julia
using QSPKit.InjecKit: combine

combo_params = merge(drug_a_params, drug_b_params)
combo_events = combine(drug_a_events, drug_b_events)

result = sim |>
    with(disease) |> simulate(2000.0; name=:baseline) |>
    with(combo_params) |> events(combo_events) |> simulate(weeks(52); name=:combination)
```

## Loading + Maintenance

```julia
result = sim |>
    with(disease) |> simulate(2000.0; name=:baseline) |>
    with(drug) |> events(loading_dose) |> keep() |> simulate(weeks(2); name=:loading) |>
    events(maintenance_dose) |> keep() |> simulate(weeks(50); name=:maintenance) |>
    simulate(weeks(12); name=:follow_up)
```

## Parameter Sensitivity Sweep

```julia
results = scan(baseline, :CL => [0.1, 0.5, 1.0, 2.0, 5.0]) do ctx, params
    ctx |> with(params) |> events(drug_events) |> simulate(weeks(52); name=:sweep)
end
```

## Conditions from DataFrame

```julia
conditions = DataFrame(
    arm     = [:arm1, :arm2, :arm3],
    dose_mg = [100, 200, 400],
    regimen = [low_events, mid_events, high_events],
)

arms = branch(baseline, conditions; name=:arm, params=[:dose_mg], event_col=:regimen)
```

## Scan Across a Population

Scan a parameter across all subjects in a population. Each scan point simulates the full population with that parameter override:

```julia
pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:BW, :igg_baseline])

baseline = SimContext(prob)
results = baseline |> scan(:igg_baseline => [2.0, 4.0, 6.0, 8.0]) do ctx, params
    ctx |> with(params) |> subjects(pop) |> simulate()
end

df = to_dataframe(results; carry_out=[:BW, :igg_baseline])
```

Each entry in `results` is a `(params=Dict, result=PopulationResult)` tuple. `to_dataframe` flattens everything into a single DataFrame with scanned parameter columns added.

## Branch with Nested Scans

Combine `branch` and `scan` for multi-arm, multi-parameter exploration. Each arm can scan different parameter spaces with dynamically generated events:

```julia
doses = (50:50:1000) .* 70 / 1000.0
baseline = SimContext(prob)

results = branch(baseline,
    :SC => scan(:dose => doses, :ii => [14.0, 28.0], :igg_baseline => [2.0, 4.0, 6.0, 8.0]) do c, params
        evs = [ev(time=Float64(t), cmt=:Depot, amt=params[:dose])
                  for t in 0.0:params[:ii]:730.0]
        c |> with(params) |> events(evs) |> simulate(730.0)
    end,
    :IV => scan(:dose => doses, :ii => [14.0, 28.0], :igg_baseline => [2.0, 4.0, 6.0, 8.0]) do c, params
        evs = [ev(time=Float64(t), cmt=:Central, amt=params[:dose])
                  for t in 0.0:params[:ii]:730.0]
        c |> with(params) |> events(evs) |> simulate(730.0)
    end,
)

# to_dataframe adds :ARM column plus all scanned parameter columns
df = to_dataframe(results; carry_out=[:V1_pkg, :BW, :igg_baseline, :ii])
```

The result is a Dict where each arm contains scan results. `to_dataframe` handles the nesting automatically, producing a single DataFrame with `:ARM`, `:dose`, `:ii`, `:igg_baseline` columns alongside state variables.

## Population Simulation (NONMEM data)

```julia
using CSV, DataFrames

nm = CSV.read("pk_data.csv", DataFrame)

pop = Population(nm; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                 parameters=[:BW, :igg_baseline])

pr = SimContext(prob) |> subjects(pop) |> simulate()

# Dense simulation for plotting
sim_df = to_dataframe(pr; carry_out=[:BW])

# Observations only (with DV column)
obs_df = to_dataframe(pr; obsonly=true, carry_out=[:BW])

# Check for failures
length(pr.errors) > 0 && @warn "$(length(pr.errors)) subjects failed"
```
