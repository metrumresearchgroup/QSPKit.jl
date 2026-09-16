# Changelog — TargKit

All notable changes to TargKit will be documented in this file.

## [Unreleased]

### Added
- **`FitResult.source_fp`**: `fit()` now attaches a per-method source fingerprint of the objective closure (a combined SHA-256 over the lowered ASTs of the user/dev code the objective transitively reaches) to the result, so provenance tooling can detect code-change staleness of a fit. Computed by a vendored, self-contained `_SourceFP` module (SHA-only — no provenance-package dependency). A back-compatible 5-arg `FitResult` constructor keeps existing construction working (`source_fp` defaults to `nothing`).
- **Objective parameter scale**: `objective(...; parameter_scale=:identity)` builds objectives that accept natural-scale parameter vectors directly. The existing log-scale behavior remains the default with `parameter_scale=:log`.
- **Series target convention prediction**: TargetSets whose values are `(t=..., y=...)` now keep vector predictions from `sim[condition][variable]` and can evaluate solution-like results as `sim[condition](value.t; idxs=variable)`, avoiding custom predictors for ordinary ODE curve targets.
- **`where(ts, :col => val)` filter**: Subset TargetSet rows by column value. Supports scalar and vector matching, plus curried form for piping: `ts |> where(:condition => :mepolizumab)`.

### Fixed
- **`FitResult.converged` now reflects the optimizer retcode**: it was `best_loss < Inf` (always true for any finite-loss fit). `_run_stage` now records whether the winning restart returned `Optimization.ReturnCode.Success`, so `converged` is a real convergence signal — and downstream auto-status (e.g. BookKit's `book_extract(::FitResult)`) no longer marks non-converged fits `:accepted`.
- **Source fingerprinting cannot destroy a completed fit**: the `_SourceFP.combined_fingerprint` call that populates `FitResult.source_fp` is guarded in `fit()`; on failure it logs and falls back to `source_fp=nothing` rather than throwing away the optimization result.
- TargetSet objectives without custom predictors now use a prepared convention-scoring plan over column arrays and a fixed series-target subplan for standard ODE curve targets. This removes `DataFrameRow` convention probing, repeated row-shape checks, and prediction-vector allocation from the ordinary ODE curve objective hot path, including for SciML solutions that are themselves array-like.
- TargetSet objective evaluations now pass fixed-key `NamedTuple` overrides for any number of fitted parameters and precompute observed logs for prepared series targets, removing proposal-time override `Dict` construction, SimKit key sorting, and fixed-data log work from eventful ODE target loops.
- Objective simulation exceptions now propagate instead of being caught and converted to the configured failure penalty. Returning `nothing` from `simulate` remains the explicit penalty signal.
- Solution observed-function lookup is cached per ODE function/variable after the first retrieval, avoiding repeated observed-function discovery and compile-lock entry while scoring repeated targets.
- Observed-function cache entries now retain and validate the actual ODE function object on cache hits, preventing stale observed-function reuse if Julia recycles an object id for another compiled model.
- Objectives now skip progress-counter locking and parameter-dict construction when `on_eval=nothing`, removing unnecessary serial work from threaded proposal loops that do not request evaluation callbacks.
- Solution-like convention prediction now obtains MTK observed functions through `SymbolicIndexingInterface.observed` under QSPKitCore's shared symbolic-compilation lock and evaluates them directly from `sol(t)`, avoiding repeated `sol(...; idxs=observed_var)` cache access during threaded objective scoring and coordinating with InjecKit's threaded ODEProblem construction.
- Objective progress state is now lock-protected and simulation failures are logged with their exception before returning the configured failure penalty.
- Series-valued convention prediction now evaluates solution-like condition results before trying property lookup, so ODE solutions that return `NaN` for unknown properties still use `sol(value.t; idxs=variable)`.
- `TargetSet(...; role = :col => Dict(...))` now preserves mapped values exactly instead of coercing non-symbol objects to `Symbol(v)`, allowing recodes to MTK variables for solution indexing.
- `objective(ts; ...)` now uses the TargetSet loss when `loss` is not explicitly supplied, so series-valued targets auto-select `:series_log` inside objectives.

## [0.4.0] — 2026-03-18

### Added
- `TargetSet` Pair syntax constructor: `:col`, `:col => fn`, `:col => Dict(...)` for column role declarations
- Wide format pivot support via `targets` kwarg
- Convention-based prediction in `score(ts; sim=sims)` — auto-extracts from `:condition`/`:variable` columns
- Custom predict escape hatch: `score(ts; sim=sims, predict=fn)`
- `score(ts::TargetSet...; sim, predict)` — score TargetSets against simulation results
- `fit(ts::TargetSet...; simulate, predict, params, bounds, strategy)` — fit TargetSets
- `objective(ts::TargetSet...; simulate, predict, params, bounds)` — build objective from TargetSets

### Changed
- `TargetSet` is now a pure data container (no predict function stored)
- Sim→data mapping happens at `score()`/`fit()` time, not construction time
- Extracted all yspec parsing code into standalone [YspecJL](https://github.com/knabt/YspecJL) package
- Removed CondaR, YAML dependencies (moved to YspecJL)

### Removed
- v3 yspec-path TargetSet constructors (`TargetSet("spec.yml", "data.csv"; ...)`)
- `load_yspec`, `namespace`, `decodes`, `lookup_source` (moved to YspecJL)
- `YspecMetadata`, `ColumnSpec` types (moved to YspecJL)
- `r_available()` (moved to YspecJL)

## [0.3.0]

### Added
- yspec-compatible target specification system with RCall + native backends
- `TargetSet` wrapping DataFrame + YspecMetadata + predict function
- Native YAML parser for yspec files
- RCall backend for yspec via CondaR
- `load_yspec`, `validate`, `namespace`, `filter_flags`, `decodes`, `lookup_source`

## [0.2.0]

### Added
- DataFrame-based targets with pluggable optimization pipelines
- `targets()` convenience constructor
- `score()`, `objective()`, `fit()` with Stage pipeline
- `fingerprint()` for deterministic target hashing
