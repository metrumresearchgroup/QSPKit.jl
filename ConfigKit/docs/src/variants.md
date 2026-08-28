# Variants

Variants allow you to define multiple parameter sets within a single keyfile, commonly used for:
- Multi-species models (human, mouse, rat, monkey)
- Different dosing scenarios (IV, oral, infusion)
- Patient populations (healthy, disease, pediatric)
- Sensitivity scenarios (low, medium, high)

## Defining Variants

Use `variants` for named overrides. Keep a base `value` when the entry must
also work without a selected variant:

```yaml
Parameters:
  CL:
    value: 5.0
    variants:
      default: 5.0
      human: 5.0
      mouse: 50.0
      rat: 25.0
      monkey: 15.0
    unit: L/hr
    description: "Systemic clearance"
```

## Loading Variants

```julia
# Load the base value without applying a variant
keyfile = load_keyfile("params.yml")
keyfile.Parameters.CL.value  # 5.0

# Load specific variant
keyfile_mouse = load_keyfile("params.yml", variant=:mouse)
keyfile_mouse.Parameters.CL.value  # 50.0

# String variant names also work
keyfile_rat = load_keyfile("params.yml", variant="rat")
```

## Mixing Variants and Fixed Values

Parameters without variants use the same value for all variants:

```yaml
Parameters:
  CL:
    variants:
      human: 5.0
      mouse: 50.0
    unit: L/hr

  # Same value regardless of variant selection
  ka:
    value: 1.5
    unit: 1/hr
```

## The `default` Name

`default` is an ordinary variant name. It is not selected automatically and is
not used as a fallback:

```yaml
Parameters:
  CL:
    variants:
      default: 5.0    # Selected explicitly with variant=:default
      human: 5.0
      mouse: 50.0
```

Select it explicitly when desired:

```julia
keyfile = load_keyfile("params.yml", variant=:default)
keyfile.Parameters.CL.value  # 5.0
```

When a requested variant is absent, ConfigKit retains the entry's base
`value`/`initial`. Without a base value, a required model parameter later
causes `populate` to report that no value was selected.

## Comparing Variants

### get_variant_diff

Compare two variants to see what differs:

```julia
diff = get_variant_diff("params.yml"; variant_a=:mouse, variant_b=:human)

for entry in diff
    println("$(entry.name):")
    println("  Mouse: $(entry.value_a)")
    println("  Human: $(entry.value_b)")
    if entry.difference !== nothing
        println("  Difference: $(entry.difference)")
        println("  Ratio: $(entry.ratio)")
    end
end
```

Output:
```
CL:
  Mouse: 50.0
  Human: 5.0
  Difference: -45.0
  Ratio: 0.1
V1:
  Mouse: 0.025
  Human: 50.0
  Difference: 49.975
  Ratio: 2000.0
```

### Filter to Only Different Values

```julia
diff = get_variant_diff(
    "params.yml"; variant_a=:mouse, variant_b=:human, only_different=true)
```

### VariantDiffEntry Fields

| Field | Description |
|-------|-------------|
| `name` | Parameter name |
| `value_a` | Value in first variant |
| `value_b` | Value in second variant |
| `difference` | `value_b - value_a` (numeric only) |
| `ratio` | `value_b / value_a` (numeric only) |
| `unit` | Parameter unit |
| `description` | Parameter description |

## Listing Available Variants

```julia
variants = list_available_variants("params.yml")
# [:default, :human, :mouse, :rat, :monkey]
```

## Variables with Variants

State variables can also have variants:

```yaml
Variables:
  Depot:
    variants:
      default: 0.0
      bolus_100mg: 100.0
      bolus_200mg: 200.0
    unit: mg
    description: "Initial dose in depot"

  Central:
    value: 0.0  # Always starts at 0
    unit: mg
```

## Best Practices

### 1. Define a base value when no variant must also work

```yaml
# Base loading and explicit variants both have values
CL:
  value: 5.0
  variants:
    default: 5.0
    human: 5.0
    mouse: 50.0

# Variant-only: callers must select a matching variant before population
CL:
  variants:
    human: 5.0
    mouse: 50.0
```

### 2. Use Consistent Variant Names

```yaml
# Good: consistent naming across parameters
Parameters:
  CL:
    variants: {human: 5.0, mouse: 50.0}
  V1:
    variants: {human: 50.0, mouse: 0.025}

# Bad: inconsistent naming
Parameters:
  CL:
    variants: {Human: 5.0, MOUSE: 50.0}
  V1:
    variants: {human: 50.0, mouse: 0.025}
```

### 3. Document Species Scaling

```yaml
Parameters:
  CL:
    variants:
      human: 5.0       # Reference species
      mouse: 50.0      # Allometric: CL_mouse = CL_human * (BW_mouse/BW_human)^0.75
      rat: 25.0
    unit: L/hr
    source: "Allometric scaling with exponent 0.75"
```

### 4. Group Related Variants

```yaml
# Consider separate files for very different scenarios
# params_species.yml - species variants
# params_dosing.yml - dosing variants

# Or use compound variant names
Parameters:
  Depot_0:
    variants:
      human_iv: 0.0
      human_oral: 100.0
      mouse_iv: 0.0
      mouse_oral: 10.0
```
