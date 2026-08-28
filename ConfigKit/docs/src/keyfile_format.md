# Keyfile format

ConfigKit reads YAML keyfiles with three optional top-level blocks:
`Parameters`, `Variables`, and `Constants`. Entry names become Julia symbols in
the returned `KeyfileAccessor`.

!!! warning "Trusted input only"
    String-valued expressions are evaluated as Julia code when ConfigKit
    resolves values or symbolic bindings. Keyfiles are executable input and are
    not sandboxed. Load only keyfiles you trust.

## Loading and field validation

```julia
kf = load_keyfile("model.yml")
kf_mouse = load_keyfile("model.yml"; variant=:mouse)
```

`strict=true` is the default. It rejects unsupported fields inside parameter,
variable, and constant entries. `strict=false` ignores unsupported entry fields
instead of adding them to metadata:

```julia
kf = load_keyfile("legacy.yml"; strict=false)
```

Strict parsing is separate from `populate(...; strict=...)`. The latter controls
unit and ModelingToolkit system validation after a model is populated.

## Parameters

A parameter can use a scalar shorthand:

```yaml
Parameters:
  CL: 5.0
  V: 50.0
```

or a mapping with the supported fields below.

| Field | Meaning |
| --- | --- |
| `value` | Numeric value or trusted Julia expression string |
| `unit` | Unit string parsed through Unitful and converted for ModelingToolkit metadata |
| `variants` | Named scalar or mapping overrides selected by `variant` |
| `description` / `desc` | Human-readable description; `desc` is normalized to `description` |
| `label` | Display label retained in metadata |
| `abbr` | Abbreviation retained in metadata |
| `source` | Provenance text retained in metadata |
| `bounds` | Two-element sequence `[lower, upper]` |
| `convert` | Target unit for numeric value conversion |
| `Implicit` | Case-sensitive flag telling `populate` not to assign this parameter directly |

Example:

```yaml
Parameters:
  CL:
    value: 5.0
    unit: L/hr
    description: Systemic clearance
    abbr: CL
    source: Synthetic population analysis
    bounds: [0.1, 50.0]

  V:
    value: 50.0
    unit: L

  k_el:
    value: CL / V
    unit: 1/hr
```

Fields such as `citation`, `type`, parameter-level `guess`, and `tunable` are
not part of the current schema. With strict parsing they raise an error. Put
citations or other provenance text in `source`.

### Bounds

Bounds must be a two-element YAML sequence:

```yaml
Parameters:
  CL:
    value: 5.0
    bounds: [0.1, 50.0]
```

They are available through `get_bounds`, `bounds_from`, and `ParameterSet`.
Dictionary forms such as `{lower: 0.1, upper: 50.0}` are not supported by
those APIs.

### Unit conversion

`convert` converts a numeric value from its declared `unit` to a target unit:

```yaml
Parameters:
  delay:
    value: 0.5
    unit: hr
    convert: s
```

The resolved value is `1800.0`. Conversion requires a source unit. Expression
values are not converted and produce a warning when `convert` is present.

## Variables

Variables use `initial` (or the alias `value`) for initial conditions.

| Field | Meaning |
| --- | --- |
| `initial` / `value` | Initial value |
| `unit` | Unit string |
| `variants` | Named initial-value overrides |
| `description` / `desc` | Human-readable description |
| `label` | Display label retained in metadata |
| `abbr` | Abbreviation retained in metadata |
| `guess` | ModelingToolkit initialization guess used by `populate` |

```yaml
Variables:
  Central:
    initial: 0.0
    unit: mg
    description: Amount in the central compartment
    guess: 0.1
```

## Constants

Constants do not support variants. Their supported fields are `value`, `unit`,
`description`/`desc`, `label`, and `abbr`.

```yaml
Constants:
  MW:
    value: 450.0
    unit: g/mol
    description: Molecular weight
```

## Base values and variants

With `variant=nothing`, ConfigKit uses the top-level `value` or `initial` and
does not apply a variant:

```yaml
Parameters:
  CL:
    value: 5.0
    variants:
      mouse: 0.5
      human: 5.0
```

```julia
load_keyfile("model.yml").Parameters.CL.value                  # 5.0
load_keyfile("model.yml"; variant=:mouse).Parameters.CL.value  # 0.5
```

`default` has no special fallback behavior. It is an ordinary variant name and
must be selected explicitly:

```julia
load_keyfile("model.yml"; variant=:default)
```

If a requested variant is absent for an entry, its base value remains in use.
If a model parameter has variants but no base value and no matching variant was
selected, `populate` reports that the parameter has no value.

See [Variants](variants.md) for comparison and discovery utilities.

## Expression-valued parameters

Parameter values may be trusted Julia expressions referring to other keyfile
entries:

```yaml
Parameters:
  CL:
    value: 5.0
  V:
    value: 50.0
  k_el:
    value: CL / V
  half_life:
    value: log(2) / k_el
```

`value(kf, :half_life)` evaluates dependencies recursively. During model
population, symbolic expressions become ModelingToolkit bindings, so updating
their independent parameters recomputes the derived value. Direct updates to a
bound parameter are rejected in strict update mode.

## Complete valid example

```yaml
Parameters:
  ka:
    value: 1.5
    unit: 1/hr
    description: First-order absorption rate
    bounds: [0.1, 10.0]
    source: Literature summary

  V:
    value: 50.0
    unit: L
    variants:
      default: 50.0
      mouse: 0.025

  CL:
    value: 5.0
    unit: L/hr
    variants:
      default: 5.0
      mouse: 0.5

  k_el:
    value: CL / V
    unit: 1/hr

Variables:
  Depot:
    initial: 0.0
    unit: mg
  Central:
    initial: 0.0
    unit: mg
    guess: 0.1

Constants:
  MW:
    value: 450.0
    unit: g/mol
    description: Molecular weight
```

Load base values with `load_keyfile("model.yml")`, or explicitly select the
named `default` or `mouse` variant.
