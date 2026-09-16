# Keyfile Format Reference

This document describes the complete YAML schema for ConfigKit keyfiles.

## Structure Overview

A keyfile has three top-level sections:

```yaml
Parameters:
  # Model parameters (rate constants, volumes, clearances, etc.)

Variables:
  # State variables with initial conditions

Constants:
  # Fixed values that never change during simulation
```

All sections are optional - you can have a keyfile with just Parameters, or just Variables, etc.

## Entry Formats

### Simple Format

For quick parameter definitions without metadata:

```yaml
Parameters:
  ka: 1.5        # Just a number
  CL: 5.0
  V1: 50.0
```

### Rich Format

Full metadata support for documented, traceable parameters:

```yaml
Parameters:
  CL:
    value: 5.0
    unit: L/hr
    description: "Systemic clearance"
    abbr: CL
    source: "PopPK Study ABC-123"
    citation: "Smith et al. CPT 2023"
    bounds: [0.1, 50.0]
    guess: 5.0
    tunable: true
```

## Core Fields

### value / initial

The parameter value or initial condition.

```yaml
Parameters:
  CL:
    value: 5.0      # For parameters, use "value"

Variables:
  Central:
    initial: 0.0    # For variables, use "initial"
```

**Note:** You can also use `value` for Variables - ConfigKit will interpret it correctly.

### unit

Physical unit as a string. ConfigKit parses these using Unitful internally and converts to DynamicQuantities for ModelingToolkit v11+.

```yaml
Parameters:
  CL:
    value: 5.0
    unit: L/hr

  ka:
    value: 1.5
    unit: 1/hr      # Rate constant

  dose:
    value: 100
    unit: mg

  concentration:
    value: 10.0
    unit: mg/L
```

**Supported unit formats:**
- Simple: `L`, `mg`, `hr`, `s`, `mol`
- Compound: `L/hr`, `mg/L`, `mol/L`
- Powers: `m^2`, `s^-1`, `L^2`
- With prefixes: `mL`, `kg`, `nmol`, `uM` (micro)
- Dimensionless: `""` or `"1"` or omit entirely

**Common QSP units:**

| Category | Examples |
|----------|----------|
| Volume | `L`, `mL`, `dL` |
| Mass | `g`, `mg`, `ug`, `ng`, `kg` |
| Time | `hr`, `d`, `min`, `s` |
| Amount | `mol`, `mmol`, `umol`, `nmol` |
| Concentration | `mg/L`, `ug/mL`, `mol/L`, `nM`, `uM` |
| Rate | `1/hr`, `1/d`, `hr^-1` |
| Clearance | `L/hr`, `mL/min`, `L/d` |
| Flow | `L/hr`, `mL/min` |

### description

Human-readable description of the parameter.

```yaml
Parameters:
  CL:
    value: 5.0
    description: "Systemic clearance - elimination from central compartment"
```

### abbr

Short abbreviation (defaults to parameter name if omitted).

```yaml
Parameters:
  elimination_rate_constant:
    value: 0.1
    abbr: k_el
```

## Metadata Fields

### source

Where the value came from - study, publication, assumption, etc.

```yaml
Parameters:
  CL:
    value: 5.0
    source: "PopPK analysis of Phase 1 data (Study ABC-123)"
```

### citation

Literature reference for the value.

```yaml
Parameters:
  Vmax:
    value: 100.0
    citation: "Jones et al., Drug Metab Dispos 2022; 50(3):245-252"
```

### type

Category tag for the parameter.

```yaml
Parameters:
  CL:
    value: 5.0
    type: clearance

  V1:
    value: 50.0
    type: volume

  kon:
    value: 0.01
    type: binding
```

## Optimization Fields

### bounds

Lower and upper limits for parameter estimation/fitting.

**Array format:**
```yaml
Parameters:
  CL:
    value: 5.0
    bounds: [0.1, 50.0]    # [lower, upper]
```

**Dict format:**
```yaml
Parameters:
  CL:
    value: 5.0
    bounds:
      lower: 0.1
      upper: 50.0
```

### guess

Initial guess for optimization or solver initialization.

