# Advanced Usage

This tutorial covers advanced features and techniques for complex modeling scenarios with InjecKit.jl.

## Complex Event Sequences

### Repeated Dosing with Intervals

```julia
using InjecKit, ModelingToolkit, DataFrames, DifferentialEquations

# Create repeated dosing events programmatically
function create_repeated_dosing(dose_times, dose_amounts, compartment)
    DataFrame(
        TIME = dose_times,
        EVID = fill(1, length(dose_times)),
        CMT = fill(compartment, length(dose_times)),
        AMT = dose_amounts
    )
end

# Q8H dosing for 3 days
q8h_times = collect(0.0:8.0:72.0)  # Every 8 hours for 72 hours
q8h_doses = fill(100.0, length(q8h_times))
dosing_regimen = create_repeated_dosing(q8h_times, q8h_doses, :central)
```

### Time-Varying Parameters

```julia
# Define model with time-varying clearance
@parameters CL_base CL_slope V
@variables C(t) CL(t)
D = Differential(t)

# Clearance increases over time (e.g., enzyme induction)
eqs = [
    CL ~ CL_base + CL_slope * t,
    D(C) ~ -CL * C / V
]

@mtkcompile sys = System(eqs, t)

# Alternative: Step changes in parameters
clearance_changes = DataFrame(
    TIME = [0.0, 24.0, 48.0],
    EVID = [2, 2, 2],
    CMT = [:CL_base, :CL_base, :CL_base],
    AMT = [5.0, 7.5, 10.0]  # Increasing clearance
)
```

### Covariate Effects

```julia
# Model with body weight covariate
@parameters CL_pop CL_WT V_pop V_WT WT
@variables C(t)

# Allometric scaling
eqs = [
    D(C) ~ -(CL_pop * (WT/70)^CL_WT) * C / (V_pop * (WT/70)^V_WT)
]

@mtkcompile sys = System(eqs, t)

# Weight changes over time (e.g., pediatric growth)
weight_updates = DataFrame(
    TIME = [0.0, 30.0, 60.0, 90.0],  # Monthly updates
    EVID = [2, 2, 2, 2],
    CMT = [:WT, :WT, :WT, :WT],
    AMT = [15.0, 16.2, 17.5, 18.8]  # Growing child
)
```

## Multiple Drug Models

### Drug-Drug Interactions

```julia
# Two-drug interaction model
@parameters ka1 ka2 CL1 CL2 V1 V2 KI  # KI = inhibition constant
@variables depot1(t) depot2(t) central1(t) central2(t)

# Drug 2 inhibits clearance of Drug 1
eqs = [
    D(depot1) ~ -ka1 * depot1,
    D(central1) ~ ka1 * depot1 - (CL1 / (1 + central2/KI)) * central1 / V1,
    D(depot2) ~ -ka2 * depot2,
    D(central2) ~ ka2 * depot2 - CL2 * central2 / V2
]

@mtkcompile sys = System(eqs, t)

# Dosing both drugs
interaction_dosing = DataFrame(
    TIME = [0.0, 0.0, 8.0, 8.0, 16.0, 16.0],
    EVID = [1, 1, 1, 1, 1, 1],
    CMT = [:depot1, :depot2, :depot1, :depot2, :depot1, :depot2],
    AMT = [100.0, 50.0, 100.0, 50.0, 100.0, 50.0]
)
```

### Sequential Therapy

```julia
# Switch from one drug to another
sequential_therapy = DataFrame(
    TIME = [0.0, 8.0, 16.0, 24.0, 32.0, 40.0],
    EVID = [1, 1, 1, 1, 1, 1],
    CMT = [:depot1, :depot1, :depot1, :depot2, :depot2, :depot2],  # Switch at 24h
    AMT = [100.0, 100.0, 100.0, 75.0, 75.0, 75.0]
)
```

## Advanced Infusion Patterns

### Variable Rate Infusions

Using the continuous infusion functionality with time-varying rates:

```julia
# Tapering infusion using multiple events
tapering_infusion = [
    ev(time=0.0, cmt=:C, amt=240.0, rate=20.0),   # High rate: 12h
    ev(time=12.0, cmt=:C, amt=180.0, rate=15.0),  # Medium rate: 12h  
    ev(time=24.0, cmt=:C, amt=120.0, rate=10.0)   # Low rate: 12h
]

prob = ODEProblem(sys, u0, (0.0, 48.0), tapering_infusion, p)
```

