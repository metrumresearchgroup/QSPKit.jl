# ShowKit.jl

*"Show it"* — ggplot2, pmplots, pmtables, and mrggsave for Julia via R.

## Features

- **ggplot2 with `+` chaining** — Same syntax as R: `ggplot() + geom_point() + theme_bw()`
- **230+ auto-generated wrappers** — All geoms, scales, coords, stats, positions, diagnostics
- **pmplots diagnostics** — `dv_pred()`, `cwres_time()`, `eta_cont()` and 60+ more
- **pmtables pipeline** — `pt_cont_wide() |> st_units() |> stable()` with curried forms
- **mrggsave provenance** — Annotated figure saving with script/filename stamps
- **SpecKit integration** — Auto-generate labels and units from yspec metadata

## Quick Start

```julia
using CondaR       # loads bundled R
using ShowKit
using DataFrames

df = DataFrame(TIME=0:0.5:24, DV=rand(49), PRED=rand(49))

p = ggplot(df, aes(x=:TIME, y=:DV)) +
    geom_point(alpha=0.6) +
    geom_smooth(method="loess") +
    theme_bw() +
    labs(x="Time (hr)", y="Concentration (ng/mL)")
```

## How It Works

ShowKit is a thin Julia layer over R packages. No R code is re-implemented in Julia.

### Architecture

```
Julia code                    R runtime (managed by CondaR)
───────────                   ──────────────────────────────────
ggplot(df, aes(...))    →     CondaR/RCall  →  ggplot2::ggplot(df, aes(...))
  + geom_point()        →     CondaR/RCall  →  R's +.gg operator
  + theme_bw()          →     CondaR/RCall  →  ggplot2::theme_bw()
display (VS Code)       →     ggsave → tempfile → PNG bytes → Julia IO
```

### R installation and packages

CondaR provisions a private MicroMamba R runtime and a separate R package library
for the consuming project. Project mode reads `pkgr.yml`; latest mode uses the
documented default repositories. Source package installation completes before
embedded R starts. See the [CondaR reference](../CondaR/README.md) for details.

### Runtime Wrapper Generation

All 230+ wrapper functions (`geom_point`, `scale_x_log10`, `dv_pred`, `cwres_time`, etc.) are generated at module parse time via `@eval` loops. Each wrapper:

1. Calls the R function by name (e.g., `ggplot2::geom_point`)
2. Forwards all positional and keyword arguments to R
3. Translates Julia naming conventions to R: `axis_text_x` → `axis.text.x` (underscore → dot)
4. Wraps the R result in `GGLayer` or `GGPlot`

The functions themselves are identical to R — all arguments, defaults, and behaviors come from the underlying R package. See the linked R documentation in each function's docstring.

### Keyword Argument Translation

Julia uses underscores; R uses dots. ShowKit auto-translates:

| Julia | R |
|-------|---|
| `axis_text_x` | `axis.text.x` |
| `legend_position` | `legend.position` |
| `panel_grid_major` | `panel.grid.major` |

To keep a literal underscore (rare), use double underscore: `my__var` → `my_var`.

## R environment

R and its packages are provisioned automatically on first use, following the
consuming project's `pkgr.yml` when present. CondaR owns a private installation;
project renv libraries are not used or modified.

```julia
using ShowKit
ShowKit.configure_r!(mode=:latest)   # optional: ignore pkgr.yml
ShowKit.configure_r!(mode=:project)  # default: follow project policy
```

The selection persists in `LocalPreferences.toml`. A switch prepares the new
library and reports whether Julia must be restarted. See the
[CondaR setup reference](../CondaR/README.md) for configuration, installation,
version tracking, and troubleshooting.

## License

MIT
