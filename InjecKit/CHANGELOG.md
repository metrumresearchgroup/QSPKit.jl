# Changelog

All notable changes to InjecKit.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **ConfigKit-updated event solves**: `solve(updated, events, alg)` now detects when `updated` came from ConfigKit's update path and routes through a cached `PreparedEventSolve` keyed by the original problem, update keys, tspan, and event signature. Scientist-style scripts that update a problem first and solve with events now get the same prepared update/event path as SimKit without explicit runner setup.
- **Prepared update-event executor**: Added `PreparedEventSolve`, which composes ConfigKit's prepared update caches with InjecKit's event runner for a fixed problem/update/event shape. SimKit can now reuse the same executor instead of maintaining its own parameter/IC update orchestration around event plans.
- **Unified event plan cache**: IEvent and DataFrame event inputs now normalize through a single event-ingestion path and cache a validated `_EventPlan` with one of two execution strategies: callback plans for boluses, time-varying parameter changes, and existing-input infusions on an already-built problem; structural plans for state-targeted infusions that require one-time MTK system extension. Structural cache hits reuse the compiled extended problem and the resolved/expanded event schedule instead of re-normalizing, resolving, expanding, and splitting events every proposal.
- **Unified structural execution**: The old constructor-specific structural event path was removed. State-targeted infusions now use the same `_EventPlan` operation plan as `solve(prob, events, alg)` and SimKit runners, with callbacks stored on the returned SciML problem when the eventful constructor surface is used.
- **Initial-action merge order**: The internal event-plan helper used by SimKit now returns a solve plan containing only deferred start-time state actions after merging start-time parameter actions into the ConfigKit update. This lets dependent initial conditions rebuild before tspan-start boluses are added.
- **Cache validation**: Event-plan and extended-system caches now retain the actual base MTK system object and require identity on cache hits, preventing stale structural/callback plans from being reused if an object id is recycled for another system.
- **Event name normalization**: String and Symbol event references now share the same resolver path, including dotted strings such as `"model.C"` by resolving the final component (`"C"`) against the active MTK system. Cache signatures use the same canonical event names as variable resolution, so DataFrame and `ev()` syntax do not fragment event-plan reuse.
- **Solve-time event fast paths**: `solve(prob, events, alg)` now runs standard IEvent/DataFrame boluses, parameter changes, and existing-input infusions through ordinary SciML runtime callbacks over a remade problem. State-targeted infusions fall through to the structural event-plan strategy, which compiles the required hidden infusion parameter once and remakes the cached extended problem thereafter.
- **Threaded MTK code generation**: Eventful and cache-miss ODEProblem construction now uses QSPKitCore's shared symbolic-compilation lock around MTK/SymbolicUtils codegen, while keeping cache hits behind only InjecKit's cache lock. This avoids concurrent function-building races when InjecKit solves run beside other QSPKit threaded symbolic work.
- **t=0 boluses into parameter-dependent state initials**: Binding filtering during eventful ODEProblem construction now drops only runtime bound parameters, not state initials that appear in MTK bindings. Previously a t=0 bolus into a state with a parameter-dependent initial expression could be applied by `separate_t0_events` and then removed before the final ODEProblem was built.
- **Fresh t=0 event solves write final `u0` explicitly**: The full ODEProblem construction path now forces state initial values from the t=0-modified map after initialization-parameter synchronization, and writes both the solver `u0` vector and `Initial(state)` parameter. This prevents fresh event solves from leaving the final problem at stale defaults after a bolus event is applied to the initial-condition map.
- **t=0 event initialization order**: t=0 bolus events now reliably add on top of user-provided initial conditions. Previously, when the ODEProblem cache was primed, `remake()` updated `Initial(var)` in the parameter vector but not the solver's `u0` array, causing stale cached IC values to persist.
- **Name-aware u0/p merge**: Replaced `merge(sys_defaults, user_map)` with a name-aware merge that deduplicates by variable name. Prevents the system's default key object (e.g. `C(t)`) and the user's key (e.g. `C`) from coexisting as separate entries.
- **Multiple t=0 events to same compartment**: Fixed accumulation bug where the second t=0 bolus would overwrite the first instead of stacking additively.
- **System IC overrides**: The compiled system's `initial_conditions` now reflect t=0 event modifications, preventing stale defaults from winning after `complete()` namespaces variables.
- **Cache path key resolution**: Added `_resolve_keys_to_system()` so the fast `remake()` path properly matches user-provided variable keys to the cached system's variable objects.
- **Thread safety**: `solve(prob, df, ...)` is now thread-safe. Replaced MutableCacheKey caching with locked module-level LRU caches, and wrapped MTK/Symbolics operations in locks to prevent "concurrently resizing vectors" errors.

### Performance
- **Event ingestion**: Raw `IEvent`, `Vector{IEvent}`, and event DataFrame inputs now normalize through one internal event-ingestion representation with the stable signature used by InjecKit's shared LRU event-plan cache.
- **Runtime callback event plans**: Cached callback plans now execute through a general pre-indexed action-group callback for all event schedules, avoiding per-trigger event-plan dictionary traversal without relying on single-event special cases.
- **Structural problem caching**: State-targeted infusions cache the extended system/problem layout once and execute through the same shared callback-compatible event plan as non-structural event schedules. Repeated solves reuse the compiled layout and update numeric parameters/initials through SymbolicIndexingInterface buffers instead of rebuilding MTK eventful systems.