```yaml
Parameters:
  CL:
    value: 5.0       # "True" or reference value
    guess: 2.0       # Starting point for optimizer

Variables:
  Central:
    initial: 0.0
    guess: 0.1       # Initial guess for steady-state solver
```

### tunable

Whether the parameter can be tuned during optimization (default: `true`).

```yaml
Parameters:
  CL:
    value: 5.0
    tunable: true    # Can be optimized

  F:
    value: 1.0
    tunable: false   # Fixed at 1.0, not optimized
```

## Expression-Valued Parameters

Define parameters as mathematical expressions of other parameters. These become **bindings** in ModelingToolkit v11+ (computed on-the-fly rather than stored as fixed values).

```yaml
Parameters:
  CL:
    value: 5.0
    unit: L/hr

  V1:
    value: 50.0
    unit: L

  # Elimination rate = clearance / volume (expression as string)
  k_el:
    value: CL / V1
    unit: 1/hr
    description: "Elimination rate constant"

  # Half-life from rate constant
  half_life:
    value: log(2) / k_el
    unit: hr
    description: "Terminal elimination half-life"
```

When you use `populate()`, expression-valued parameters automatically become symbolic bindings. This means:
- `k_el` is not stored as `0.1` — it's stored as `CL / V1`
- If you later update `CL` or `V1`, `k_el` automatically recomputes
- You cannot directly update `k_el` (it's derived, not independent)

### Supported Functions in Expressions

**Arithmetic:** `+`, `-`, `*`, `/`, `^`

**Exponential/Logarithmic:**
- `exp(x)` - e^x
- `log(x)` - natural log
- `log10(x)` - base-10 log
- `log2(x)` - base-2 log
- `sqrt(x)` - square root

**Trigonometric:**
- `sin`, `cos`, `tan`
- `asin`, `acos`, `atan`
- `sinh`, `cosh`, `tanh`

**Utility:**
- `abs(x)` - absolute value
- `sign(x)` - sign function
- `floor(x)`, `ceil(x)`, `round(x)`
- `min(a, b)`, `max(a, b)`

**Constants:**
- `pi` or `π` - 3.14159...
- `e` or `ℯ` - 2.71828...

### Chained Expressions

Expressions can reference other expression-valued parameters:

```yaml
Parameters:
  CL:
    value: 5.0
    unit: L/hr

  V1:
    value: 50.0
    unit: L

  k_el:
    value: CL / V1
    unit: 1/hr

  half_life:
    value: log(2) / k_el    # References k_el
    unit: hr

  # Even deeper chaining
  time_to_90pct:
    value: 3.32 * half_life  # ~3.32 half-lives to 90% elimination
    unit: hr
```

## Variants

Define multiple parameter sets for different species, scenarios, or populations.

```yaml
Parameters:
  CL:
    unit: L/hr
    description: "Systemic clearance"
    variants:
      default: 5.0     # Fallback value
      human: 5.0
      mouse: 0.5
      rat: 2.5
      monkey: 3.0
    source: "Allometric scaling (BW^0.75)"
```

### Loading Variants

```julia
# Load default
keyfile = load_keyfile("params.yml")

# Load specific variant
keyfile = load_keyfile("params.yml", variant=:mouse)
```

### Mixing Fixed and Variant Values

Parameters without variants use the same value for all variants:

```yaml
Parameters:
  # Varies by species
  CL:
    variants:
      human: 5.0
      mouse: 0.5
    unit: L/hr

  # Same for all species
  fu:
    value: 0.1
    description: "Fraction unbound - same across species"
```

See [Variants](variants.md) for complete variant documentation.

## Variables Section

State variables with initial conditions:

```yaml
Variables:
  # Drug in depot compartment
  Depot:
    initial: 100.0     # Starting amount
    unit: mg
    description: "Drug in absorption compartment"

  # Drug in central compartment
  Central:
    initial: 0.0
    unit: mg
    description: "Drug in central (plasma) compartment"
    guess: 0.1         # For steady-state solvers

  # Receptor occupancy
  RO:
    initial: 0.0
    unit: ""           # Dimensionless (fraction)
    description: "Target receptor occupancy"
```

Variables can also have variants:

```yaml
Variables:
  Depot:
    unit: mg
    variants:
      default: 0.0
      bolus_100: 100.0
      bolus_200: 200.0
```

## Constants Section

Fixed values that never change during simulation:

```yaml
Constants:
  # Molecular properties
  MW:
    value: 450.0
    unit: g/mol
    description: "Molecular weight"

  # Physiological constants
  BW_human:
    value: 70.0
    unit: kg
    description: "Reference human body weight"

  BW_mouse:
    value: 0.025
    unit: kg
    description: "Reference mouse body weight"

  # Bioavailability (if fixed)
  F:
    value: 0.85
    description: "Oral bioavailability"
```

## Complete Example: Two-Compartment PK Model

```yaml
# two_cpt_pk.yml
# Two-compartment PK model with first-order absorption
# Supports human, mouse, and rat scaling

Parameters:
  # === Absorption ===
  ka:
    value: 1.5
    unit: 1/hr
    description: "First-order absorption rate constant"
    bounds: [0.1, 10.0]
    source: "Literature average for small molecules"

  F:
    value: 0.85
    description: "Oral bioavailability"
    tunable: false

  # === Distribution ===
  V1:
    unit: L
    description: "Central compartment volume"
    variants:
      human: 50.0
      mouse: 0.025
      rat: 0.25
    source: "Allometric scaling (BW^1.0)"
    bounds: [1.0, 200.0]

  V2:
    unit: L
    description: "Peripheral compartment volume"
    variants:
      human: 100.0
      mouse: 0.05
      rat: 0.5
    source: "Allometric scaling (BW^1.0)"

  # === Clearance ===
  CL:
    unit: L/hr
    description: "Systemic clearance"
    variants:
      human: 5.0
      mouse: 0.5
      rat: 2.5
    source: "Allometric scaling (BW^0.75)"
    bounds: [0.1, 50.0]

  Q:
    unit: L/hr
    description: "Intercompartmental clearance"
    variants:
      human: 10.0
      mouse: 1.0
      rat: 5.0
    source: "Allometric scaling (BW^0.75)"

  # === Derived Parameters (Expressions) ===
  k_el:
    value: CL / V1
    unit: 1/hr
    description: "Elimination rate constant"

  k12:
    value: Q / V1
    unit: 1/hr
    description: "Central to peripheral rate constant"

  k21:
    value: Q / V2
    unit: 1/hr
    description: "Peripheral to central rate constant"

  half_life:
    value: log(2) / k_el
    unit: hr
    description: "Approximate terminal half-life"

Variables:
  Depot:
    initial: 0.0
    unit: mg
    description: "Drug amount in depot (GI tract)"

  Central:
    initial: 0.0
    unit: mg
    description: "Drug amount in central compartment"

  Peripheral:
    initial: 0.0
    unit: mg
    description: "Drug amount in peripheral compartment"

Constants:
  MW:
    value: 450.0
    unit: g/mol
    description: "Molecular weight"
    source: "Compound characterization"
```

## Tips for QSP Scientists

### 1. Start Simple, Add Metadata Gradually

Begin with just values, then add units and descriptions as the model matures:

```yaml
# Early development
Parameters:
  CL: 5.0
  V1: 50.0

# Production-ready
Parameters:
  CL:
    value: 5.0
    unit: L/hr
    description: "Systemic clearance"
    source: "PopPK Study ABC-123"
    bounds: [0.1, 50.0]
```

### 2. Use Comments for Context

YAML supports comments with `#`:

```yaml
Parameters:
  # PK parameters from Phase 1 PopPK analysis
  CL:
    value: 5.0
    # Note: This is the typical value; IIV CV% = 35%
```

### 3. Group Related Parameters

Use comments to organize sections:

```yaml
Parameters:
  # === Absorption ===
  ka:
    value: 1.5
  F:
    value: 0.85

  # === Distribution ===
  V1:
    value: 50.0
  V2:
    value: 100.0

  # === Elimination ===
  CL:
    value: 5.0
```

### 4. Document Data Sources

Future you (and regulators) will thank you:

```yaml
Parameters:
  Kd:
    value: 0.1
    unit: nM
    description: "Equilibrium dissociation constant"
    source: "SPR binding assay, internal data"
    citation: "Study Report XYZ-2023-001, Table 3"
```
