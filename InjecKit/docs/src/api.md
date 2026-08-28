# API reference

## Events and problem construction

```@docs
IEvent
ev
setevent
expand_repeated_events
get_infusion_parameters
```

InjecKit extends `ODEProblem` and `solve` for ModelingToolkit-backed problems
with event vectors, event tables, and symbolic discrete callbacks.
`InjecKit.MTK` is the package's re-exported alias for `ModelingToolkitBase`.

## Regimen composition

The documented regimen constructors and combinators are collected on the
[Event composition](event_composition.md) page.

## Prepared execution

```@docs
EventRunner
PreparedEventSolve
solve_event_runner
with_prepared_event_problem
with_prepared_event_solve
with_prepared_active_tunable_sensitivity_problem
tunable_parameter_index
```

The prepared-execution surface is public for integration authors. The
`with_prepared_*` functions lend temporary problems and buffers to a callback;
do not retain or mutate those borrowed values after the callback returns.
