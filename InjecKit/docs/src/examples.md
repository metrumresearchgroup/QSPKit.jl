# Examples

This page provides complete, runnable examples demonstrating various InjecKit.jl use cases.

## Example 1: Simple First-Order PK Model

A basic one-compartment model with first-order elimination.

```julia
using InjecKit, ModelingToolkit, DataFrames, DifferentialEquations, Plots

# Define the model
@parameters k V
@variables C(t)
@independent_variables t
D = Differential(t)

@mtkcompile sys = System([D(C) ~ -k*C/V], t)

# Create dosing regimen: 100mg Q8H × 3 days
dosing_data = DataFrame(
    TIME = collect(0.0:8.0:72.0),    # Every 8 hours for 3 days
    EVID = fill(1, 10),              # All dosing events
    CMT = fill(:C, 10),              # Target compartment
    AMT = fill(100.0, 10)            # 100mg doses
)

# Initial conditions and parameters
u0 = [C => 0.0]
p = [k => 0.15, V => 10.0]  # k = 0.15 hr⁻¹, V = 10L

# Solve
prob = ODEProblem(sys, u0, (0.0, 96.0), dosing_data, p)
sol = solve(prob, Tsit5(), saveat=0.5)

# Plot results
plot(sol, idxs=C, xlabel="Time (hours)", ylabel="Concentration (mg/L)",
     title="Simple PK Model - Multiple Dosing", linewidth=2)
```

## Example 2: Two-Compartment Model with Absorption

A more complex model with absorption from a depot compartment.

```julia
using InjecKit, ModelingToolkit, DataFrames, DifferentialEquations, Plots

# Define two-compartment model with absorption
@parameters ka k12 k21 k10 V1 V2
@variables depot(t) central(t) peripheral(t)
@independent_variables t
D = Differential(t)

eqs = [
    D(depot) ~ -ka * depot,
    D(central) ~ ka * depot - (k12 + k10) * central + k21 * peripheral,
    D(peripheral) ~ k12 * central - k21 * peripheral
]

@mtkcompile sys = System(eqs, t)

# Dosing: Loading dose + maintenance
dosing_data = DataFrame(
    TIME = [0.0, 8.0, 16.0, 24.0, 32.0],
    EVID = [1, 1, 1, 1, 1],
    CMT = [:depot, :depot, :depot, :depot, :depot],
    AMT = [200.0, 100.0, 100.0, 100.0, 100.0]  # Higher loading dose
)

# Parameters
u0 = [depot => 0.0, central => 0.0, peripheral => 0.0]
p = [ka => 1.0, k12 => 0.5, k21 => 0.2, k10 => 0.1, V1 => 10.0, V2 => 20.0]

# Solve
prob = ODEProblem(sys, u0, (0.0, 48.0), dosing_data, p)
sol = solve(prob, Tsit5(), saveat=0.25)

# Plot all compartments
plot(sol, idxs=[central, peripheral], 
     xlabel="Time (hours)", ylabel="Amount",
     title="Two-Compartment PK Model", 
     label=["Central" "Peripheral"], linewidth=2)
```

## Example 3: Continuous Infusions

Demonstrating various infusion types using the continuous infusion functionality.

```julia
using InjecKit, ModelingToolkit, DataFrames, DifferentialEquations, Plots

# Simple one-compartment model for infusion
@parameters k V
@variables C(t)
@independent_variables t
D = Differential(t)

@mtkcompile sys = System([D(C) ~ -k*C/V], t)

# Mixed bolus and infusion dosing using ev() function
events = [
    # Initial bolus
    ev(time=0.0, cmt=:C, amt=100.0),
    
    # Rate-based infusion (50 mg over 2.5 hours)
    ev(time=2.0, cmt=:C, amt=50.0, rate=20.0),
    
    # Duration-based infusion (75 mg over 3 hours)  
    ev(time=8.0, cmt=:C, amt=75.0, duration=3.0),
    
    # Another bolus
    ev(time=15.0, cmt=:C, amt=50.0)
]

# Solve
u0 = [C => 0.0]
p = [k => 0.1, V => 10.0]

prob = ODEProblem(sys, u0, (0.0, 24.0), events, p)
sol = solve(prob, Tsit5(), saveat=0.1)

# Plot with infusion rates
p1 = plot(sol, idxs=C, xlabel="Time (hours)", ylabel="Concentration (mg/L)",
          title="Continuous Infusions Example", linewidth=2, label="Concentration")

# Add dosing markers
dose_times = [0.0, 2.0, 8.0, 15.0]
scatter!(p1, dose_times, [0, 0, 0, 0], marker=:arrow, markersize=8, 
         color=:red, alpha=0.7, label="Doses")

# Plot infusion parameters if available
infusion_params = get_infusion_parameters(sol.prob.f.sys)
if !isempty(infusion_params)
    p2 = plot(xlabel="Time (hours)", ylabel="Infusion Rate (mg/hour)",
              title="Infusion Rate History")
    for param in infusion_params
        plot!(p2, sol, idxs=param, label=string(param), linewidth=2)
    end
    
    plot(p1, p2, layout=(2,1), size=(800,600))
else
    p1
end
```

