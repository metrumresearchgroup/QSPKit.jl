function OrdinaryDiffEq.solve(prob::ODEProblem, schedule::EventSchedule, alg=nothing; kwargs...)
    prepared_sol = _solve_configkit_updated_events(prob, schedule, alg; kwargs...)
    prepared_sol === nothing || return prepared_sol
    return solve_event_runner(cached_event_runner(prob, schedule), prob, alg; kwargs...)
end

"""
    OrdinaryDiffEq.solve(prob::ODEProblem, df::DataFrame, alg=nothing; kwargs...)

Solve ODEProblem with DataFrame events as positional argument.
This uses multiple dispatch to avoid recursion issues.

# Arguments
- `prob::ODEProblem`: The ODE problem to solve
- `df::DataFrame`: Event data frame
- `alg`: The solver algorithm (defaults to automatic selection)
- `kwargs...`: Additional keyword arguments passed to solve()

# Returns
Solution object from DifferentialEquations.jl

# Example
```julia
# With DataFrame
df = DataFrame(TIME=[5.0, 10.0], EVID=[1, 1], CMT=[:depot, :depot], AMT=[100.0, 50.0])
sol = solve(prob, df, Tsit5(); saveat=0.1)
```
"""
function OrdinaryDiffEq.solve(prob::ODEProblem, df::DataFrame, alg=nothing; kwargs...)
    return OrdinaryDiffEq.solve(prob, InjecKit.prepare_events(df), alg; kwargs...)
end

"""
    OrdinaryDiffEq.solve(prob::ODEProblem, events::Vector{<:MTK.SymbolicDiscreteCallback}, alg=nothing; kwargs...)

Solve ODEProblem with events vector as positional argument.
This uses multiple dispatch to avoid recursion issues.

# Arguments
- `prob::ODEProblem`: The ODE problem to solve
- `events::Vector{<:MTK.SymbolicDiscreteCallback}`: Pre-defined events
- `alg`: The solver algorithm (defaults to automatic selection)
- `kwargs...`: Additional keyword arguments passed to solve()

# Returns
Solution object from DifferentialEquations.jl

# Example
```julia
# With pre-defined events
events = [MTK.SymbolicDiscreteCallback([5.0], [depot ~ Pre(depot) + 100.0])]
sol = solve(prob, events, Tsit5(); saveat=0.1)
```
"""
function OrdinaryDiffEq.solve(prob::ODEProblem, events::Vector{<:MTK.SymbolicDiscreteCallback}, alg=nothing; kwargs...)
    # Check if problem has an MTK System
    if !hasproperty(prob.f, :sys) || !isa(prob.f.sys, MTK.AbstractSystem)
        error("solve with events only works with ODEProblems where f is an AbstractSystem type")
    end

    # Extract components from original problem
    sys = prob.f.sys
    tspan = prob.tspan

    # Extract u0 and parameters from original problem using unified function
    u0_p_map = InjecKit.extract_u0_p_from_problem(prob)

    # Use optimized constructor to create problem with events properly integrated
    prob_with_events = optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)

    # Solve with the updated problem (remove kwargs that were used in constructor)
    solve_kwargs = filter(p -> !(first(p) in [:tstops]), kwargs)
    if alg === nothing
        return SciMLBase.solve(prob_with_events; solve_kwargs...)
    else
        return SciMLBase.solve(prob_with_events, alg; solve_kwargs...)
    end
end

"""
    OrdinaryDiffEq.solve(prob::ODEProblem, event::MTK.SymbolicDiscreteCallback, alg=nothing; kwargs...)

Solve ODEProblem with single event as positional argument.
This uses multiple dispatch to avoid recursion issues.

# Arguments
- `prob::ODEProblem`: The ODE problem to solve
- `event::MTK.SymbolicDiscreteCallback`: Single event
- `alg`: The solver algorithm (defaults to automatic selection)
- `kwargs...`: Additional keyword arguments passed to solve()

# Returns
Solution object from DifferentialEquations.jl

# Example
```julia
# With single event
event = MTK.SymbolicDiscreteCallback([5.0], [depot ~ Pre(depot) + 100.0])
sol = solve(prob, event, Tsit5(); saveat=0.1)
```
"""
function OrdinaryDiffEq.solve(prob::ODEProblem, event::MTK.SymbolicDiscreteCallback, alg=nothing; kwargs...)
    # Just wrap single event in vector and delegate
    return OrdinaryDiffEq.solve(prob, [event], alg; kwargs...)
end

"""
    OrdinaryDiffEq.solve(prob::ODEProblem, events::Vector{IEvent}, alg=nothing; kwargs...)

Solve ODEProblem with IEvent vector as positional argument.
This uses multiple dispatch to avoid recursion issues.

# Arguments
- `prob::ODEProblem`: The ODE problem to solve
- `events::Vector{IEvent}`: IEvent vector
- `alg`: The solver algorithm (defaults to automatic selection)
- `kwargs...`: Additional keyword arguments passed to solve()

# Returns
Solution object from DifferentialEquations.jl

# Example
```julia
# With IEvent vector
events = [ev(time=5.0, cmt=:depot, amt=100.0)]
sol = solve(prob, events, Tsit5(); saveat=0.1)
```
"""
function OrdinaryDiffEq.solve(prob::ODEProblem, events::Vector{IEvent}, alg=nothing; kwargs...)
    return OrdinaryDiffEq.solve(prob, InjecKit.prepare_events(events), alg; kwargs...)
end

function OrdinaryDiffEq.solve(prob::ODEProblem, event::IEvent, alg=nothing; kwargs...)
    return OrdinaryDiffEq.solve(prob, InjecKit.prepare_events(event), alg; kwargs...)
end
