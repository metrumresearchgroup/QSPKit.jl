# ============================================================
# Generated ggplot2 Wrappers — Metaprogramming
# ============================================================
# All functions follow the same pattern: forward args/kwargs to R,
# return a GGLayer. Special cases are hand-written elsewhere.

# ---- Geoms ----

const GEOM_FUNCTIONS = [
    :geom_point, :geom_line, :geom_bar, :geom_col,
    :geom_boxplot, :geom_violin, :geom_jitter,
    :geom_histogram, :geom_density, :geom_freqpoly, :geom_dotplot,
    :geom_smooth, :geom_rug,
    :geom_hline, :geom_vline, :geom_abline,
    :geom_ribbon, :geom_area, :geom_step,
    :geom_errorbar, :geom_errorbarh,
    :geom_crossbar, :geom_pointrange, :geom_linerange,
    :geom_text, :geom_label,
    :geom_tile, :geom_rect, :geom_raster,
    :geom_polygon, :geom_path,
    :geom_segment, :geom_curve,
    :geom_contour, :geom_contour_filled,
    :geom_hex, :geom_bin2d,
    :geom_density_2d, :geom_density2d, :geom_density_2d_filled,
    :geom_qq, :geom_qq_line,
    :geom_sf, :geom_sf_text, :geom_sf_label,
    :geom_spoke, :geom_quantile,
    :geom_map, :geom_blank,
]

# ---- Scales ----

const SCALE_FUNCTIONS = [
    # Position scales
    :scale_x_continuous, :scale_y_continuous,
    :scale_x_discrete, :scale_y_discrete,
    :scale_x_log10, :scale_y_log10,
    :scale_x_sqrt, :scale_y_sqrt,
    :scale_x_reverse, :scale_y_reverse,
    :scale_x_date, :scale_y_date,
    :scale_x_datetime, :scale_y_datetime,
    :scale_x_time, :scale_y_time,
    :scale_x_binned, :scale_y_binned,
    # Color/fill scales
    :scale_color_manual, :scale_fill_manual,
    :scale_color_brewer, :scale_fill_brewer,
    :scale_color_distiller, :scale_fill_distiller,
    :scale_color_gradient, :scale_fill_gradient,
    :scale_color_gradient2, :scale_fill_gradient2,
    :scale_color_gradientn, :scale_fill_gradientn,
    :scale_color_continuous, :scale_fill_continuous,
    :scale_color_discrete, :scale_fill_discrete,
    :scale_color_viridis_c, :scale_fill_viridis_c,
    :scale_color_viridis_d, :scale_fill_viridis_d,
    :scale_color_grey, :scale_fill_grey,
    :scale_color_identity, :scale_fill_identity,
    :scale_colour_manual, :scale_colour_brewer,
    :scale_colour_distiller, :scale_colour_gradient,
    :scale_colour_gradient2, :scale_colour_gradientn,
    :scale_colour_continuous, :scale_colour_discrete,
    :scale_colour_viridis_c, :scale_colour_viridis_d,
    :scale_colour_grey, :scale_colour_identity,
    # Other aesthetic scales
    :scale_alpha, :scale_alpha_continuous, :scale_alpha_discrete, :scale_alpha_manual,
    :scale_size, :scale_size_continuous, :scale_size_discrete, :scale_size_manual, :scale_size_area,
    :scale_shape, :scale_shape_manual, :scale_shape_identity,
    :scale_linetype, :scale_linetype_manual, :scale_linetype_identity,
]

# ---- Coordinates ----

const COORD_FUNCTIONS = [
    :coord_cartesian, :coord_fixed, :coord_flip,
    :coord_polar, :coord_sf, :coord_trans,
    :coord_map, :coord_quickmap, :coord_equal,
]

# ---- Stat functions ----

const STAT_FUNCTIONS = [
    :stat_count, :stat_bin, :stat_bin2d, :stat_bin_hex,
    :stat_boxplot, :stat_contour, :stat_contour_filled,
    :stat_density, :stat_density_2d, :stat_density_2d_filled,
    :stat_ecdf, :stat_ellipse, :stat_function,
    :stat_identity, :stat_qq, :stat_qq_line,
    :stat_quantile, :stat_smooth, :stat_summary,
    :stat_summary_bin, :stat_unique, :stat_ydensity,
]

# ---- Position functions ----

const POSITION_FUNCTIONS = [
    :position_dodge, :position_dodge2,
    :position_fill, :position_identity,
    :position_jitter, :position_jitterdodge,
    :position_nudge, :position_stack,
]

# ---- Annotation/Guide functions ----

const GUIDE_FUNCTIONS = [
    :annotate, :annotation_logticks, :annotation_custom,
    :guides, :guide_legend, :guide_colorbar, :guide_colourbar,
    :guide_bins, :guide_coloursteps, :guide_colorsteps,
    :guide_axis, :guide_none,
]

# ---- Misc functions ----

const MISC_FUNCTIONS = [
    :after_stat, :after_scale, :stage,
    :expansion, :expand_limits, :lims, :xlim, :ylim,
    :margin, :rel, :unit,
]

# ============================================================
# Generate all wrapper functions
# ============================================================

for fn in vcat(
    GEOM_FUNCTIONS, SCALE_FUNCTIONS, COORD_FUNCTIONS,
    STAT_FUNCTIONS, POSITION_FUNCTIONS, GUIDE_FUNCTIONS,
    MISC_FUNCTIONS,
)
    r_name = replace(string(fn), "_" => "_")  # already snake_case
    @eval begin
        @doc """
            $($fn)(args...; kwargs...)

        Thin wrapper around `ggplot2::$($fn)()`. All keyword arguments are forwarded to R.
        See [ggplot2 documentation](https://ggplot2.tidyverse.org/reference/$($fn).html) for details.

        Returns a `GGLayer` that can be added to a `GGPlot` with `+`.
        """
        function $(fn)(args...; kwargs...)
            robj = _rcall_gg($(QuoteNode(fn)), args, kwargs)
            GGLayer(robj, $(QuoteNode(fn)))
        end
        export $(fn)
    end
end
