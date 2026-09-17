# API Reference

This document covers all public functions exported by ConfigKit.

## Keyfile values and bounds

```@docs
value
get_values
get_bounds
get_all_values
ParameterSet
```

## Loading Keyfiles

### load_keyfile

```julia
load_keyfile(path; variant=nothing, strict=true) -> KeyfileAccessor
```

Load a YAML keyfile and return an accessor object for ergonomic access to parameters, variables, and constants.

**Arguments:**
- `path::String`: Path to the YAML keyfile
- `variant::Union{Symbol, String, Nothing}`: Which variant to load (default: `nothing`, which uses base values without variant overrides)
- `strict::Bool`: If true, warns about unexpected fields in the keyfile (default: `true`)

**Returns:** `KeyfileAccessor` with `.Parameters`, `.Variables`, `.Constants` properties

**Example:**
```julia
using QSPKit.ConfigKit

# Load with default variant
keyfile = load_keyfile("params.yml")

# Load specific species variant
keyfile = load_keyfile("params.yml", variant=:mouse)

# Access parameter values
CL = keyfile.Parameters.CL.value      # 5.0
unit = keyfile.Parameters.CL.unit     # DynamicQuantities unit

# Check metadata
desc = keyfile.Parameters.CL.metadata[:description]  # "Systemic clearance"

# Check if parameter has an expression
haskey(keyfile.Parameters.k_el.metadata, :expression)  # true if value is expression
keyfile.Parameters.k_el.metadata[:expression]          # "CL / V"
```

---

## Populating Models

### populate

```julia
populate(sys::System, keyfile::KeyfileAccessor;
         strict=true, overrides=Dict(), solve_for=Pair[]) -> System
```

Populate a ModelingToolkit system with values from a keyfile. This is the primary function for connecting your keyfile to your model.

**Arguments:**
- `sys::System`: The ModelingToolkit system to populate
- `keyfile::KeyfileAccessor`: Loaded keyfile from `load_keyfile`

**Keyword Arguments:**
| Argument | Default | Description |
|----------|---------|-------------|
| `strict` | `true` | Validates that all required parameters exist |
| `overrides` | `Dict()` | Override keyfile values: `Dict("CL" => 20.0)` |
| `solve_for` | `Pair[]` | Use MTK init system to solve for parameters (see below) |

**Returns:** New `System` with:
- Initial conditions set from Variables block
- Parameter defaults set from Parameters block
- Expression-valued parameters configured as bindings
- Ghost parameters injected for keyfile parameters not in the model

**Example:**
```julia
using ModelingToolkit
using QSPKit.ConfigKit

# Define your model
@variables t Central(t) Depot(t)
@parameters CL V1 ka

D = Differential(t)
eqs = [
    D(Depot) ~ -ka * Depot,
    D(Central) ~ ka * Depot - (CL/V1) * Central
]

@named sys = System(eqs, t)

# Load keyfile and populate
keyfile = load_keyfile("pk_params.yml", variant=:human)
sys_populated = populate(sys, keyfile)

# Build and solve
sys_simplified = mtkcompile(sys_populated)
prob = ODEProblem(sys_simplified, [], (0.0, 24.0))
sol = solve(prob, Tsit5())
```

### The `solve_for` Argument

Use `solve_for` when you want MTK's initialization system to compute parameter values at t=0 based on equations. This is useful for:
- Steady-state initialization
- Inverse problems (find parameters that satisfy given constraints)

**Syntax:** `solve_for = [:target => [:adjustable_params...]]`

```julia
# Keyfile has: CL=10.0, V=100.0, k_el="CL / V"
# Use MTK init system to solve for k_el by adjusting CL and V
sys = populate(sys, keyfile; solve_for=[:k_el => [:CL, :V]])

# Custom equation (not from keyfile)
sys = populate(sys, keyfile; solve_for=["k_el ~ CL / V * 2" => [:CL, :V]])

# Multiple targets
sys = populate(sys, keyfile; solve_for=[:k1 => [:a], :k2 => [:b]])
```