## Example 4: Parameter Changes During Simulation

Modeling time-varying parameters due to physiological changes.

```julia
using InjecKit, ModelingToolkit, DataFrames, DifferentialEquations, Plots

# Model with clearance that can change
@parameters CL V
@variables C(t)
@independent_variables t
D = Differential(t)

@mtkcompile sys = System([D(C) ~ -(CL/V) * C], t)

# Dosing + clearance changes (e.g., enzyme induction)
mixed_events = DataFrame(
    TIME = [0.0, 8.0, 12.0, 16.0, 24.0, 24.0, 32.0],
    EVID = [1, 1, 2, 1, 1, 2, 1],  # Dosing and parameter changes
    CMT = [:C, :C, :CL, :C, :C, :CL, :C],
    AMT = [100.0, 100.0, 7.5, 100.0, 100.0, 10.0, 100.0]  # Increasing CL
)

u0 = [C => 0.0]
p = [CL => 5.0, V => 10.0]  # Initial clearance 5 L/hr

prob = ODEProblem(sys, u0, (0.0, 48.0), mixed_events, p)
sol = solve(prob, Tsit5(), saveat=0.5)

# Plot results
plot(sol, idxs=C, xlabel="Time (hours)", ylabel="Concentration (mg/L)",
     title="Time-Varying Clearance Model", linewidth=2)

# Add vertical lines at clearance changes
vline!([12.0, 24.0], linestyle=:dash, alpha=0.7, label="CL Changes")
```

## Example 5: Drug-Drug Interaction Model

Two drugs where one affects the clearance of the other.

```julia
using InjecKit, ModelingToolkit, DataFrames, DifferentialEquations, Plots

# Two-drug interaction model
@parameters ka1 ka2 CL1 CL2 V1 V2 KI
@variables depot1(t) depot2(t) central1(t) central2(t)
@independent_variables t
D = Differential(t)

# Drug 2 inhibits clearance of Drug 1
eqs = [
    D(depot1) ~ -ka1 * depot1,
    D(central1) ~ ka1 * depot1 - (CL1 / (1 + central2/KI)) * central1,
    D(depot2) ~ -ka2 * depot2, 
    D(central2) ~ ka2 * depot2 - CL2 * central2
]

@mtkcompile sys = System(eqs, t)

# Dosing regimen: Drug 1 alone, then both drugs
interaction_dosing = DataFrame(
    TIME = [0.0, 8.0, 12.0, 12.0, 16.0, 20.0, 20.0, 24.0],
    EVID = [1, 1, 1, 1, 1, 1, 1, 1],
    CMT = [:depot1, :depot1, :depot1, :depot2, :depot1, :depot1, :depot2, :depot1],
    AMT = [100.0, 100.0, 100.0, 50.0, 100.0, 100.0, 50.0, 100.0]
)

# Parameters
u0 = [depot1 => 0.0, depot2 => 0.0, central1 => 0.0, central2 => 0.0]
p = [ka1 => 1.0, ka2 => 0.8, CL1 => 5.0, CL2 => 3.0, V1 => 10.0, V2 => 15.0, KI => 20.0]

prob = ODEProblem(sys, u0, (0.0, 36.0), interaction_dosing, p)
sol = solve(prob, Tsit5(), saveat=0.25)

# Plot both drugs
plot(sol, idxs=[central1, central2],
     xlabel="Time (hours)", ylabel="Central Amount",
     title="Drug-Drug Interaction Model",
     label=["Drug 1 (inhibited)" "Drug 2 (inhibitor)"], linewidth=2)

# Add marker for when Drug 2 dosing starts
vline!([12.0], linestyle=:dash, alpha=0.7, label="Drug 2 starts")
```

