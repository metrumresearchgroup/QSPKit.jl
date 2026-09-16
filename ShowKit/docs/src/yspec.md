# SpecKit Integration

ShowKit integrates with [SpecKit](https://metrumresearchgroup.github.io/yspec/) to automatically generate axis labels, units, and decode maps from yspec YAML data specifications. This eliminates manual label strings and keeps plots/tables consistent with the data spec.

## Overview

A yspec YAML file describes every column in your dataset: name, label, units, type, and decode maps. ShowKit's `axis_col_labs()` function reads this metadata and generates the `"COL//Label [unit]"` strings that pmplots expects.

## `axis_col_labs()`

Generate pmplots-format label strings from a yspec metadata object:

```julia
using ShowKit, SpecKit

spec = load_yspec("data/derived/pk.yml")

# Generate labels for specific columns
labs = axis_col_labs(spec, [:DV, :PRED, :TIME, :WT, :AGE])
# Dict(:DV => "DV//Concentration [ng/mL]",
#       :PRED => "PRED//Population Predicted [ng/mL]",
#       :TIME => "TIME//Time [hr]", ...)

# Generate labels for all columns
all_labs = axis_col_labs(spec)
```

### Using with pmplots

```julia
spec = load_yspec("data/derived/pk.yml")
labs = axis_col_labs(spec, [:DV, :PRED, :IPRED, :TIME, :WT, :AGE, :SCR])

# GOF plots with automatic labels
p1 = dv_pred(df; x=labs[:PRED], y=labs[:DV])
p2 = cwres_time(df; x=labs[:TIME])

# ETA vs covariates with labels
covar_labs = [labs[:WT], labs[:AGE], labs[:SCR]]
eta_plots = [eta_cont(df; x=cl, y="ETA1//CL") for cl in covar_labs]
pm_grid(eta_plots; ncol=3)
```

## `col_label()`

Get a display label for a single column (without the column name prefix):

```julia
spec = load_yspec("data/derived/pk.yml")

col_label(spec, :WT)    # "Weight [kg]"
col_label(spec, :DV)    # "Concentration [ng/mL]"
col_label(spec, :TIME)  # "Time [hr]"
```

Useful for custom axis labels:

```julia
p + labs(x=col_label(spec, :TIME), y=col_label(spec, :DV))
```

## Duck Typing

The yspec integration is duck-typed — it works with any object that has a `.columns` dict where entries have `.short`, `.label`, and `.unit` fields. You don't need SpecKit loaded:

```julia
# Works with any spec-like object
mock_spec = (columns=Dict(
    :WT => (short="Weight", label="Body Weight", unit="kg"),
    :AGE => (short="Age", label="Age", unit="years"),
),)

labs = axis_col_labs(mock_spec, [:WT, :AGE])
# Dict(:WT => "WT//Weight [kg]", :AGE => "AGE//Age [years]")
```

## Complete Example

```julia
using ShowKit, SpecKit, DataFrames, CSV

# Load spec and data
spec = load_yspec("data/derived/pk.yml")
df = CSV.read("data/derived/pk-data.csv", DataFrame)

# Auto-generate all labels
labs = axis_col_labs(spec, [:DV, :PRED, :IPRED, :TIME, :TAD, :WT, :AGE, :SCR, :ALB])

# GOF panel with yspec labels
gof_plots = [
    dv_pred(df; x=labs[:PRED], y=labs[:DV]) + ggtitle("DV vs PRED"),
    dv_ipred(df; x=labs[:IPRED], y=labs[:DV]) + ggtitle("DV vs IPRED"),
    cwres_time(df; x=labs[:TIME]) + ggtitle("CWRES vs TIME"),
    cwres_pred(df; x=labs[:PRED]) + ggtitle("CWRES vs PRED"),
]

gof = pm_grid(gof_plots; ncol=2)
mrggsave(gof, "gof-panel"; dir="deliv/figure", script="pk-report.jl")

# Covariate ETA plots with yspec labels
covar_cols = [labs[:WT], labs[:AGE], labs[:SCR], labs[:ALB]]
for eta in ["ETA1//CL", "ETA2//V"]
    plots = [eta_cont(df; x=cl, y=eta) for cl in covar_cols]
    grid = pm_grid(plots; ncol=2)
    eta_name = split(eta, "//")[2]
    mrggsave(grid, "eta-$(lowercase(eta_name))-covariates";
        dir="deliv/figure", script="pk-report.jl")
end
```