**How it works:**
1. Target parameter is bound to `missing` (solver will compute)
2. Adjustable params get keyfile values as initial guesses
3. Initialization equation is added: `target ~ expression`
4. MTK's init solver finds values satisfying the equation

---

### populate!

```julia
populate!(prob::ODEProblem, keyfile::KeyfileAccessor; strict=true) -> ODEProblem
```

Updates an existing ODEProblem with values from a keyfile. Uses the fast `update()` engine internally for efficient parameter updates.

**Arguments:**
- `prob`: An existing ODEProblem to update
- `keyfile`: KeyfileAccessor containing parameter values
- `strict`: If true, throws error for missing parameters (default: true)

---

## Updating Parameters

### update

```julia
update(prob::ODEProblem, pairs; kwargs...) -> ODEProblem
update(integrator::AbstractODEIntegrator, pairs; kwargs...) -> AbstractODEIntegrator
```

High-performance parameter update using internal caching. After the first call (which builds a cache), subsequent updates run ~50x faster than naive remake.

**Arguments:**
- `prob` or `integrator`: The object to update
- `pairs`: Vector of `parameter => value` pairs

**Keyword Arguments:**
| Argument | Default | Description |
|----------|---------|-------------|
| `strict` | `true` | Error if attempting to update a bound parameter |

**Returns:** New problem/integrator with updated parameters (original unchanged)

**Example:**
```julia
# Basic usage
new_prob = update(prob, [CL => 10.0, V1 => 100.0])

# String keys also work
new_prob = update(prob, ["CL" => 10.0])

# Symbol keys
new_prob = update(prob, [:CL => 10.0])
```

**Binding Protection:**

If a parameter is an expression-valued parameter (a binding), it cannot be directly updated. ConfigKit will error with a helpful message:

```julia
# k_el is defined as "CL / V" in the keyfile
update(prob, [:k_el => 2.0])
# ERROR: Cannot update 'k_el' — it is a bound parameter defined as: CL / V
#        Update the underlying parameters instead.

# Instead, update the base parameters:
update(prob, [:CL => 2.0, :V1 => 10.0])  # k_el will be recomputed
```

---

## Variant Utilities

### get_variant_diff

```julia
get_variant_diff(source; variant_a, variant_b=nothing, only_different=true) -> VariantDiffResult
```

Compare parameter values between two variants, or between a variant and base values.

**Arguments:**
- `source`: Path to keyfile (String) or raw YAML Dict

**Keyword Arguments:**
- `variant_a::Symbol`: First variant to compare (required)
- `variant_b::Union{Symbol,Nothing}`: Second variant, or `nothing` to compare against base values
- `only_different::Bool`: If true (default), only include entries that differ

**Returns:** `VariantDiffResult` that supports iteration and indexing

**Example:**
```julia
# Compare two variants
diff = get_variant_diff("params.yml"; variant_a=:mouse, variant_b=:human)

for entry in diff
    println("$(entry.name): $(entry.value_a) → $(entry.value_b)")
    if entry.ratio !== nothing
        println("  Ratio: $(entry.ratio)x")
    end
end

# Access specific parameter
if haskey(diff, :CL)
    cl_diff = diff[:CL]
    println("CL ratio: $(cl_diff.ratio)")
end

# Compare variant to base values
diff = get_variant_diff("params.yml"; variant_a=:human)
```

**VariantDiffEntry Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `name` | `Symbol` | Parameter name |
| `category` | `Symbol` | `:Parameters` or `:Variables` |
| `value_a` | `Any` | Value in variant_a |
| `value_b` | `Any` | Value in variant_b (or base) |
| `difference` | `Float64` or `nothing` | `value_b - value_a` for numeric values |
| `ratio` | `Float64` or `nothing` | `value_b / value_a` for numeric values |
| `unit` | Unit or `nothing` | Parameter unit |
| `description` | `String` or `nothing` | Parameter description |

---

