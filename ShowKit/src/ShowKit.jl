"""
    ShowKit

*"Show it"* — ggplot2, pmplots, pmtables, and mrggsave for Julia via R.

Wraps pharmacometric plotting and tabling R packages,
providing Julia-native types (`GGPlot`, `GGLayer`, `PMTable`) with `+` operator
chaining, display integration, and yspec metadata support.

# Quick Start
```julia
using ShowKit      # automatically loads R via CondaR

p = ggplot(df, aes(x=:TIME, y=:DV)) +
    geom_point() +
    theme_bw() +
    labs(x="Time (hr)", y="Concentration (ng/mL)")
```

"""
module ShowKit

using DataFrames
using CondaR

# R backend (uses CondaR directly)
include("r_backend.jl")

# Core types (GGPlot, GGLayer, PMTable, LaTeXTable, + operator)
include("types.jl")

# Plot data boundary helpers
include("plot_data.jl")

# Kwarg utilities (underscore → dot conversion, R function calling)
include("kwarg_utils.jl")

# ---- ggplot2 ----
include("ggplot/core.jl")
include("ggplot/generated.jl")
include("ggplot/themes.jl")
include("ggplot/facets.jl")
include("ggplot/labels.jl")
include("ggplot/escape.jl")

# ---- pmplots ----
include("pmplots/diagnostics.jl")
include("pmplots/eta_plots.jl")
include("pmplots/covariate.jl")
include("pmplots/layout.jl")

# ---- pmtables ----
include("pmtables/tables.jl")
include("pmtables/pipeline.jl")
include("pmtables/render.jl")

# ---- mrggsave ----
include("mrggsave/save.jl")

# ---- vpc ----
include("vpc/vpc.jl")

# ---- npde ----
include("npde/autonpde.jl")

# ---- Display (Base.show for all types, MIME rendering) ----
include("display.jl")

# ---- Yspec integration (works with any YspecMetadata-like object) ----
include("yspec_integration.jl")

function __init__()
    _check_rcall()
end

# ============================================================
# Exports
# ============================================================

# Types
export GGPlot, GGLayer, PMTable, LaTeXTable

# ggplot2 core
export ggplot, aes

# ggplot2 themes (hand-written)
export theme, element_text, element_blank, element_rect, element_line

# ggplot2 facets
export facet_wrap, facet_grid

# ggplot2 labels
export labs, xlab, ylab, ggtitle

# ggplot2 escape hatch + base R utilities
export gg, r_gg, factor

# pmplots layout
export pm_grid, list_plot_x

# pmtables constructors
export st_new, pt_cont_wide, pt_cont_long, pt_cat_wide, pt_cat_long
export pt_demographics, pt_data_inventory

# pmtables pipeline
export st_units, st_notes, st_caption, st_files
export st_panel, st_align, st_center, st_blank, st_noteconf, st_span_split, st_as_image
export st_span, st_rename, st_bold, tab_clear_reps
export st_clear_reps, st_clear_grouped, col_fixed, col_ragged

# pmtables render
export stable, stable_long, stable_save, st2png

# mrggsave
export mrggsave, mrggsave_list

# vpc — exported from src/vpc/vpc.jl: vpc, vpc_cens, vpc_cat, vpc_tte

# Yspec bridge
export axis_col_labs, col_label, ys_factors, ys_factors!

# R backend status
export r_available

# Display config
export set_display_size

# NOTE: geom_*, scale_*, coord_*, stat_*, position_*, guide_*,
# theme_bw/minimal/classic/etc., and pmplots functions are exported
# from their respective generated.jl / diagnostics.jl / etc. files

end # module
