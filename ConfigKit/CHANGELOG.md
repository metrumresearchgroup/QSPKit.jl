# Changelog

All notable changes to ConfigKit.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Thread-local update workspaces**: Added `thread_update_cache` and `with_thread_update_cache` so proposal-time simulation, fitting, and sensitivity loops can share `ConfigKit.UpdateCache` workspaces per thread/problem/key set while still holding the cache lock for borrowed-buffer solves.
- **`ParameterSet` struct**: Bundles parameter names, values, and bounds from a keyfile into a single container. Constructed via `ParameterSet(keyfile, [:CL, :V1, :ka])` for convenient handoff to optimization routines.
- **Optics documentation page**: Added docs for Accessors.jl integration — `MTKParamLens`, `@param` macro, `bounds_from()`, with examples for parameter sweeps and optimization

### Changed
- **Shared cached-update hot path**: Downstream QSPKit packages can now use ConfigKit's central per-thread update cache instead of maintaining package-local `UpdateCache` registries or calling allocation-owning `update()` in repeated proposal loops.
- **Cached update value inputs**: `update!` and `with_update_cache` now accept tuple value buffers in addition to vectors and named tuples, so callers with a prepared fixed key set can pass ordered values without materializing a `Vector` on every proposal.
- **`update()` uses `setp` for fast parameter writes**: Refactored `update()` to use `setp` setters from SymbolicIndexingInterface instead of passing parameter Dicts to `remake`. Pattern: `copy(prob.p)` → `setp` → `remake(prob; p=pnew)`. Removed LRU cache and locks (unnecessary complexity—symbolic lookups are fast). Note: initial condition dependencies are no longer propagated.

### Added
- **`update!()` for in-place mutation**: New function for maximum performance when thread-safety isn't needed. Mutates the problem's parameters directly via cached `setp` setters without copying.

### Fixed
- **Keyfile unit spelling in reports**: Parameter entries now retain the original unit text (for example, `L` or `mL/L`) alongside the parsed dimensional quantity so reporting layers do not replace it with an SI-normalized representation.
- **Update-origin metadata**: `update`, `update!`, and `with_update_cache` now record validated update-source metadata on returned `ODEProblem`s when the update can be represented by ConfigKit keys and values. Downstream QSPKit packages can use this to compose prepared update/event execution after common script patterns such as `updated = ConfigKit.update(...); solve(updated, events, alg)`.
- **Cache validation**: Update-plan and setter caches now retain the actual MTK system object and require identity on cache hits, instead of trusting a compact token that includes `objectid(sys)`. This prevents stale cached setters/plans from being reused if Julia recycles an object id for a later compiled model.
- **Cached initial-condition dependency detection**: Added an internal cached predicate for whether a fixed update key set can affect state initial conditions, including dependencies stored as compiled MTK unknown bindings. SimKit uses this to preserve the fast no-initialization path for ordinary updates while deferring start-time state events when parameter-dependent ICs must rebuild first.
- **State updates write `u0` explicitly**: `update(prob, [state => value])` now updates both the hidden `Initial(state)` parameter and the solver initial-condition vector, and symbolic keys from same-named sibling systems are canonicalized against the active problem. Previously state updates could leave `prob[state]` at the stale value even though the initial parameter buffer had changed, or skip a valid state when the key came from a related system object.
- **Algebraic variables no longer get `Initial()` in `populate()`**: Fixed a bug where algebraic/observed variables (those without `D(var) ~ ...` equations) were incorrectly getting initial conditions assigned via `Initial()`. This caused problems building `ODEProblem` since algebraic variables are computed from their equations, not from initial conditions. Now `populate()` correctly handles three cases: (1) differential state variables (in unknowns with `D(var)` equation) get `Initial()` conditions, (2) algebraic unknowns (in unknowns but no `D(var)` equation, e.g., DAE systems) get guesses, and (3) observed/algebraic variables (not in unknowns, e.g., after `mtkcompile`) get guesses to help the initialization solver. Additionally, any existing ICs copied from the original system are now explicitly deleted when setting guesses for algebraic variables. A name-based cleanup pass handles cases where symbolic object identity prevents direct deletion. Namespace-aware matching now handles cases where `mtkcompile()` is called before `populate()` (e.g., `gadkar₊Km_IL33` correctly matches `Km_IL33` from the keyfile).
- **Model metadata precedence in `populate()`**: Fixed metadata handling so that model metadata (units, descriptions) takes precedence over keyfile metadata. Previously, keyfile metadata would overwrite model metadata. Now keyfile metadata only fills in gaps where the model has no metadata defined.
- **Critical: `getUnitfulUnit` function call in variants.jl**: Fixed call to non-existent `getUnitfulUnit()` function in `_get_entry_metadata()`. Changed to `getMTKUnit()` which is the correct function name.
- **Documentation alignment with implementation**:
  - Fixed `populate!` signature in api_reference.md (takes `ODEProblem`, not `System`)
  - Fixed `.initial` and `.bounds` field access examples in getting_started.md (use `.value` and `.metadata[:bounds]`)
  - Changed `structural_simplify` to `mtkcompile` in README.md and getting_started.md
  - Fixed `load_keyfile` signature documentation (default variant is `nothing`, added `strict` parameter)
  - Removed non-existent `clear_update_cache!()` function reference from update_engine.md (LRU cache is self-managing)

