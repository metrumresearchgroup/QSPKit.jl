# Variants

Variants allow you to define multiple parameter sets within a single keyfile, commonly used for:
- Multi-species models (human, mouse, rat, monkey)
- Different dosing scenarios (IV, oral, infusion)
- Patient populations (healthy, disease, pediatric)
- Sensitivity scenarios (low, medium, high)

## Defining Variants

Use the `variants` field instead of `value`:

```yaml
Parameters:
  CL:
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
# Load default variant
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

## The `default` Variant

The `default` variant serves as a fallback:

```yaml
Parameters:
  CL:
    variants:
      default: 5.0    # Used when variant not found
      human: 5.0
      mouse: 50.0
```

If you request a variant that doesn't exist for a parameter, it falls back to `default`:

```julia
# 'dog' variant not defined, falls back to default
keyfile = load_keyfile("params.yml", variant=:dog)
keyfile.Parameters.CL.value  # 5.0 (from default)
```

## Comparing Variants

### get_variant_diff

Compare two variants to see what differs:

```julia
diff = get_variant_diff(:mouse, :human; keyfile="params.yml")

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
  Difference: 45.0
  Ratio: 10.0
V1:
  Mouse: 0.025
  Human: 50.0
  Difference: -49.975
  Ratio: 0.0005
```

### Filter to Only Different Values

```julia
diff = get_variant_diff(:mouse, :human; keyfile="params.yml", only_different=true)
```

### VariantDiffEntry Fields

| Field | Description |
|-------|-------------|
| `name` | Parameter name |
| `value_a` | Value in first variant |
| `value_b` | Value in second variant |
| `difference` | `value_a - value_b` (numeric only) |
| `ratio` | `value_a / value_b` (numeric only) |
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

### 1. Always Define `default`

```yaml
# Good: default provides fallback
CL:
  variants:
    default: 5.0
    human: 5.0
    mouse: 50.0

# Risky: no fallback if variant not found
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