### list_available_variants

```julia
list_available_variants(source) -> Set{Symbol}
```

List all variants defined across all parameters and variables in a keyfile.

**Arguments:**
- `source`: Path to keyfile (String) or raw YAML Dict

**Returns:** `Set{Symbol}` of variant names

**Example:**
```julia
variants = list_available_variants("params.yml")
# Set([:default, :human, :mouse, :rat])

for v in variants
    println("Available variant: $v")
end
```

---

## Accessor Types

These types are returned by `load_keyfile` and provide ergonomic access to keyfile data.

### KeyfileAccessor

Top-level accessor returned by `load_keyfile`.

**Properties:**
- `.Parameters` → `ParametersView` of all parameters
- `.Variables` → `ParametersView` of all variables
- `.Constants` → `ParametersView` of all constants

### ParametersView

Iterable view over a category (Parameters, Variables, or Constants).

**Supports:**
- Property access: `view.CL` returns a `ParameterEntry`
- Iteration: `for param in view`
- Length: `length(view)`

### ParameterEntry

Accessor for a single parameter's data.

**Properties:**
| Property | Type | Description |
|----------|------|-------------|
| `.name` | `Symbol` | Parameter name |
| `.value` | `Any` | Parameter value (number or expression string) |
| `.unit` | `DQ.Quantity` | Unit as DynamicQuantities |
| `.value_original` | `Any` | Original value from YAML |
| `.metadata` | `Dict{Symbol,Any}` | Additional metadata (description, bounds, etc.) |
| `.equation` | `Any` | Optional symbolic equation |

**Metadata keys:** `:description`, `:label`, `:bounds`, `:expression` (for expression-valued params)

**Example:**
```julia
keyfile = load_keyfile("params.yml")
entry = keyfile.Parameters.CL

entry.name                           # :CL
entry.value                          # 5.0 (or "CL / V" for expressions)
entry.unit                           # DynamicQuantities unit
entry.metadata[:description]         # "Systemic clearance"
entry.metadata[:bounds]              # [0.1, 50.0]

# Check if expression-valued
haskey(entry.metadata, :expression)  # true for expression params
```

---

## Update integration API

```@docs
UpdateCache
thread_update_cache
with_thread_update_cache
BindingUpdateError
prepared_update_source
```

`update!` mutates an `UpdateCache` for reuse. `with_update_cache` lends a
temporarily updated problem to a callback, and `PreparedUpdateSource` records
the prepared source metadata used by that boundary.

## Model helpers

```@docs
ConfigKit.@common_constants
MTKParamLens
ConfigKit.@param
bounds_from
```

`ConfigKit.@observed` declares an observed expression for the generated model
system.

`ConfigKit.MTK` aliases `ModelingToolkitBase`. ConfigKit also re-exports the
`@us_str` macro for symbolic unit annotations.

## Internal Functions

These functions are not exported but may be useful for advanced users. Access via `ConfigKit.function_name()`.

### getMTKUnit

```julia
ConfigKit.getMTKUnit(unit_str::String) -> DynamicQuantities.Quantity
```

Parse a unit string into a DynamicQuantities quantity for use with ModelingToolkit v11+.

**Example:**
```julia
ConfigKit.getMTKUnit("L/hr")   # DQ.Quantity with volume/time dimensions
ConfigKit.getMTKUnit("mg")     # DQ.Quantity with mass dimensions
ConfigKit.getMTKUnit("")       # Dimensionless (1.0)
```

### parse_string_to_symbolic

```julia
ConfigKit.parse_string_to_symbolic(expr::String, name_map::Dict) -> Symbolics.Num
```

Parse a string expression into a Symbolics.jl symbolic expression. Used internally to convert keyfile expressions like `"CL / V"` into symbolic bindings.

**Example:**
```julia
# Internal usage (name_map maps Symbol names to symbolic objects)
expr = ConfigKit.parse_string_to_symbolic("CL / V", Dict(:CL => CL_sym, :V => V_sym))
```