### Overlapping Infusions

```julia
# Multiple concurrent infusions
overlapping_infusions = [
    # Primary infusion line
    ev(time=0.0, cmt=:central, amt=480.0, rate=20.0),    # 24h infusion
    
    # Secondary bolus doses  
    ev(time=6.0, cmt=:central, amt=50.0),                # Rescue dose
    ev(time=18.0, cmt=:central, amt=50.0),               # Another rescue
    
    # Maintenance infusion starts before primary ends
    ev(time=20.0, cmt=:central, amt=600.0, rate=10.0)    # Lower rate, longer duration
]
```

## Population Modeling Preparation

### Individual Simulation

```julia
# Function to simulate individual with specific parameters
function simulate_individual(individual_params, dosing_events, tspan)
    u0 = [central => 0.0, peripheral => 0.0]
    prob = ODEProblem(sys, u0, tspan, dosing_events, individual_params)
    return solve(prob, Tsit5(), saveat=0.5)
end

# Different individual parameters
individual1_params = [ka => 1.2, k12 => 0.5, k21 => 0.2, k10 => 0.1, V1 => 8.0, V2 => 15.0]
individual2_params = [ka => 0.8, k12 => 0.3, k21 => 0.15, k10 => 0.15, V1 => 12.0, V2 => 25.0]

# Simulate both
sol1 = simulate_individual(individual1_params, dosing_regimen, (0.0, 72.0))
sol2 = simulate_individual(individual2_params, dosing_regimen, (0.0, 72.0))
```

### Batch Simulation

```julia
# Simulate population of individuals
function simulate_population(n_individuals, base_params, cv_params, dosing_events, tspan)
    solutions = []
    
    for i in 1:n_individuals
        # Add between-subject variability (lognormal)
        individual_params = copy(base_params)
        for (param, cv) in cv_params
            param_idx = findfirst(p -> p.first == param, individual_params)
            if param_idx !== nothing
                base_value = individual_params[param_idx].second
                # Lognormal variability: new_value = base * exp(η) where η ~ N(0, ω²)
                eta = randn() * sqrt(log(cv^2 + 1))
                new_value = base_value * exp(eta)
                individual_params[param_idx] = param => new_value
            end
        end
        
        sol = simulate_individual(individual_params, dosing_events, tspan)
        push!(solutions, sol)
    end
    
    return solutions
end

# Population simulation
base_params = [ka => 1.0, k12 => 0.4, k21 => 0.18, k10 => 0.12, V1 => 10.0, V2 => 20.0]
cv_params = Dict(ka => 0.3, k10 => 0.4, V1 => 0.2)  # 30%, 40%, 20% CV

population_solutions = simulate_population(50, base_params, cv_params, dosing_regimen, (0.0, 72.0))
```

## Custom Event Processing

### Conditional Dosing

```julia
# Create events based on concentration thresholds
function create_conditional_dosing(target_concentration, monitoring_times, rescue_dose)
    events = DataFrame(
        TIME = Float64[],
        EVID = Int[],
        CMT = Symbol[],
        AMT = Float64[]
    )
    
    # Regular monitoring doses would be added here based on 
    # concentration-dependent logic (requires iterative solving)
    
    return events
end
```

### Protocol Violations

```julia
# Handle missed doses or protocol deviations
planned_dosing = DataFrame(
    TIME = collect(0.0:8.0:72.0),
    EVID = fill(1, 10),
    CMT = fill(:central, 10),
    AMT = fill(100.0, 10)
)

# Remove doses (missed doses)
missed_dose_times = [16.0, 32.0]  # Miss 3rd and 5th doses
actual_dosing = filter(row -> !(row.TIME in missed_dose_times), planned_dosing)

# Add rescue doses
rescue_doses = DataFrame(
    TIME = [20.0, 36.0],  # 4 hours after missed doses
    EVID = [1, 1],
    CMT = [:central, :central],
    AMT = [150.0, 150.0]  # Higher rescue dose
)

final_dosing = vcat(actual_dosing, rescue_doses)
final_dosing = sort(final_dosing, :TIME)
```

## Model Diagnostics and Validation

### Parameter Sensitivity