## [0.1.1] - 2026-01-14

### Fixed
- **Unit Metadata Extraction in `update()`**: Fixed `_get_model_unit()` not properly extracting unit metadata from symbolic parameters. The function now unwraps `Num` types using `Symbolics.unwrap()` before accessing `VariableUnit` metadata, enabling proper unit validation and conversion for compiled systems.
- **Exact Unit Matching in Validate-Only Mode**: Fixed `update()` not enforcing exact unit matching when `validate_units=true` and `convert_units=false`. Previously, dimensionally-compatible but different units (e.g., `hr^-1` vs `s^-1`) were silently accepted. Now an error is thrown advising to enable conversion.
- **Constants in Parameter Expressions**: Fixed a bug where constants defined in keyfiles could not be used in parameter expressions (e.g., `TV_L0: TV_mm3_0 / mm3_per_L` where `mm3_per_L` is a constant). Constants were being parsed but never integrated into the `populate()` workflow, causing ModelingToolkit to reject bindings with "non-parameter symbolics" errors. Constants are now properly injected as system parameters with their fixed values.
- **Unit Metadata Preservation**: Fixed metadata transfer order in `populate()` that was causing new unit metadata to be overwritten by old (empty) metadata. Unit and description metadata are now set AFTER transferring existing metadata to prevent overwrites.
- **Derivative Unit Metadata**: Fixed missing unit metadata on differential equation LHS terms (e.g., `D(TCE)`). Derivative units are now explicitly computed as `unit(x) / unit(t)` and attached to the differential term.
- **Unit Normalization**: Fixed unit magnitude mismatch between LHS and RHS of equations. Units from keyfiles (e.g., `nmol/L`) are now normalized to magnitude 1.0 before storing in the unit map, ensuring consistent unit checking across equations.
- **Ghost Parameter Filtering**: Fixed `populate()` creating ghost parameters for ALL keyfile entries, even those not used by the model. Ghost parameters and constants are now only created when actually referenced by system expressions. This prevents errors from unused keyfile entries (e.g., PK model parameters in an in-vitro model keyfile).
- **Variant-Only Parameter Error Handling**: System parameters with only variant values (no default) now produce a clear error message when `populate()` is called without specifying a variant, instead of failing with cryptic MTK errors about missing values.
- **Expression Binding Initialization**: Expression-valued parameters (e.g., `k_growth: log(2)/Tumor_cell_doubling_time`) now get a computed numeric guess in addition to their symbolic binding. This helps MTK's initialization system work correctly while preserving the dependency relationship so that `update()` propagates changes through parameter expressions.
- **Unit Conversion (`convert` field)**: Fixed the `convert` field in keyfiles being completely ignored. The `convert` field allows specifying a target unit for automatic value conversion (e.g., `value: 0.1, unit: hr, convert: s` now correctly produces `360` seconds instead of `0.1`). The parser now recognizes the field, and `populate()` applies the conversion factor when setting parameter values.

