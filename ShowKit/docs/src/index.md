# ShowKit.jl

*"Show it"* — ggplot2, pmplots, pmtables, and mrggsave for Julia via R.

## Why Use ShowKit?

Pharmacometricians already have a mature reporting ecosystem in R:

- **ggplot2** for grammar-of-graphics plotting
- **pmplots** for standardized diagnostic plots (GOF, CWRES, ETAs)
- **pmtables** for LaTeX summary tables (demographics, data inventory)
- **mrggsave** for annotated figure saving with provenance

ShowKit brings all of these into Julia with native types, `+` operator chaining, and seamless DataFrame interop — without reimplementing any of the R packages. Every plot is a real ggplot2 object rendered by R.

## The Kit Family

| Package | Tagline | Purpose |
|---------|---------|---------|
| **ConfigKit** | "Config it" | Parameter management, YAML keyfiles |
| **InjecKit** | "Inject it" | Dosing events, callbacks |
| **SimKit** | "Simulate it" | Simulation pipelines, branching |
| **TargKit** | "Target it" | Calibration targets, optimization |
| **ShowKit** | "Show it" | Plots, tables, figures via R |

## Quick Example

```julia
using ShowKit      # automatically loads R via CondaR
using DataFrames

df = DataFrame(TIME=0:0.5:24, DV=rand(49), PRED=rand(49))

# ggplot2 with Julia syntax — same + chaining you know from R
p = ggplot(df, aes(x=:TIME, y=:DV)) +
    geom_point(alpha=0.6) +
    geom_smooth(method="loess") +
    theme_bw() +
    labs(x="Time (hr)", y="Concentration (ng/mL)", title="PK Profile")

# pmplots diagnostics in one line
gof = dv_pred(df) + theme_bw()

# pmtables pipeline to LaTeX
tbl = pt_cont_wide(df; cols=[:DV, :PRED]) |>
      st_units(DV="ng/mL", PRED="ng/mL") |>
      stable

# Save with provenance annotation
mrggsave(p, "pk-profile"; dir="deliv/figure", script="analysis.jl")
```

## Key Features

| Feature | Benefit |
|---------|---------|
| **`+` operator chaining** | `ggplot() + geom_point() + theme_bw()` — identical to R syntax |
| **100+ ggplot2 functions** | All geoms, scales, coords, stats, positions auto-generated |
| **Automatic kwarg translation** | `axis_text_x` becomes `axis.text.x` in R |
| **Symbol aesthetics** | `aes(x=:TIME, y=:DV)` — Julia Symbols map to R columns |
| **pmplots diagnostics** | `dv_pred()`, `cwres_time()`, `eta_cont()` and 40+ more |
| **pmtables pipeline** | `pt_cont_wide() \|> st_units() \|> stable` with curried forms |
| **VS Code / Jupyter display** | Plots render inline via PNG/SVG |
| **SpecKit integration** | `axis_col_labs()` generates labels/units from yspec metadata |
| **Escape hatch** | `gg(:any_r_function; kwargs...)` for unwrapped functions |
| **No R reimplementation** | Every plot is real ggplot2 rendered by R via CondaR |

## Contents

- [Getting Started](getting_started.md) — Installation and first plot
- [ggplot2](ggplot2.md) — Grammar of graphics in Julia
- [pmplots](pmplots.md) — Pharmacometric diagnostic plots
- [pmtables](pmtables.md) — LaTeX summary tables
- [mrggsave](mrggsave.md) — Annotated figure saving
- [SpecKit Integration](yspec.md) — Automatic labels and units from yspec
- [API Reference](api_reference.md) — Complete function reference

## Design Philosophy

1. **Wrap, don't reimplement** — Real R ggplot2 under the hood, not a Julia clone
2. **Familiar syntax** — If you know ggplot2, you already know ShowKit
3. **Julia-native types** — `GGPlot`, `GGLayer`, `PMTable` with proper dispatch and display
4. **Composable** — Plots are objects: store them, modify them, pass them around
5. **Escape hatches** — `gg()` lets you call any ggplot2 function, even extensions