```julia
# Test sensitivity to parameter changes
base_p = [ka => 1.0, k10 => 0.1, V => 10.0]

# ±20% parameter changes
sensitivity_tests = [
    [ka => 0.8, k10 => 0.1, V => 10.0],   # -20% ka
    [ka => 1.2, k10 => 0.1, V => 10.0],   # +20% ka
    [ka => 1.0, k10 => 0.08, V => 10.0],  # -20% k10
    [ka => 1.0, k10 => 0.12, V => 10.0],  # +20% k10
    [ka => 1.0, k10 => 0.1, V => 8.0],    # -20% V
    [ka => 1.0, k10 => 0.1, V => 12.0]    # +20% V
]

sensitivity_solutions = [simulate_individual(p, dosing_regimen, (0.0, 48.0)) for p in sensitivity_tests]
```

### Event Timing Validation

```julia
# Validate event timing and dosing history
function validate_dosing_regimen(events_df)
    # Check for negative times
    if any(events_df.TIME .< 0)
        @warn "Negative event times found"
    end
    
    # Check for missing AMT in dosing events
    dosing_events = filter(row -> row.EVID == 1, events_df)
    if any(ismissing.(dosing_events.AMT))
        error("Missing AMT values for dosing events")
    end
    
    # Check for reasonable dosing intervals
    if nrow(dosing_events) > 1
        intervals = diff(dosing_events.TIME)
        if any(intervals .< 0.1)  # Less than 6 minutes between doses
            @warn "Very short dosing intervals detected"
        end
    end
    
    return true
end

validate_dosing_regimen(final_dosing)
```

## Performance Optimization

### Efficient Large-Scale Simulations

```julia
# Pre-allocate for large simulations
function efficient_population_sim(n_individuals, base_params, dosing_events, tspan)
    # Pre-allocate solution storage
    all_concentrations = Matrix{Float64}(undef, n_individuals, length(0:0.5:tspan[2]))
    
    Threads.@threads for i in 1:n_individuals
        # Individual parameter sampling
        individual_params = sample_parameters(base_params)
        
        # Solve
        prob = ODEProblem(sys, u0, tspan, dosing_events, individual_params)
        sol = solve(prob, Tsit5(), saveat=0.5)
        
        # Store concentrations
        all_concentrations[i, :] = sol[central, :]
    end
    
    return all_concentrations
end
```

### Memory Management

```julia
# For very large datasets, process in chunks
function process_large_dataset(large_dosing_df, chunk_size=1000)
    n_rows = nrow(large_dosing_df)
    results = []
    
    for start_idx in 1:chunk_size:n_rows
        end_idx = min(start_idx + chunk_size - 1, n_rows)
        chunk = large_dosing_df[start_idx:end_idx, :]
        
        # Process chunk
        prob = ODEProblem(sys, u0, tspan, chunk, p)
        sol = solve(prob, Tsit5())
        
        push!(results, sol)
        
        # Optional: Clear memory
        GC.gc()
    end
    
    return results
end
```

## Integration with Other Packages

### Pumas.jl Compatibility

```julia
# Prepare data for Pumas.jl format
function convert_to_pumas_format(mrg_events_df)
    # Convert InjecKit DataFrame to Pumas-compatible format
    pumas_df = copy(mrg_events_df)
    rename!(pumas_df, :CMT => :cmt, :AMT => :amt, :TIME => :time)
    
    # Add ID column for population modeling
    pumas_df[!, :id] = fill(1, nrow(pumas_df))
    
    return pumas_df
end
```

### Plots.jl Integration

```julia
using Plots

# Custom plotting functions for InjecKit
function plot_dosing_history(events_df, title="Dosing History")
    dosing_events = filter(row -> row.EVID == 1, events_df)
    
    p = scatter(dosing_events.TIME, dosing_events.AMT,
               xlabel="Time", ylabel="Dose Amount",
               title=title, markersize=6, alpha=0.7)
    
    return p
end

function plot_concentration_with_doses(sol, events_df, compartment_idx=1)
    p1 = plot(sol, idxs=compartment_idx, linewidth=2, 
              xlabel="Time", ylabel="Concentration",
              title="PK Profile with Dosing")
    
    # Add dosing markers
    dosing_events = filter(row -> row.EVID == 1, events_df)
    scatter!(p1, dosing_events.TIME, fill(0, nrow(dosing_events)),
            marker=:arrow, markersize=8, alpha=0.7, color=:red,
            label="Doses")
    
    return p1
end
```

This advanced functionality makes InjecKit.jl suitable for complex pharmacokinetic modeling scenarios while maintaining the familiar NONMEM/mrgsolve workflow.