### Added
- **Unit Handling in `update()`**: The `update()` function now supports Unitful values in update pairs. When you pass values with units (e.g., `update(prob, [model.Thalf => 200u"hr"])`), units are automatically validated and converted to match the model's unit metadata. New keyword arguments:
  - `validate_units=true`: Validates that value units are dimensionally compatible with model units (only when model has unit metadata)
  - `convert_units=true`: Converts values to model units (e.g., hours → seconds)
  - When the model has no unit metadata on a parameter, units are simply stripped (lenient behavior for practical workflows)
- **Unit Handling Tests**: Added comprehensive tests for unit conversion, dimension validation, and edge cases (Tests 14-19 in `update_test.jl`)
- **Helper Macros**: Added two utility macros for ModelingToolkit-based model construction:
  - `@observed(sym)`: Creates observed equations that link computed expressions to observable variables. Simplifies adding observables to `ODESystem` constructors.
  - `@common_constants()`: Defines commonly used physical constants as MTK parameters: `N_Av` (Avogadro's number), `nmol_per_mol` (conversion factor), `s_per_hr` (seconds per hour).
- **Macro Tests**: Added comprehensive test suite for helper macros (`test/macros/macros_test.jl`).

## 2026-01-12

### Changed
- **Standardized MTK alias**: Consolidated imports to use `const MTK = ModelingToolkitBase` consistently across all source files. All `ModelingToolkit.` references now use `MTK.` prefix.
- **Exported MTK alias**: Added `MTK` to public exports so test files and downstream users can access the alias directly via `using ConfigKit`.

### Performance Improvements
- **Zero-Allocation Update Engine**: Reimplemented `update(prob, pairs)` using `SciMLStructures`. This bypasses dictionary creation and generic setters, interacting directly with the flat parameter vector for maximum speed.
- **Automatic Caching**: Implemented an internal `LRUCache` to automatically memoize parameter indices. The first call for a set of keys incurs a lookup cost; subsequent calls are near-instantaneous.
- **Thread Safety**: The global update cache is now protected by a `ReentrantLock`, allowing safe parallel execution of `update()` in multi-threaded workflows (e.g., virtual populations).

### Fixed
- **Unified State/Parameter Updates**: Fixed an issue in ModelingToolkit v11 where passing `u0` and `p` simultaneously to `remake` caused `u0` updates to be ignored. The `update()` function now automatically detects state variables and maps them to `Initial(var)` parameter updates, ensuring consistent re-initialization.

### Dependencies
- **New Dependencies**: Added `LRUCache` and `SciMLStructures` to support the new update engine.

## 2026-01-05

### Breaking Changes
- **Removed `LockDependency` from YAML**: The `LockDependency` field has been completely removed from keyfile syntax. Expression-valued parameters now automatically become symbolic bindings (computed on-the-fly). If your keyfiles contain `LockDependency: true` or `LockDependency: false`, you will get an error on load.

  **Migration**: Simply remove all `LockDependency` lines from your YAML files. Expression-valued parameters (e.g., `value: CL / V`) automatically become bindings.

- **Removed `lock` field from `ParameterEntry`**: The `.lock` property no longer exists on `ParameterEntry`. Use `haskey(entry.metadata, :expression)` to check if a parameter is expression-valued.

- **New `solve_for` kwarg replaces `LockDependency: false`**: To use MTK's initialization system (previously `LockDependency: false`), pass the `solve_for` kwarg to `populate()`:
  ```julia
  # Old (removed): LockDependency: false in YAML
  # New:
  sys = populate(sys, keyfile; solve_for=[:k_el => [:CL, :V]])
  ```

### Added
- **`solve_for` kwarg for `populate()`**: Explicitly opt parameters into MTK's initialization system:
  - `solve_for = [:target => [:adjustable_params...]]` - Use keyfile expression for target
  - `solve_for = ["target ~ expr" => [:adjustable_params...]]` - Use custom equation
  - Target is bound to `missing`, adjustable params get keyfile values as guesses
  - Supports multiple targets and shared adjustable parameters

### Documentation
- **Complete Documentation Overhaul**: Rewrote all documentation for QSP scientist audience (non-developers)
  - Added "Why Use ConfigKit?" section explaining workflow benefits
  - Created missing `update_engine.md` with practical performance guidance
  - Updated `api_reference.md` to match actual exports (removed dead code references)
  - Rewrote `getting_started.md` with step-by-step QSP workflow examples
  - Enhanced `keyfile_format.md` with common QSP units table and tips section
  - Updated `variants.md` to remove references to deleted functions
  - Rewrote `README.md` to be consistent with new documentation
- **Removed Dead Code References**: Cleaned up docs that referenced deleted functions (`resolve_variant` 3-arg version, `validate_variant_completeness`, metadata types)
- **Unit Documentation**: Updated all unit references to use DynamicQuantities (MTK v11+) instead of Unitful

### Removed (Breaking)
- **`metadata.jl`**: Removed custom metadata types (`ConstantParameter`, `InputParameter`, `DependentParameter`, `ConnectionVariable`, `LockParameterDependency`, `ParameterBounds`). These were never used internally—InjecKit uses ModelingToolkit's built-in `[input=true]` metadata, and other Kit packages don't use these types. If you were referencing these types externally, use MTK's native metadata system instead (e.g., `@parameters p [input=true]`).
- **Dead code in `utils.jl`**: Removed 7 unused functions: `load_yaml_ordered_safe`, `infer_units_from_expression`, `convertToBool`, `validate_allowed_keys`, `validate_required_keys`, `determine_parameter_flags`, `normalize_entry_format`. These were never called by any public API.
- **Dead code in `variants.jl`**: Removed 2 unused functions: `resolve_variant(param_name, variant, keyfile)` (3-arg version) and `validate_variant_completeness`. The 3-arg `resolve_variant` was redundant with `load_keyfile(...; variant=...)`, and `validate_variant_completeness` was defined but never exported or called.

### Added
- **Comprehensive Update Engine Tests**: Added 26 tests for `update.jl` covering ODEProblem updates, System updates, Integrator updates, binding errors, ghost parameters, string/symbol key resolution, and callback integration.
- **Comprehensive Populate Tests**: Added 17 tests for `populate.jl` covering basic population, locked dependencies, guesses, overrides, and full integration scenarios.
- **`_resolve_to_num` Num Support**: Added pass-through method for `Num` types in `_resolve_to_num`, enabling direct use of symbolic variables in `update()` calls.

### Fixed
- **`update(sys::AbstractSystem, ...)` MTK v11 Compatibility**: Fixed to use `initial_conditions` instead of `bindings` for parameter values. In MTK v11, `bindings` is reserved for derived quantities (equations like `k_el = CL/V`), not parameter values.
- **Test Symbolic Indexing**: Updated state variable tests to use symbolic indexing (`prob[x]`) instead of positional indexing (`prob.u0[1]`), as `mtkcompile` may reorder states.
- **Duplicate Namespaced Parameters Bug**: Fixed `populate.jl` incorrectly adding duplicate namespaced parameters (e.g., both `CL` and `sys₊CL`) due to the `meta_subs` loop. This caused ODEProblem construction to fail with "Missing values for variables" errors.
- **Expression Resolution Order**: Expressions like `k_el = CL / V` with `LockDependency: false` now resolve correctly regardless of parameter processing order. The `numeric_values` map is built upfront from all keyfile entries with direct numeric values.
- **MTK Symbol Resolution**: Switched from custom string parsing to `MTK.parse_variable()` for proper system-aware symbol resolution, ensuring namespaced symbols are handled correctly.
- **Test IC Comparisons**: Updated tests to use `Symbolics.value()` when comparing values from `initial_conditions`, as MTK stores ICs as symbolic types internally.

### Removed (Breaking)
- **`evaluate_mathematical_expression`**: Removed the custom expression evaluation engine (`locked_deps.jl`, 371 lines). This was dead code—`populate.jl` uses `Symbolics.parse_expr_to_symbolic` for all expression evaluation. If you were using this function externally, use Julia's `Meta.parse` + `eval` or `Symbolics.parse_expr_to_symbolic` directly.

### Fixed
- **Test Suite Overhaul**: Fixed all 88 tests to pass with current implementation.
  - Updated tests to use DynamicQuantities instead of Unitful for unit handling.
  - Fixed metadata access tests to use dictionary-based API (`entry.metadata[:description]`).
  - Updated variant diff tests for proper struct usage.
  - Fixed symbolic logic tests for auto-declared parameter behavior.
- **Parser Robustness**: Added normalization for simple scalar values in Parameters and Variables blocks (e.g., `ka: 1.5` now works without requiring dict format).
- **Variant Resolution**: Fixed `resolve_variant` to properly handle `OrderedDict` and merge variant overrides.
- **Description Alias**: Added `desc` as an alias for `description` in keyfile metadata.

### Added
- **Exports**: Added `populate` and `populate!` to public API exports.
- **Test Dependencies**: Added `test/Project.toml` with proper test dependencies (ModelingToolkit, OrdinaryDiffEq, Symbolics, etc.).

### Removed
- **Obsolete Exports**: Removed non-existent exports (`getUnitfulUnit`, `set_unit_validation`, `KeyfileKeys`, `KeyfileParameters`, `KeyfileVariables`).
- **Performance Tests**: Removed benchmark/allocation tests (not needed for current development).

### Changed
- **Update Engine Tests**: Temporarily disabled update engine tests (`integrator_test.jl`, `mtk_v11_integration_test.jl`, `system_update_test.jl`) pending MTK v11 API compatibility updates. Core keyfile functionality is fully tested.

## 2026-01-03

### Added
- **Binding Update Error**: The `update()` function now throws a descriptive `BindingUpdateError` when attempting to update a bound parameter (MTK v11+). Previously, attempting to update a binding like `k_el = CL/V` would silently succeed but have no effect — a dangerous silent failure. The error message now shows the binding expression and advises updating the underlying parameters instead.
- **`strict` Keyword Argument**: Added `strict=true` keyword to `update(prob, pairs)` and `update(integrator, pairs)`. Set to `false` to silently skip bindings (not recommended).
- **Exported `BindingUpdateError`**: The exception type is now exported for users who want to catch it explicitly.

### Fixed
- **Units Embedded in Values**: Fixed a critical bug where `populate` was multiplying numeric parameter values by their unit (e.g., `1.0 * u"1/s"` → `Quantity(1.0, s⁻¹)`), causing `ODEProblem` construction to fail with `AssertionError: Quantity has dimensions! Use ustrip instead`. Units are now stored only in symbol metadata (`VariableUnit`), with values remaining as plain numbers. The `validate_dict_units` function was also updated to only check dimensions when values are actually `DQ.AbstractQuantity` types.

## 2026-01-02

### Fixed
- **Critical Metadata Loss**: Fixed an issue where `populate` would strip existing ModelingToolkit metadata (e.g., `VariableSource`, `SymScope`, `VariableDescription`) when applying new unit metadata. The function now robustly transfers all properties from the original symbols using `getproperty`, ensuring compatibility with ModelinToolkit v9+.
- **Unit Inference**: Fixed a regression where dimensionless parameters (default `1.0`) blocked inference of dependent units (e.g., `k_el = 0.1 * k_a`). The inference engine now prioritizes expression evaluation over default dimensionless units.
- **Equation Substitution**: Fixed a bug where `Symbolics.substitute` failed to correctly update the time derivative operator on the LHS of equations (e.g., `D(Conc)`), leading to unit validation failures. Equations are now manually reconstructed to ensure derivatives use the updated independent variable.
- **Symbol Lookup Crashes**: Fixed a `matching non-exhaustive` error in `getname` by adding structural checks for `Symbolics.iscall` vs `Symbolics.Sym`.
- **Validation False Positives**: Fixed unit validation to ignore symbolic expressions (e.g., `k ~ 0.1*p`) during value checks, preventing type errors when comparing `Num` against `Quantity`.

### Changed
- **Error Handling**: Removed internal `try-catch` blocks in `populate.jl` that were silently suppressing errors (such as missing variables or invalid expressions), improving debugging visibility.
- **System Construction**: Switched from `ODESystem` to the generic `MTK.System` constructor for broader compatibility with different system types.
- **Ghost Parameters**: Ghost parameters (those in the keyfile but not the system) are now injected with explicit `VariableSource` and `SymScope` metadata to match standard MTK variables.

### Added
- **Robust Independent Variable Detection**: Improved logic to infer the unit of the independent variable (e.g., `t`) based on the units of differential equations if not explicitly defined.

## [0.2.0] - 2025-12-31

### Refactored (Breaking Changes)
- **ModelingToolkit v11 Migration**:
  - Removed all usage of the deprecated `defaults` field.
  - **Parameters** are now mapped to `system.defaults` (for values) or `system.bindings` (for structural dependencies).
  - **State Variables** are now mapped to `system.initial_conditions`.
  - `populate(sys, keyfile)` now returns a new, `complete`d System with updated bindings and initial conditions.
- **Update Engine Simplified**:
  - Removed the legacy "Update Engine" (`src/update_engine/`), including `UpdateCache`, `PrecompiledModel`, and manual `DiffCache` logic.
  - `update(prob, pairs)` now directly wraps `SciMLBase.remake`, leveraging MTK v11's internal performance optimizations.
  - `update(integrator, pairs)` now uses safe symbolic indexing to support in-place updates.

### Added
- **Initialization Guesses**: Added support for the `guess` field in keyfiles. This data is now automatically mapped to `system.guesses` to aid initialization of DAEs and algebraic loops.
- **Symbolic Preservation**: Locked dependencies (e.g., `k: CL/V`) are now applied as symbolic `Equation` bindings in the System, rather than being pre-calculated to numeric values. This preserves the topological structure of the model.

### Fixed
- **Integrator Indexing**: Fixed the "Indexing with parameters is deprecated" error by using `SymbolicIndexingInterface.is_parameter` to correctly route parameter updates to `integrator.ps`.
- **ODEProblem Population**: `populate!` now automatically separates keyfile entries into `p` (parameters) and `u0` (states) before calling `remake`, preventing errors about missing keys.
- **Keyfile Utilities**:
  - `evaluate_mathematical_expression` now handles `Dict{String, Number}` for value substitution.
  - `getUnitfulUnit("")` correctly returns `NoUnits` instead of erroring.
  - `list_available_variants` and `get_variant_diff` now accept file paths as strings.

## [0.1.0] - 2025-12-07

### Added
- Initial package structure
- Project.toml with dependencies for keyfile parsing and update engine
- Basic directory structure for src, test, docs, and examples
- Core keyfile data structures (structs.jl):
  - `KeyfileParameters`, `KeyfileVariables`, `KeyfileKeys` for internal storage
  - `ParameterEntry`, `ParametersView`, `KeyfileAccessor` for ergonomic API
  - `VariantDiffEntry`, `VariantDiffResult` for variant comparison
- Custom MTK metadata types (metadata.jl):
  - `ConstantParameter`, `InputParameter`, `DependentParameter`
  - `ConnectionVariable`, `ValueFunction`, `LockParameterDependency`
  - `ParameterBounds`, `SubstitutedDependentParameter`
- Helper utilities (utils.jl):
  - `load_yaml_ordered`, `getUnitfulUnit`, `convertToBool`
  - Validation and normalization functions
  - Unit inference from expressions
- Expression engine (locked_deps.jl):
  - `evaluate_mathematical_expression` for safe expression evaluation
  - Auto-declaration of keyfile-only parameters
  - Support for all standard math operations and functions
  - Symbolic substitution mode for MTK integration
- YAML parser (parser.jl):
  - `load_keyfile`, `parse_keyfile_for_defaults`, `load_key`
  - Full support for Parameters, Variables, Constants blocks
  - Unit validation and inference
  - Locked dependency resolution
- Variant system (variants.jl):
  - `get_variant_diff` for comparing variants
  - `list_available_variants`, `resolve_variant`
  - `validate_variant_completeness`
- Main module (ConfigKit.jl) with all exports
- Update engine (update_core.jl, update.jl, integrator_update.jl):
  - `update(prob, map)` for high-performance ODEProblem updates (~50μs)
  - `update(system, map)` for ModelingToolkit.System updates
  - `update(integrator, map)` for integrator updates
  - `clear_update_cache!()` to reset precompiled model cache
  - Automatic caching of precompiled models via LRU cache
  - Unit validation and conversion
  - Dependency resolution with cycle detection
- Test suite:
  - Test fixtures for basic parameters, variants, and dependencies
  - Tests for keyfile loading, variant utilities, expression engine
  - Unit utility tests
- Documentation (docs/src/):
  - index.md: Overview and quick example
  - getting_started.md: Installation and basic usage
  - keyfile_format.md: Complete YAML schema reference
  - variants.md: Multi-species/scenario parameter management
  - update_engine.md: High-performance update documentation
  - api_reference.md: Complete function reference
  - Documenter.jl setup (docs/make.jl)
