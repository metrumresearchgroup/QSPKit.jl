# Periodic steady-state simulation

Specify a dose with `SS=1` and a positive `II`. SimKit advances repeated dosing
internally, then simulates the requested observations from the converged state.
Observation times stay on the original time axis. The first forward dose is
applied once; `ADDL` doses continue the regimen without resetting it again.

For a population DataFrame:

```julia
population = Population(events; time=:TIME, evid=:EVID, amt=:AMT, cmt=:CMT,
    parameters=[:BW, :AGE], steady_state=:converge)
profiles = simulate_profiles(result; data=population, draw=1, eta=:sample, rng=rng,
    ss_options=SteadyStateOptions(reltol=1e-5))
```

`simulate_profiles` is the BayesKit interface. It keeps each subject's individual
parameters fixed throughout advancement and returns states, predictions, and
`steady_state.cycles` / `steady_state.error`. Use `eta=:sample` to sample
new virtual subjects in BayesKit. Each profile also returns the population
`theta` and individual `eta` used in its simulation. Those ETAs can be reused
as columns of an explicit matrix for comparisons across regimens. No residual
noise is added.
Its named keywords select `data`, `draw`, `eta`, and `rng`; numerical keywords pass
through `kwargs...` to SimKit's `simulation_options`. That helper separates
`ss_options` from ODE solver settings and validates the tolerances. ODE
`abstol` and `reltol` default to the fitted settings, and overrides apply only
to the simulation call. Other keywords are passed to the solver backend;
supported keywords depend on that backend.
SimKit's ordinary `simulate` pipeline also handles staged `SS=1` events and
accepts `ss_options`. The lower-level `steady_state_solution` returns the ODE
solution together with convergence diagnostics.

The convergence rule checks every state at the end of each interval and, for
an infusion, at the end of infusion. Each checkpoint must satisfy
`abs(current - previous) ≤ abstol + reltol * abs(current)` across successive
cycles. Defaults are `abstol=1e-8`, `reltol=1e-6`, at least 10 cycles and at most
10,000 cycles. These are steady-state tolerances, independent of ODE solver
tolerances. Absolute tolerance uses the state variables' units. A failed solve,
non-finite state, or failure to converge raises an error.

The model's initial state is the starting guess. Endogenous production and all
model compartments remain part of the ODE. The model must be autonomous or
periodic with the dosing interval. A loading regimen is unnecessary when
calculating the periodic maintenance steady state.

Supported: one `SS=1` dose at the start, bolus or finite infusion shorter than
`II`, followed by ordinary forward events. Unsupported forms are rejected:
`SS=2`, later steady-state resets, simultaneous events at the initial SS dose,
overlapping or constant infusions, and model-defined negative RATE codes.
Custom callbacks and custom `tstops` are not accepted during SS advancement.

SS convergence is a simulation feature. Sensitivities through the periodic
fixed point are not implemented for inference; BayesKit rejects unexpanded SS
records for fitting. In this report's vendored SimKit, `Population` retains its
existing default `steady_state=:history` (ten prior doses) to preserve the data
preparation used for the completed fit. Use `steady_state=:converge` explicitly
for this feature. The development repo already preserved SS records by default
and continues to do so. Saved fits and model files are not rewritten.
