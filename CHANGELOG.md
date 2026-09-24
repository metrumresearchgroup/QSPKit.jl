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
- Added matching of TargKit targets to simulation output, declared where a
  TargetSet meets a simulation: `fit`, `setup`, `objective`, and `score` take
  `match`, `at`, and `variable`, or pair each TargetSet with its own
  `Match(...)`: `fit(pk => Match(:dose; at = :TIME, variable = :Conc), ...)`.
  `match` names the target columns that pick a simulation (dose, donor, arm).
  `at` picks the point along one axis, either a target column (`:TIME`,
  `:TIME_hr => :TIME`) or a constant (`:TIME => 48.0`). `variable` names the
  simulated variable, or translates a TargetSet `variable` column with a Dict.
  `simulate` may return a DataFrame, an ODE solution, a SimKit scan result or
  `SimContext`, or a Dict. Each target must match exactly one simulation point,
  otherwise a `TargKit.MatchError` explains the mismatch before optimization
  starts. Values between saved points are not interpolated, and a target at a
  dose time is an error. Design: `TargKit/docs/matching.md`.
- Removed the TargKit `condition` and `timepoint` keywords and the implicit
  prediction lookup (`sim[condition][variable]`, `sim[target name]`). A
  TargetSet holds only observed data; `fit`, `setup`, `objective`, and `score`
  need `match`/`at`/`variable` or a `predict` function, and raise an error
  without one instead of silently scoring every target with a penalty.
- Added optimizer options to TargKit fit stages:
  `fit(NelderMead(); maxiters = 5, local_maxiters = 500, g_abstol = 1e-6)`, and
  the same keywords on `Stage`. NelderMead and LBFGS run inside Optim's
  `Fminbox`, so `maxiters` counts outer iterations and `local_maxiters` the
  inner iterations of each (default 1000); tolerances are Optim's `g_abstol`,
  `f_reltol`, `f_abstol`, `x_abstol`, `x_reltol`, and their `outer_*` versions.
  ParticleSwarm has no convergence test and takes only `maxtime` and
  `f_calls_limit`. Options a stage would not use are an error when the stage is
  built.
- Fixed TargKit `fit` and `setup` ignoring a TargetSet's `loss` (they passed
  `:log` down). Each TargetSet's rows now use its own loss; `loss = ...` on the
  call overrides them all.
- Fixed TargKit `score` and the `fit` report failing when TargetSets have
  different columns; their rows now stack with `missing` in the gaps.
- TargKit `TargetSet` role keywords that name a missing column, or that would
  rename a column onto an existing one, are now errors instead of being
  silently ignored.
- ShowKit `mrggsave` and `mrggsave_list` now write PNG files with R's headless
  Cairo device (`type = "cairo-png"`) unless `type` is passed, so PNG output
  works on Linux machines without an X11 display.
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