## Example 6: Population Simulation Setup

Preparing for population pharmacokinetic analysis.

```julia
using InjecKit, ModelingToolkit, DataFrames, DifferentialEquations
using Random, Distributions

# Simple PK model for population simulation
@parameters ka k V
@variables depot(t) central(t)
@independent_variables t
D = Differential(t)

@mtkcompile sys = System([
    D(depot) ~ -ka * depot,
    D(central) ~ ka * depot - k * central
], t)

# Standard dosing regimen
standard_dosing = DataFrame(
    TIME = [0.0, 12.0, 24.0],
    EVID = [1, 1, 1],
    CMT = [:depot, :depot, :depot],
    AMT = [100.0, 100.0, 100.0]
)

# Population parameters (typical values and between-subject variability)
function simulate_individual(id::Int, dosing_df::DataFrame)
    # Typical population parameters
    ka_pop = 1.0   # hr⁻¹
    k_pop = 0.1    # hr⁻¹  
    V_pop = 10.0   # L
    
    # Between-subject variability (log-normal, 30% CV)
    Random.seed!(id)  # Reproducible individual parameters
    
    eta_ka = rand(Normal(0, sqrt(log(1.3^2))))
    eta_k = rand(Normal(0, sqrt(log(1.3^2)))) 
    eta_V = rand(Normal(0, sqrt(log(1.3^2))))
    
    # Individual parameters
    ka_i = ka_pop * exp(eta_ka)
    k_i = k_pop * exp(eta_k)
    V_i = V_pop * exp(eta_V)
    
    # Solve individual
    u0 = [depot => 0.0, central => 0.0]
    p = [ka => ka_i, k => k_i, V => V_i]
    
    prob = ODEProblem(sys, u0, (0.0, 48.0), dosing_df, p)
    sol = solve(prob, Tsit5(), saveat=1.0)
    
    return (id=id, ka=ka_i, k=k_i, V=V_i, solution=sol)
end

# Simulate 10 individuals
n_individuals = 10
population_results = [simulate_individual(i, standard_dosing) for i in 1:n_individuals]

# Extract concentrations for plotting
using Plots
p = plot(xlabel="Time (hours)", ylabel="Central Amount", 
         title="Population Simulation (n=$n_individuals)")

for result in population_results
    plot!(p, result.solution, idxs=central, alpha=0.6, color=:blue, 
          label=false, linewidth=1)
end

# Add population median (would need proper calculation in practice)
display(p)

# Summary of individual parameters
params_df = DataFrame(
    ID = [r.id for r in population_results],
    ka = [r.ka for r in population_results],
    k = [r.k for r in population_results], 
    V = [r.V for r in population_results]
)

println("Population Parameter Summary:")
println(describe(params_df))
```

## Example 7: Repeated Dosing with ii/addl

Demonstrating convenient repeated dosing schedules similar to NONMEM/mrgsolve.

