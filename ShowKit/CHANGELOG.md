# Changelog

All notable changes to ShowKit.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Curried `stable()`/`stable_long()` now accept keyword arguments**. Their curried forms were defined as zero-argument (`stable_long() = tbl -> stable_long(tbl)`), so piping into them with arguments — `tbl |> stable_long(lt_cap_label="tab-x")` — raised `MethodError: no method matching stable_long(; lt_cap_label::String)`. They now follow the same `f(; kwargs...) = tbl -> f(tbl; kwargs...)` pattern as every `st_*` modifier.
- **pmtables keyword names are no longer mangled into dot names**. All pmtables wrappers translated `note_config` to `note.config`, `lt_cap_label` to `lt.cap.label`, and so on, using the ggplot2 dot convention. pmtables' API is snake_case throughout (50+ arguments) and its keyword names double as data frame column names, which are usually snake_case too. Because `stable()`, `stable_long()`, and the `pt_*` constructors all take `...`, the mangled names were absorbed silently: `lt_cap_label` produced no `\label{}`, and `st_align(keyfile_value=col_ragged(2))` silently fell back to the default alignment instead of setting a 2 cm ragged column. pmtables call sites now route through `_pmtables_to_r_name`, which keeps underscores literal and translates only a leading underscore to a leading dot (`_default` becomes `.default`, as before). ggplot2, pmplots, and mrggsave translation is unchanged.

  This is breaking for code that worked around the old behavior with the `__` escape (`lt__cap__label`); write such names plainly now.

### Changed
- **`stable_save` can render longtables**: `stable_save(tbl::PMTable, path)` and `stable_save(tbl::PMTable; kwargs...)` accept `longtable=true` to render with `pmtables::stable_long()` instead of `pmtables::stable()`, so a table built for a longtable is no longer silently saved in a `tabular` environment.
- **pmtables Symbol columns**: DataFrame columns containing Julia `Symbol` values are converted to strings at the R boundary, allowing grouped repeat clearing and other dplyr-backed modifiers to compare report labels safely.
- **`mrggsave`/`mrggsave_list` script provenance**: when `script` is omitted, the "Source code" annotation is now auto-detected from the `.jl` file that called `mrggsave` (via the call stack), instead of defaulting to the literal `"ShowKit"`. Called from an interactive session (REPL, `julia -e`, or a notebook cell) with no `script`, it now raises an `ArgumentError` asking for an explicit `script` rather than stamping a meaningless source. Passing `script=` explicitly is unchanged.

### Added
- **Manual pmtables column widths**: `st_align`, `col_fixed`, and `col_ragged` expose upstream pmtables' default/per-column alignment and fixed-width column specifications.
- **Repeat clearing**: `tab_clear_reps(data, cols...; grouped=false)` exposes immediate DataFrame-level repeat suppression, `st_clear_grouped(cols...)` wraps hierarchical pipeline suppression, and `st_clear_reps` now accepts multiple string or symbol columns.
- **Inline pmtables previews**: `PMTable` and `LaTeXTable` now provide PNG rich-display output through `st2png`, so VS Code and Jupyter automatically show rendered tables in their preview pane. Rendering restores the R `stable` vector class, escapes literal carets outside math mode, and uses the supported `pdflatex` plus `pdftools` toolchain rather than requiring a separate DVI toolchain.
- **vpc wrappers**: `vpc()`, `vpc_cens()`, `vpc_cat()`, `vpc_tte()` wrapping Ron Keizer's [vpc](https://vpc.ronkeizer.com/) R package for Visual Predictive Checks. Pass `sim` and `obs` as Julia `DataFrame`s; all other kwargs forward to R with underscore→dot translation. Returns `GGPlot` for `+` composition with theme/labs/etc. Auto-installs from CRAN (with GitHub fallback) on first use.
- **`pm_grid` varargs method**: `pm_grid(p1, p2, p3, p4; ncol=2)` now works alongside the existing `Vector{GGPlot}` form, matching the natural R `pmplots::pm_grid(...)` calling style.

## [0.1.0] - 2026-03-31

### Added
- **ggplot2 wrapping**: `GGPlot` and `GGLayer` types with `Base.:+` operator chaining that delegates to R's `+.gg` S3 method. `ggplot()`, `aes()` with Julia Symbol column mapping.
- **100+ auto-generated wrappers**: Metaprogramming loop generates Julia functions for all ggplot2 geoms (`geom_point`, `geom_line`, etc.), scales, coordinates, stats, positions, and guides.
- **Theme system**: Hand-written `theme()`, `element_text()`, `element_blank()`, `element_rect()`, `element_line()`, and all preset themes (`theme_bw`, `theme_minimal`, etc.).
- **Faceting**: `facet_wrap(cols; kwargs...)` and `facet_grid(rows, cols)` with Symbol, Vector{Symbol}, and R formula string inputs.
- **Labels**: `labs()`, `xlab()`, `ylab()`, `ggtitle()`.
- **Escape hatch**: `gg(:any_function; kwargs...)` for calling unwrapped ggplot2 functions and extensions.
- **Kwarg translation**: Automatic underscore-to-dot conversion (`axis_text_x` becomes `axis.text.x`). Double underscore `__` escapes to literal underscore.
- **pmplots wrappers**: 40+ pharmacometric diagnostic functions — `dv_pred`, `cwres_time`, `eta_cont`, `eta_cat`, `pm_grid`, and all residual/covariate variants. All return `GGPlot` for further `+` customization.
- **pmtables wrappers**: `pt_cont_wide`, `pt_cat_wide`, `pt_demographics`, `pt_data_inventory` and more. Pipeline `st_*()` modifiers (`st_units`, `st_notes`, `st_caption`) with curried forms for `|>` piping. `stable()` and `stable_long()` render to `LaTeXTable`. `stable_save()` writes `.tex` files.
- **mrggsave wrappers**: `mrggsave(plot, stem; ...)` and `mrggsave_list(plots; stems, ...)` for provenance-annotated figure saving to PDF/PNG.
- **YspecJL integration**: `axis_col_labs(spec, cols)` generates pmplots `"COL//Label [unit]"` strings from yspec metadata. `col_label(spec, col)` for display labels. Duck-typed (no hard YspecJL dependency).
- **Display**: PNG and SVG rendering via `ggsave()` for VS Code and Jupyter inline display. Configurable via `set_display_size()`.
- **Runtime R detection**: Same pattern as YspecJL — discovers `Main.CondaR` at runtime, no hard dependency on CondaR/RCall.
- **CondaPkg.toml**: Declares r-ggplot2 and all tidyverse deps via conda-forge. MetrumRG packages (pmplots, pmtables, mrggsave) auto-install from GitHub on first use.
- **SSL fix in CondaR**: Sets `CURL_CA_BUNDLE` to conda env's `cacert.pem` so R's libcurl can reach CRAN and GitHub.
