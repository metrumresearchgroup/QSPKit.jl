# Getting Started

## Installation

ShowKit is part of the QSPKit monorepo. Add it via:

```julia
using Pkg
Pkg.develop(path="path/to/QSPKit/ShowKit")
```

ShowKit requires R via CondaR. If you haven't set up CondaR yet:

```julia
Pkg.develop(path="path/to/CondaR")
using CondaR  # resolves the isolated CondaPkg R environment on first use
```

ShowKit never installs or rewrites R packages at runtime. Provision the R
packages required by the features you use before starting Julia. The committed
`CondaPkg.toml` declares conda-forge dependencies; packages installed from
other sources belong in a separately reviewed environment lock or setup step.

## First Plot

```julia
# CondaR is loaded automatically by ShowKit
using ShowKit
using DataFrames

# Create some sample data
df = DataFrame(
    TIME = repeat(0:0.5:24, 10),
    DV = rand(490),
    ID = repeat(1:10, inner=49),
    STUDY = repeat(["A", "B"], inner=245),
)

# Build a ggplot — same + chaining as R
p = ggplot(df, aes(x=:TIME, y=:DV, color=:STUDY)) +
    geom_point(alpha=0.3) +
    geom_smooth(method="loess") +
    theme_bw() +
    labs(x="Time (hr)", y="Concentration (ng/mL)")
```

In VS Code or Jupyter, the plot renders inline automatically. In the REPL, use `mrggsave()` or `ggsave()` to save to file.

## Understanding the Types

ShowKit has four core types:

| Type | What it holds | Created by | Composed with |
|------|--------------|------------|---------------|
| `GGPlot` | A complete ggplot2 plot | `ggplot()`, pmplots functions | `+` to add layers |
| `GGLayer` | A layer/theme/scale | `geom_*()`, `theme_*()`, `scale_*()` | `+` to add to GGPlot |
| `PMTable` | A pmtables table object | `pt_cont_wide()`, `pt_cat_wide()` | `\|>` with `st_*()` pipeline |
| `LaTeXTable` | Rendered LaTeX string | `stable()`, `stable_long()` | `stable_save()` to write file |

## The `+` Operator

Just like R's ggplot2, you build plots by adding layers with `+`:

```julia
# Each + adds a layer and returns a new GGPlot
p = ggplot(df, aes(x=:TIME, y=:DV))   # base plot
p = p + geom_point()                    # add points
p = p + theme_bw()                      # add theme
p = p + labs(title="My Plot")           # add labels

# Or chain them all at once (most common)
p = ggplot(df, aes(x=:TIME, y=:DV)) +
    geom_point() +
    theme_bw() +
    labs(title="My Plot")
```

You can also add a vector of layers:

```julia
my_style = [theme_bw(), labs(subtitle="Draft")]
p = ggplot(df, aes(x=:TIME, y=:DV)) + geom_point() + my_style
```

## Aesthetic Mappings with `aes()`

Map data columns to visual properties using Julia Symbols:

```julia
aes(x=:TIME, y=:DV)                      # basic x/y
aes(x=:TIME, y=:DV, color=:STUDY)        # color by group
aes(x=:TIME, y=:DV, shape=:SEX, size=:WT)  # multiple aesthetics
```

`aes()` can also be used inside individual geoms:

```julia
p = ggplot(df) +
    geom_point(aes(x=:TIME, y=:DV); alpha=0.5) +
    geom_line(aes(x=:TIME, y=:PRED); color="red")
```

## Keyword Argument Translation

R uses dots in argument names (`axis.text.x`), but Julia uses underscores. ShowKit converts automatically:

| Julia | R equivalent |
|-------|-------------|
| `axis_text_x` | `axis.text.x` |
| `legend_position` | `legend.position` |
| `panel_background` | `panel.background` |
| `strip_text` | `strip.text` |

If you need a literal underscore in R (rare), use double underscore: `my__var` becomes `my_var`.

## Themes

```julia
# Preset themes
p + theme_bw()
p + theme_minimal()
p + theme_classic()

# Custom theme modifications
p + theme(
    axis_text_x = element_text(angle=45, hjust=1),
    legend_position = "bottom",
    panel_background = element_blank(),
    plot_title = element_text(size=16, face="bold"),
)
```

## Faceting

Split plots by variables:

```julia
# Wrap by one variable
p + facet_wrap(:STUDY)
p + facet_wrap(:STUDY; ncol=3)

# Wrap by multiple variables
p + facet_wrap([:STUDY, :SEX])

# Grid layout (rows ~ cols)
p + facet_grid(:SEX, :STUDY)

# R formula string for complex cases
p + facet_grid("SEX ~ STUDY")
```

## Scales

```julia
# Log scales
p + scale_x_log10() + scale_y_log10()

# Manual colors
p + scale_color_manual(values=["#E41A1C", "#377EB8", "#4DAF4A"])

# Color brewer
p + scale_color_brewer(palette="Set1")

# Axis limits
p + scale_x_continuous(limits=[0, 24]) + scale_y_continuous(limits=[0, 100])
```

## The Escape Hatch

For any ggplot2 function not yet wrapped, use `gg()`:

```julia
# Call any ggplot2 function by name
p + gg(:geom_density_ridges; scale=0.9)
p + gg(:annotation_logticks; sides="bl")
p + gg(:geom_rug)
```

This works for ggplot2 extension packages too (ggrepel, ggforce, patchwork, etc.) as long as they're installed in R.

## Checking R Availability

```julia
r_available()  # true if CondaR is loaded and ggplot2 is installed
```

All ShowKit functions will error with a clear message if R is not available.

## How It Works Under the Hood

ShowKit does NOT reimplement R packages in Julia. Every function call forwards to R via CondaR/RCall.

### R Environment

R is installed and isolated via CondaPkg (conda-forge). Your system R,
`.Rprofile`, and `.Renviron` are not used — CondaR blanks all R environment
variables to prevent contamination. By default CondaR uses the named
`@qspkit_r` CondaPkg environment; CI runs set `JULIA_CONDAPKG_ENV` to a
disposable path.

Two `CondaPkg.toml` files declare dependencies:
- `CondaR/CondaPkg.toml` — installs `r-base >= 4.4` (the R runtime)
- `ShowKit/CondaPkg.toml` — declares ggplot2 and the conda-forge dependencies
  used by optional integrations

The pmplots, pmtables, and mrggsave packages are not installed implicitly.
Provide reviewed versions explicitly if those integrations are needed.

### Wrapper Generation

All 230+ wrapper functions are generated at module parse time via `@eval` loops. Each wrapper:
1. Calls the R function by name (e.g., `ggplot2::geom_point`)
2. Forwards all arguments and kwargs to R
3. Translates Julia naming (`axis_text_x` → `axis.text.x`)
4. Wraps the result in `GGLayer` or `GGPlot`

### Updating R Packages

Change declared constraints in `ShowKit/CondaPkg.toml`, regenerate the
environment lock in a disposable environment, and review the resulting diff.
For packages obtained outside conda-forge, record an immutable release tag or
commit in the consuming application's setup rather than installing the moving
default branch.

### Display

In VS Code or Jupyter, `GGPlot` objects render automatically via `ggsave` → temp PNG → inline display. Default size: 7x5 inches at 150 DPI. Adjust with:
```julia
set_display_size(width=10, height=7, dpi=200)
```