### Added
- **New exports**: `expand_repeated_events` and `get_infusion_parameters` are now exported for advanced usage patterns

### Changed
- **Standardized MTK alias**: Migrated from `ModelingToolkit` to `ModelingToolkitBase` with `const MTK = ModelingToolkitBase` alias. All source files now use the `MTK.` prefix consistently.
- **Exported MTK alias**: Added `MTK` to public exports so test files and downstream users can access the alias directly via `using InjecKit`.

### Fixed
- **Documentation alignment with implementation**:
  - Removed references to non-existent internal functions from api.md (`_add_infusion_to_system`, `_create_unique_infusion_param`, `_validate_existing_parameter`, `_is_continuous_infusion`, `_create_infusion_callbacks`, `create_events`, `create_callbacks_from_events`, `_process_continuous_infusions`)
  - Updated api.md Internal Functions section with accurate function names
  - Updated getting_started.md examples to use preferred 4-argument `ODEProblem` constructor instead of deprecated 5-argument form

### Breaking (from earlier unreleased changes)
- **Breaking:** Renamed package from MRGEvents to InjecKit
- **Breaking:** Renamed `MRGEvent` struct to `IEvent` throughout the codebase
- **Breaking:** Requires ModelingToolkit.jl v11.0+ (previously v9.0+)
- Updated all documentation to use MTK v11 patterns (`@mtkcompile`, `System`)
- Time-dependent parameters must now be declared with `@discretes` macro instead of `@parameters X(t)`

### Removed
- Removed `parameter_dependency_checking.jl` - obsolete for MTK v11 since default value dependencies are substituted at compile time

### Fixed
- Fixed t=0 event handling when state variables are defined via bindings (e.g., `T_cell => total_T_cells_init`)
- Fixed system extension with events by manually constructing new system with `checks=false` instead of using `MTK.extend()` which re-introduces bindings as equations. Uses `complete()` instead of `mtkcompile()` to avoid InitializationProblem failures on parameter bindings. This properly handles systems with parameter bindings (e.g., `k_growth => expr`)
- Fixed parameter binding substitution for binding-only parameters (like `k_growth => 0.693/T_doubling`) that are not in the params list. These are now correctly identified and substituted into equations by checking if bindings are NOT state variables, rather than checking if they ARE in the params list. Bindings are preserved when creating extended systems for infusion parameters.
- Added validation to reject events that try to modify computed/dependent parameters in bindings (e.g., `k_growth => expr`)
- Fixed variable matching in `simple_t0_update!` to use name-based comparison for robust matching across different symbolic types
- Bindings are now properly merged into u0_p_map for matching and filtered before passing to ODEProblem
- Fixed MTK warnings about `Pre` operator by adding `discrete_parameters` to SymbolicDiscreteCallback calls
- Fixed compatibility with ModelingToolkit.jl v11 API changes:
  - `ModelingToolkit.defaults` replaced with `ModelingToolkit.get_initial_conditions`
  - `@parameters X(t)` replaced with `@discretes X(t)` for time-dependent parameters
  - `Symbolics.Symbolic` type replaced with `Set{Any}` for compatibility with SymbolicUtils v4+
  - Time-dependent parameter detection now uses `VariableSource` metadata check for `:discretes`
  - `Symbolics.value()` used for extracting numeric values from symbolic expressions
- Fixed infusion parameter creation to use `@discretes` with `[input=true]` metadata

### Added
- Export `IEvent` type from main module
- Improved error messages for time-dependent parameter validation
- Comprehensive test coverage improvements:
  - `test_plotting.jl`: Tests for `plot_infusion_history()` function
  - `test_empty_edge_cases.jl`: Tests for empty DataFrames, empty event vectors, zero amounts, edge cases
  - `test_helper_functions.jl`: Unit tests for internal helpers (`missing_to_nothing`, `is_bolus_dose`, `is_infusion`, `calculate_infusion_parameters`, etc.)
  - `test_complex_infusions.jl`: Tests for sequential/adjacent infusions, multi-compartment scenarios, large event datasets
  - `test_error_handling.jl`: Tests for validation errors, invalid inputs, error messages

## [1.0.0-DEV] - Initial Development

### Added
- Multiple input formats: DataFrames (NONMEM-style), IEvent vectors (mrgsolve-style), and SymbolicDiscreteCallbacks
- Flexible dosing: Bolus doses, continuous infusions (rate-based or duration-based), and mixed dosing regimens
- Parameter changes: Time-varying parameter updates with dependency validation
- Repeated dosing: Support for `ii` (interdose interval) and `addl` (additional doses)
- Simultaneous events: Handle multiple events at the same time point
- Automatic validation: Input metadata validation for infusion parameters
- Performance optimized: Batched event processing for efficient handling of large datasets
- `ev()` function for creating events with mrgsolve-like syntax
- Automatic infusion parameter creation with unique naming via `gensym()`
- Parameter change callbacks for time-varying parameters
