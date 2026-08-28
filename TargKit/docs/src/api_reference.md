# API reference

## Targets and scoring

```@docs
targets
TargetSet
validate
where
filter_flags
fingerprint
score
ScoreReport
```

## Objectives and fitting

```@docs
objective
reset!
Stage
fit
FitResult
setup
finish
inspect_fit
score_fit
checkpoint
FitState
StageResult
FitStep
FitPipeline
```

The predefined pipeline values are `PSO_NM`, `NM_ONLY`, and `LBFGS_ONLY`.

## Error and penalty policy

`score` and ordinary objective evaluation reject invalid numeric values and
unresolved prediction sources. Errors identify the target and, for series,
the failing index. Synthetic objective values are reserved for two explicit
controls: `simulate` returning `nothing` uses `failure_penalty`, and an enabled
`bounds_penalty` short-circuits out-of-bounds parameter vectors.

For convenient target-table construction, TargKit re-exports `DataFrame`,
`nrow`, `eachrow`, `groupby`, `innerjoin`, `leftjoin`, and `CSV`. It also
re-exports the DataFramesMeta macros `@chain`, `@rsubset`, `@rtransform`,
`@rselect`, `@select`, `@transform`, `@subset`, `@combine`, `@by`, `@rename`,
`@orderby`, and `@groupby`, plus the Optimization solver constructors
`ParticleSwarm`, `NelderMead`, and `LBFGS`.
