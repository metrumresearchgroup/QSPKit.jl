# Changelog

## Unreleased

- Added a keyword form of `scan` that needs no pipeline body:
  `scan(prob, :dose => doses; events = p -> ev(cmt=:Depot, amt=p.dose), duration=72.0)`.
  Swept model parameters and states are staged with `with`; other swept values
  are passed only to the `events` function. Remaining keywords go to `simulate`.
- Exported `scan` from the root `QSPKit` module.
- Added `print_every = N` to TargKit `fit`, `setup`, and `objective`. It prints
  a status line every `N` objective evaluations in every fit stage and restart,
  with the eval count, stage label, current and best loss, and elapsed time:
  `[eval 400 | stage 1: ParticleSwarm restart 2/3] loss=0.8123 best=0.7011 (12.3s)`.
- Added `match` and `at` to TargKit `TargetSet`, which match target rows to
  simulation output like a join. `match` names the target columns that pick a
  simulation (dose, donor, arm). `at` picks the point along one axis, either a
  target column (`:TIME`, `:TIME_hr => :TIME`) or a constant (`:TIME => 672.0`).
  The observed column's name is the simulated variable, or name it with
  `value = :obs => :simvar`. `simulate` may return a DataFrame, an ODE solution,
  a SimKit scan result or `SimContext`, or a Dict. Each target must match
  exactly one simulation point, otherwise a `TargKit.MatchError` explains the
  mismatch before optimization starts. Values between saved points are not
  interpolated, and a target at a dose time is an error. Design:
  `TargKit/docs/matching.md`.
- Deprecated the TargKit `condition` and `timepoint` keywords in favor of
  `match` and `at`. They keep working unchanged.
- TargKit `TargetSet` role keywords that name a missing column, or that would
  rename a column onto an existing one, are now errors instead of being
  silently ignored.
- Fixed the first ShowKit R call in a session logging `Precompiled image RCall
  not available` while loading `SciMLBaseRCallExt`. CondaR now precompiles
  RCall for the selected R environment before importing it. Julia's loader had
  been loading RCall from source because RCall's source contains a conditional
  `__precompile__(false)`, leaving the extension no cache image to build against.

## QSPKit 0.1.0 — 2026-09-17

- Introduced QSPKit as one installable and versioned Julia package.
- Organized the retained domain APIs as public `QSPKit.<Component>` submodules.
- Added a curated root export surface for common configuration, dosing, and
  simulation workflows.
- Unified package testing under `Pkg.test("QSPKit")`.
- Retained component-level validation, coverage, documentation, and differential
  execution caching as internal qualification details.
- Published one aggregate QSPKit scorecard and one deterministic source tarball.
