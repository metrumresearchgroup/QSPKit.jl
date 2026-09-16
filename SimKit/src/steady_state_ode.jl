"""
    steady_state_solution(prob, events, alg; ss_options=SteadyStateOptions(), kwargs...)

Solve an initial SS=1 regimen with convergence checked internally. Returns
`solution` and `steady_state` (cycle count and maximum scaled change).
The forward solution starts at the event time; virtual advancement does not
shift observations. The ODE must be autonomous or periodic with period II.
See `steady_state_regimen` for the supported event forms.
"""
function steady_state_solution(prob, events, alg;
                               ss_options::SteadyStateOptions=SteadyStateOptions(), kwargs...)
    regimen = steady_state_regimen(events, first(prob.tspan))
    regimen === nothing && return (; solution=OrdinaryDiffEq.solve(prob, collect(events), alg; kwargs...), steady_state=nothing)
    for key in (:callback, :tstops)
        haskey(kwargs,key) && throw(ArgumentError("SS advancement does not support custom $key"))
    end
    cycle_kwargs = (; (k => v for (k,v) in pairs(kwargs)
        if !(k in (:saveat,:save_start,:save_end,:save_everystep,:dense,:save_idxs)))...)
    t0 = first(prob.tspan)
    runner = InjecKit.PreparedEventSolve(prob,[regimen.dose];
        tspan=(t0,t0+regimen.interval),base_u0=copy(prob.u0))
    names = SciMLBase.variable_symbols(prob)
    cycle = function (u)
        InjecKit.with_prepared_event_solve(runner; alg, base_u0=u,
            cycle_kwargs..., saveat=regimen.checkpoints, save_start=false,
            save_end=true, save_everystep=false, dense=false) do sol, _
            SciMLBase.successful_retcode(sol) || error("Steady-state interval solve failed: $(sol.retcode)")
            # Preserve the original problem's state order across event lowering.
            [sol(t;idxs=name) for name in names, t in regimen.checkpoints]
        end
    end
    ss = advance_to_steady_state(cycle, prob.u0; options=ss_options)
    forward = InjecKit.PreparedEventSolve(prob,regimen.forward;base_u0=ss.state)
    solution = forward(;alg,kwargs...)
    return (; solution, steady_state=(; cycles=ss.cycles,error=ss.error))
end

# Parameter updates remain in InjecKit's prepared executor, including symbolic
# Initial values and parameter bindings. Both SimRunner and simulate use it.
struct PreparedSteadyStateSolve
    base::InjecKit.PreparedEventSolve
    events::Vector{InjecKit.IEvent}
end

function (runner::PreparedSteadyStateSolve)(overrides;alg, duration=nothing,tspan=nothing,kwargs...)
    InjecKit.with_prepared_event_problem(runner.base,overrides;duration,tspan) do prob, callback, _
        callback === nothing || error("Steady-state base problem has unexpected event callbacks")
        steady_state_solution(prob,runner.events,alg;kwargs...).solution
    end
end