```julia
using InjecKit, ModelingToolkit, DataFrames, DifferentialEquations, Plots

# Simple PK model
@independent_variables t
@variables C(t)
@parameters CL V
D = Differential(t)

eqs = [D(C) ~ -(CL/V) * C]
@mtkcompile sys = System(eqs, t)

u0 = Dict(C => 0.0)
p = Dict(CL => 2.0, V => 10.0)
tspan = (0.0, 168.0)  # 1 week

# Compare different repeated dosing approaches

# Method 1: Individual events (tedious for many doses)
individual_events = [
    ev(time=0.0, cmt=:C, amt=100.0),
    ev(time=12.0, cmt=:C, amt=100.0),
    ev(time=24.0, cmt=:C, amt=100.0),
    ev(time=36.0, cmt=:C, amt=100.0),
    # ... would need 14 total events for 1 week BID
]

# Method 2: Using ii/addl (much cleaner)
repeated_events = [
    ev(time=0.0, cmt=:C, amt=100.0, ii=12.0, addl=13)  # 14 doses total (0, 12, 24, ..., 156)
]

# Method 3: DataFrame with ii/addl
df_repeated = DataFrame(
    TIME = [0.0],
    EVID = [1],
    CMT = [:C],
    AMT = [100.0],
    II = [12.0],
    ADDL = [13]
)

# Solve all three approaches (should give identical results)
prob1 = ODEProblem(sys, merge(u0, p), tspan, individual_events[1:4])  # Just first 4 for demo
prob2 = ODEProblem(sys, merge(u0, p), tspan, repeated_events)
prob3 = ODEProblem(sys, merge(u0, p), tspan, df_repeated)

sol1 = solve(prob1, Tsit5(), saveat=1.0)
sol2 = solve(prob2, Tsit5(), saveat=1.0)
sol3 = solve(prob3, Tsit5(), saveat=1.0)

# Plot results
p1 = plot(sol2, idxs=C, xlabel="Time (hours)", ylabel="Concentration (mg/L)",
          title="Repeated Dosing: 100mg Q12H × 1 week", linewidth=2, label="IEvent")
plot!(p1, sol3, idxs=C, linestyle=:dash, linewidth=2, label="DataFrame")

# Add dosing markers
dose_times = collect(0.0:12.0:156.0)
scatter!(p1, dose_times, zeros(length(dose_times)), 
         marker=:arrow, markersize=4, color=:red, alpha=0.7, label="Doses")

display(p1)
```

## Example 8: Mixed Repeated and Single Events

Combining repeated dosing with individual events for complex regimens.

```julia
# Complex regimen: Loading dose + repeated maintenance + rescue doses
complex_events = [
    # Loading dose (higher amount)
    ev(time=0.0, cmt=:C, amt=200.0),
    
    # Repeated maintenance dosing starting at 12h (100mg Q12H × 6 doses)
    ev(time=12.0, cmt=:C, amt=100.0, ii=12.0, addl=5),
    
    # Rescue doses (individual events)
    ev(time=30.0, cmt=:C, amt=50.0),   # Low concentration rescue
    ev(time=54.0, cmt=:C, amt=75.0),   # Another rescue
    
    # Final maintenance phase (lower dose, longer interval)
    ev(time=84.0, cmt=:C, amt=75.0, ii=24.0, addl=2)  # Q24H × 3 doses
]

prob = ODEProblem(sys, merge(u0, p), tspan, complex_events)
sol = solve(prob, Tsit5(), saveat=1.0)

# Plot with event annotations
p_complex = plot(sol, idxs=C, xlabel="Time (hours)", ylabel="Concentration (mg/L)",
                title="Complex Dosing Regimen", linewidth=2, label="Concentration")

# Annotate different phases
vline!([0], color=:green, alpha=0.7, label="Loading", linestyle=:solid)
vline!([12, 24, 36, 48, 60], color=:blue, alpha=0.5, label="Maintenance", linestyle=:dash)
vline!([30, 54], color=:orange, alpha=0.7, label="Rescue", linestyle=:dot)
vline!([84, 108, 132], color=:purple, alpha=0.7, label="Final Phase", linestyle=:dashdot)

display(p_complex)
```

## Example 9: Simultaneous Events

Multiple events occurring at the same time point.

