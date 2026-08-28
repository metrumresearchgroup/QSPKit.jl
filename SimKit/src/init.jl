# ============================================================
# SimContext constructor — create from an ODEProblem
# ============================================================

"""
    SimContext(prob::SciMLBase.ODEProblem; solver=nothing, kwargs...)

Create a `SimContext` from an ODEProblem.

# Arguments
- `prob`: The base ODE problem
- `solver`: Default solver algorithm (for example, `OrdinaryDiffEqBDF.QNDF()`)
- `kwargs...`: Default solver keyword arguments (for example, `reltol=1e-6`, `maxiters=50000`, `saveat=[12.0]`)

# Example
```julia
sim = SimContext(prob; solver=OrdinaryDiffEqBDF.QNDF(), reltol=1e-6, maxiters=50000)
```

# Direct pipeline entry (auto-wrap)
A bare MTK-backed `ODEProblem` can also enter a pipeline directly, without ever
naming `SimContext` — it auto-wraps in a default context at the top of the
pipeline (via `Base.:(|>)(::ODEProblem, ::PipelineStep)` / `(::ODEProblem, ::Pipeline)`):
```julia
prob |> simulate(28.0)                                  # default auto-switching solver
prob |> with(:CL => 2.0) |> events(evs) |> simulate(28.0)
prob |> (with(:CL => 2.0) >> simulate(28.0))            # >>-composed Pipeline
```
No solver is named on this path, so the auto-switching default applies at solve
time; per-phase solver/tolerances can be set on the first `simulate` and then
propagate forward (see [`simulate`](@ref)). Reach for the explicit
`SimContext(prob; solver=…, reltol=…)` form when you want to configure solver
defaults once and reuse them across many phases.
"""
function SimContext(prob::SciMLBase.ODEProblem; solver=nothing, sys=nothing, kwargs...)
    if sys === nothing && hasproperty(prob.f, :sys) && prob.f.sys !== nothing
        sys = prob.f.sys
    end
    sys === nothing &&
        error("SimKit requires an MTK-backed ODEProblem or explicit `sys`; plain SciML ODEProblem inputs are unsupported.")
    SimContext(
        prob,
        nothing,
        NamedTuple(),
        InjecKit.prepare_events(InjecKit.IEvent[]),
        solver,
        NamedTuple(kwargs),
        Phase[],
        false,
        sys,
    )
end
