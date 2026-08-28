# pmplots

ShowKit wraps the public [pmplots](https://metrumresearchgroup.github.io/pmplots/) package, which provides pre-built pharmacometric diagnostic plots. All functions accept a Julia DataFrame and return a `GGPlot` that can be further customized with `+`.

## Overview

pmplots assumes NONMEM-style column names: `DV`, `PRED`, `IPRED`, `CWRES`, `NPDE`, `TIME`, `TAD`, `TAFD`, `ETA1`, `ETA2`, etc. If your data uses different names, pass the column mapping via keyword arguments.

## Goodness-of-Fit Plots

```julia
using ShowKit, DataFrames

# DV vs PRED
p1 = dv_pred(df)

# DV vs IPRED
p2 = dv_ipred(df)

# Both on one layout
p3 = dv_preds(df)

# DV over time
p4 = dv_time(df)
p5 = dv_tad(df)      # time after dose
p6 = dv_tafd(df)     # time after first dose
```

All return `GGPlot` objects — customize freely:

```julia
p = dv_pred(df) +
    theme_bw() +
    ggtitle("Observed vs Predicted") +
    labs(x="Population Predicted", y="Observed")
```

## Residual Plots

Every residual type has a full set of variants:

```julia
# CWRES (conditional weighted residuals)
cwres_time(df)       cwres_tad(df)        cwres_tafd(df)
cwres_pred(df)       cwres_cont(df)       cwres_cat(df)
cwres_hist(df)       cwres_q(df)          # QQ plot
cwres_panel(df)      cwres_scatter(df)

# WRES
wres_time(df)        wres_pred(df)        wres_hist(df)
wres_q(df)

# NPDE
npde_time(df)        npde_pred(df)        npde_hist(df)
npde_q(df)           npde_panel(df)

# RES
res_time(df)         res_pred(df)         res_hist(df)
```

### Covariate Residual Plots

```julia
# CWRES vs multiple covariates
cwres_covariate(df; x="WT//Weight (kg)", y="CWRES")

# NPDE vs covariates
npde_covariate(df; x="AGE//Age (years)")
```

## ETA Plots

```julia
# ETA vs continuous covariate
eta_cont(df; x="WT//Weight (kg)", y="ETA1//CL")

# ETA vs categorical covariate
eta_cat(df; x="SEXf//Sex", y="ETA1//CL")

# ETA histogram
eta_hist(df; x="ETA1//CL")

# ETA pairs (correlation matrix)
eta_pairs(df)

# ETA vs multiple covariates at once
eta_covariate(df; x=["WT//Weight", "AGE//Age"], y=["ETA1//CL", "ETA2//V"])
```

## Covariate Plots

```julia
# Continuous vs continuous scatter
cont_cont(df; x="WT//Weight (kg)", y="ALB//Albumin (g/dL)")

# Continuous vs categorical boxplot
cont_cat(df; x="SEXf//Sex", y="WT//Weight (kg)")

# Histogram
cont_hist(df; x="WT//Weight (kg)")

# Scatter with pmplots styling
pm_scatter(df; x="WT", y="CL")
pm_box(df; x="SEXf", y="CL")
```

## The `col//label` Syntax

pmplots uses `"COLUMN//Axis Label"` strings to specify both the data column and its axis title:

```julia
# Column name on the left, label on the right
dv_pred(df; x="PRED//Population Predicted", y="DV//Observed Concentration")
eta_cont(df; x="WT//Weight (kg)", y="ETA1//CL ETA")
```

If you omit the `//`, the column name is used as the label:

```julia
eta_cont(df; x="WT", y="ETA1")  # axes labeled "WT" and "ETA1"
```

See the [SpecKit Integration](yspec.md) page for automatic label generation from yspec metadata.

## Faceted (Wrapped) Plots

```julia
wrap_cont_cont(df)    wrap_cont_time(df)    wrap_res_time(df)
wrap_eta_cont(df)     wrap_hist(df)         wrap_dv_preds(df)
wrap_cont_cat(df)
```

## Layout

Arrange multiple plots in a grid:

```julia
plots = [dv_pred(df), cwres_time(df), npde_pred(df), eta_hist(df)]
grid = pm_grid(plots; ncol=2)
```

Programmatically generate plots for multiple variables:

```julia
# Plot CWRES vs each covariate
covar_labels = ["WT//Weight (kg)", "AGE//Age (years)", "SCR//Serum Cr (mg/dL)"]
plots = list_plot_x(df, (d; x) -> cwres_cont(d; x=x), covar_labels)
pm_grid(plots; ncol=3)
```

## Complete Diagnostic Panel Example

```julia
using ShowKit, DataFrames

# Load your NONMEM output
df = CSV.read("run001.csv", DataFrame)

# Standard GOF panel
gof = pm_grid([
    dv_pred(df) + ggtitle("DV vs PRED"),
    dv_ipred(df) + ggtitle("DV vs IPRED"),
    cwres_time(df) + ggtitle("CWRES vs TIME"),
    cwres_pred(df) + ggtitle("CWRES vs PRED"),
]; ncol=2)

# ETA diagnostics
etas = pm_grid([
    eta_hist(df; x="ETA1//CL"),
    eta_hist(df; x="ETA2//V"),
    eta_cont(df; x="WT//Weight (kg)", y="ETA1//CL"),
    eta_cont(df; x="AGE//Age (years)", y="ETA1//CL"),
]; ncol=2)

# Save both
mrggsave(gof, "gof-panel"; dir="deliv/figure", dev=["pdf", "png"])
mrggsave(etas, "eta-panel"; dir="deliv/figure", dev=["pdf", "png"])
```