```julia
# Model with time-varying clearance for simultaneous event demo
@discretes CL_td(t)
@parameters V_static
eqs_tv = [D(C) ~ -(CL_td/V_static) * C]
@mtkcompile sys_tv = System(eqs_tv, t)

u0_tv = Dict(C => 100.0)  # Start with some drug
p_tv = Dict(CL_td => 2.0, V_static => 10.0)
tspan_tv = (0.0, 24.0)

# Simultaneous events: parameter change + infusion + bolus at t=5
simultaneous_events = DataFrame(
    TIME = [0.0, 5.0, 5.0, 5.0, 15.0],
    EVID = [1, 2, 1, 1, 1],
    CMT = [:C, missing, :C, :C, :C],
    AMT = [100.0, missing, missing, 50.0, missing],
    RATE = [0.0, missing, 25.0, 0.0, 0.0],
    DURATION = [missing, missing, 10.0, missing, missing],
    CL_td = [missing, 5.0, missing, missing, missing]  # Increase clearance
)

prob_sim = ODEProblem(sys_tv, merge(u0_tv, p_tv), tspan_tv, simultaneous_events)
sol_sim = solve(prob_sim, Tsit5(), saveat=0.1)

# Plot results
p_sim = plot(sol_sim, idxs=C, xlabel="Time (hours)", ylabel="Concentration (mg/L)",
            title="Simultaneous Events at t=5", linewidth=2, label="Concentration")

# Mark the simultaneous events at t=5
vline!([5.0], color=:red, alpha=0.8, linewidth=3, 
       label="CL↑ + Infusion + Bolus")

# Show infusion parameters if available
infusion_params = InjecKit.get_infusion_parameters(sol_sim.prob.f.sys)
if !isempty(infusion_params)
    p2 = plot(sol_sim, idxs=infusion_params[1], xlabel="Time (hours)", 
             ylabel="Infusion Rate", title="Infusion Rate", 
             linewidth=2, label="Auto-created infusion parameter")
    
    plot(p_sim, p2, layout=(2,1), size=(800,600))
else
    p_sim
end
```

## Example 10: Complex Infusion Schedule

Real-world intensive care dosing with multiple infusion lines.

```julia
using InjecKit, ModelingToolkit, DataFrames, DifferentialEquations

# Two-compartment model for ICU drug
@parameters CL Q V1 V2  
@variables central(t) peripheral(t)
@independent_variables t
D = Differential(t)

eqs = [
    D(central) ~ -(CL + Q) * central / V1 + Q * peripheral / V1,
    D(peripheral) ~ Q * central / V1 - Q * peripheral / V2
]

@mtkcompile sys = System(eqs, t)

# Complex ICU dosing protocol using continuous infusions
icu_protocol = [
    # Loading dose
    ev(time=0.0, cmt=:central, amt=400.0),
    
    # Primary maintenance infusion (24h)
    ev(time=0.5, cmt=:central, amt=1200.0, rate=50.0),
    
    # Rescue boluses during maintenance
    ev(time=6.0, cmt=:central, amt=100.0),   # 6h rescue
    ev(time=18.0, cmt=:central, amt=150.0),  # 18h rescue
    
    # Dose adjustment: reduce rate at 24h
    ev(time=24.5, cmt=:central, amt=960.0, rate=40.0),  # Reduced rate for 24h
    
    # Final day: further reduction
    ev(time=48.5, cmt=:central, amt=720.0, rate=30.0)   # 24h at lowest rate
]

# ICU parameters (critically ill patient)
u0 = [central => 0.0, peripheral => 0.0]
p = [CL => 8.0, Q => 4.0, V1 => 15.0, V2 => 50.0]  # Altered PK in ICU

prob = ODEProblem(sys, u0, (0.0, 96.0), icu_protocol, p)
sol = solve(prob, Tsit5(), saveat=0.5)

# Comprehensive plotting
using Plots

# Main concentration plot
p1 = plot(sol, idxs=central, xlabel="Time (hours)", 
          ylabel="Central Amount", title="ICU Dosing Protocol",
          linewidth=2, label="Central Compartment")

# Add dosing events
dose_times = [0.0, 0.5, 6.0, 18.0, 24.5, 48.5]
dose_types = ["Bolus", "Infusion Start", "Rescue", "Rescue", "Rate↓", "Rate↓↓"]

for (i, (t, type)) in enumerate(zip(dose_times, dose_types))
    vline!(p1, [t], alpha=0.7, linestyle=:dash, 
           label=i==1 ? "Dose Events" : false)
end

# Infusion rate history
infusion_params = get_infusion_parameters(sol.prob.f.sys)
if !isempty(infusion_params)
    p2 = plot(xlabel="Time (hours)", ylabel="Infusion Rate", 
              title="Infusion Rate Profile")
    for param in infusion_params
        plot!(p2, sol, idxs=param, linewidth=2, 
              label="Infusion Rate")
    end
    
    plot(p1, p2, layout=(2,1), size=(800,600))
else
    p1
end
```

These examples demonstrate the flexibility and power of InjecKit.jl for various pharmacokinetic modeling scenarios, from simple single-compartment models to complex multi-drug interactions and population simulations.