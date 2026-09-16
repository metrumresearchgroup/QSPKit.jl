# SpecKit

*"Spec it"* — yspec data specification for Julia.

SpecKit loads [yspec](https://github.com/metrumresearchgroup/yspec) YAML files that describe NONMEM dataset columns — labels, units, types, decode maps, and namespaces. Used by ShowKit for automatic axis labels and by TargKit for data validation.

## Features

- **Dual backend**: R yspec package via CondaR/RCall (full fidelity) or native Julia YAML parser (no R needed)
- **Auto-install**: R yspec package installs from GitHub on first use
- **Column metadata**: labels, units, types, ranges, decode maps, namespaces
- **Flags**: group columns by category (e.g., covariates, PK, PD)
- **Lookup files**: resolve external decode tables

## Quick Start

```julia
using SpecKit

# Load a yspec file (auto-selects R backend if available, falls back to native)
spec = load_yspec("data/derived/pk.yml")

# Access column metadata
spec.columns[:WT].label    # "Body Weight"
spec.columns[:WT].unit     # "kg"
spec.columns[:WT].short    # "Weight"

# Get all covariate columns (via flags)
cov_cols = spec.flags[:covariate]  # [:WT, :AGE, :SCR, :ALB]

# Decode maps
decodes(spec, :SEX)  # Dict(0 => "Male", 1 => "Female")

# Namespace switching (e.g., for different label conventions)
ns_spec = namespace(spec, "tex")
```

## With ShowKit

```julia
using ShowKit, SpecKit

spec = load_yspec("data/derived/pk.yml")
labs = axis_col_labs(spec, [:DV, :PRED, :TIME, :WT])

# pmplots with automatic labels
dv_pred(df; x=labs[:PRED], y=labs[:DV])
cwres_time(df; x=labs[:TIME])
```

## Backend Selection

```julia
load_yspec("spec.yml")                    # auto (R if available, else native)
load_yspec("spec.yml"; backend=:rcall)    # force R backend
load_yspec("spec.yml"; backend=:native)   # force native Julia parser
```

The R backend uses the real yspec package for full compatibility. The native backend parses the YAML directly — covers most features but may not handle all yspec edge cases.

## Installation

SpecKit is part of the QSPKit monorepo:

```julia
using Pkg
Pkg.develop(path="path/to/QSPKit/SpecKit")
```

For the R backend, also load CondaR before SpecKit:

```julia
using CondaR   # loads R runtime
using SpecKit  # auto-detects R availability
```
