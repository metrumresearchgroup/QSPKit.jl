# TargKit

TargKit is the calibration-target and fitting layer of QSPKit. It provides:

- `targets` and `TargetSet` for DataFrame-based observations;
- `score` for comparing one or more target tables with simulation results;
- `objective` for constructing a reusable optimization objective;
- `fit` and `Stage` for bounded staged optimization; and
- `setup`, `FitStep`, `FitPipeline`, and `finish` for composable fitting.

The simulation function and prediction mapping are supplied by the caller.
TargKit does not own an ODE model or solver runtime.

## Target table schema

Every target table has `name` and `value` columns. Optional `lower`, `upper`,
`weight`, and `loss` columns control range checks and scoring. `TargetSet`
also understands role columns such as `condition`, `variable`, and
`timepoint`, including wide-to-long conversion.

Built-in losses are `:log`, `:squared`, `:series_log`, `:series_mse`, and
`:range_only`. A loss may instead be a function of `(predicted, observed,
weight)`.

Scoring is strict: non-finite values, nonpositive log inputs, malformed series,
missing convention lookup sources, and missing bounds required by
`:range_only` raise descriptive errors with target and series-index context.
They are never converted to ordinary target-loss penalties.

## Package boundaries

ConfigKit is used only when a fitting pipeline asks a keyfile for parameter
values or bounds. QSPKitCore provides the shared symbolic-compilation lock.
TargKit does not depend on SimKit, BookKit, or retired population/sampler
packages.
