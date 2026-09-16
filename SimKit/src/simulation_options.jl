"""
    simulation_options(defaults=NamedTuple(); kwargs...)

Resolve numerical settings for a simulation wrapper. Returns `solver` keywords
for the ODE backend and `steady_state` settings for periodic advancement.
Callers can supply their existing solver settings as `defaults`.

`ss_options` is interpreted by SimKit and defaults to `SteadyStateOptions()`.
Scalar `abstol` and `reltol` overrides must be finite and positive; `nothing`
retains the corresponding default. Other keywords pass through to the solver
backend, which determines whether they are supported.
"""
function simulation_options(defaults::NamedTuple=NamedTuple(); kwargs...)
    overrides = (; (key => value for (key, value) in pairs(kwargs)
        if !(key in (:abstol, :reltol) && value === nothing))...)
    options = merge(defaults, overrides)
    steady_state = get(options, :ss_options, SteadyStateOptions())
    steady_state isa SteadyStateOptions ||
        throw(ArgumentError("ss_options must be a SimKit.SteadyStateOptions value"))
    solver = (; (key => value for (key, value) in pairs(options) if key !== :ss_options)...)
    for name in (:abstol, :reltol)
        haskey(solver, name) || continue
        value = solver[name]
        value isa Real && isfinite(value) && value > 0 ||
            throw(ArgumentError("$name must be finite and positive"))
        solver = merge(solver, NamedTuple{(name,)}((Float64(value),)))
    end
    return (; solver, steady_state)
end
