# API Reference

## Types

```@docs
GGPlot
GGLayer
PMTable
LaTeXTable
```

## ggplot2 Core

```@docs
ggplot
aes
```

## ggplot2 Themes

```@docs
theme
element_text
element_blank
element_rect
element_line
```

## ggplot2 Facets

```@docs
facet_wrap
facet_grid
```

## ggplot2 Labels

```@docs
labs
xlab
ylab
ggtitle
```

## ggplot2 Escape Hatch

```@docs
gg
```

## pmplots — Diagnostic Plots

### DV Plots
- `dv_pred(data; kwargs...)` — DV vs PRED
- `dv_ipred(data; kwargs...)` — DV vs IPRED
- `dv_preds(data; kwargs...)` — DV vs PRED and IPRED combined
- `dv_time(data; kwargs...)` — DV vs TIME
- `dv_tad(data; kwargs...)` — DV vs time after dose
- `dv_tafd(data; kwargs...)` — DV vs time after first dose

### Residual Plots
- `cwres_time`, `cwres_tad`, `cwres_tafd`, `cwres_pred` — CWRES variants
- `cwres_cont`, `cwres_cat`, `cwres_hist`, `cwres_q` — CWRES distributions
- `cwres_panel`, `cwres_scatter`, `cwres_covariate` — CWRES panels
- `wres_*`, `res_*`, `npde_*`, `cwresi_*` — same pattern for other residual types

### ETA Plots
- `eta_cont(data; x, y, kwargs...)` — ETA vs continuous covariate
- `eta_cat(data; x, y, kwargs...)` — ETA vs categorical covariate
- `eta_hist(data; x, kwargs...)` — ETA histogram
- `eta_pairs(data; kwargs...)` — ETA pairs correlation plot
- `eta_covariate(data; kwargs...)` — ETA vs multiple covariates

### Covariate Plots
- `cont_cont(data; kwargs...)` — continuous vs continuous scatter
- `cont_cat(data; kwargs...)` — continuous vs categorical boxplot
- `cont_hist(data; kwargs...)` — continuous histogram
- `pm_scatter(data; kwargs...)` — general scatter
- `pm_box(data; kwargs...)` — general boxplot

### Layout

```@docs
pm_grid
list_plot_x
```

## pmtables — Table Constructors

```@docs
pt_cont_wide
pt_cont_long
pt_cat_wide
pt_cat_long
pt_demographics
pt_data_inventory
```

## pmtables — Pipeline

```@docs
st_units
st_notes
st_caption
st_files
st_span
st_rename
st_bold
st_clear_reps
```

## pmtables — Rendering

```@docs
stable
stable_long
stable_save
st2png
```

## mrggsave API

```@docs
mrggsave
mrggsave_list
```

## SpecKit Integration

```@docs
axis_col_labs
col_label
```

## Configuration

```@docs
r_available
set_display_size
```

## Complete exported API inventory

This reviewed inventory includes the wrappers exported from ShowKit's included
generator files. The test suite compares it with the module's runtime exports,
and the SDLC traceability matrix covers every entry below.

```text
GGLayer
GGPlot
LaTeXTable
PMTable
add_npde!
aes
after_scale
after_stat
annotate
annotation_custom
annotation_logticks
autonpde
axis_col_labs
col_fixed
col_label
col_ragged
cont_cat
cont_cont
cont_hist
coord_cartesian
coord_equal
coord_fixed
coord_flip
coord_map
coord_polar
coord_quickmap
coord_sf
coord_trans
cwres_cat
cwres_cont
cwres_covariate
cwres_hist
cwres_panel
cwres_pred
cwres_q
cwres_scatter
cwres_tad
cwres_tafd
cwres_time
cwresi_cat
cwresi_cont
cwresi_hist
cwresi_pred
cwresi_q
cwresi_tad
cwresi_tafd
cwresi_time
dv_ipred
dv_pred
dv_pred_ipred
dv_preds
dv_tad
dv_tafd
dv_time
element_blank
element_line
element_rect
element_text
eta_cat
eta_cont
eta_covariate
eta_covariate_list
eta_hist
eta_pairs
expand_limits
expansion
facet_grid
facet_wrap
factor
geom_abline
geom_area
geom_bar
geom_bin2d
geom_blank
geom_boxplot
geom_col
geom_contour
geom_contour_filled
geom_crossbar
geom_curve
geom_density
geom_density2d
geom_density_2d
geom_density_2d_filled
geom_dotplot
geom_errorbar
geom_errorbarh
geom_freqpoly
geom_hex
geom_histogram
geom_hline
geom_jitter
geom_label
geom_line
geom_linerange
geom_map
geom_path
geom_point
geom_pointrange
geom_polygon
geom_qq
geom_qq_line
geom_quantile
geom_raster
geom_rect
geom_ribbon
geom_rug
geom_segment
geom_sf
geom_sf_label
geom_sf_text
geom_smooth
geom_spoke
geom_step
geom_text
geom_tile
geom_violin
geom_vline
gg
ggplot
ggtitle
guide_axis
guide_bins
guide_colorbar
guide_colorsteps
guide_colourbar
guide_coloursteps
guide_legend
guide_none
guides
labs
lims
list_plot_x
margin
mrggsave
mrggsave_list
npde_cat
npde_cont
npde_covariate
npde_hist
npde_panel
npde_pred
npde_q
npde_scatter
npde_tad
npde_tafd
npde_time
plot_data
pm_box
pm_grid
pm_scatter
position_dodge
position_dodge2
position_fill
position_identity
position_jitter
position_jitterdodge
position_nudge
position_stack
pt_cat_long
pt_cat_wide
pt_cont_long
pt_cont_wide
pt_data_inventory
pt_demographics
r_available
r_gg
rel
res_cat
res_cont
res_hist
res_pred
res_q
res_tad
res_tafd
res_time
scale_alpha
scale_alpha_continuous
scale_alpha_discrete
scale_alpha_manual
scale_color_brewer
scale_color_continuous
scale_color_discrete
scale_color_distiller
scale_color_gradient
scale_color_gradient2
scale_color_gradientn
scale_color_grey
scale_color_identity
scale_color_manual
scale_color_viridis_c
scale_color_viridis_d
scale_colour_brewer
scale_colour_continuous
scale_colour_discrete
scale_colour_distiller
scale_colour_gradient
scale_colour_gradient2
scale_colour_gradientn
scale_colour_grey
scale_colour_identity
scale_colour_manual
scale_colour_viridis_c
scale_colour_viridis_d
scale_fill_brewer
scale_fill_continuous
scale_fill_discrete
scale_fill_distiller
scale_fill_gradient
scale_fill_gradient2
scale_fill_gradientn
scale_fill_grey
scale_fill_identity
scale_fill_manual
scale_fill_viridis_c
scale_fill_viridis_d
scale_linetype
scale_linetype_identity
scale_linetype_manual
scale_shape
scale_shape_identity
scale_shape_manual
scale_size
scale_size_area
scale_size_continuous
scale_size_discrete
scale_size_manual
scale_x_binned
scale_x_continuous
scale_x_date
scale_x_datetime
scale_x_discrete
scale_x_log10
scale_x_reverse
scale_x_sqrt
scale_x_time
scale_y_binned
scale_y_continuous
scale_y_date
scale_y_datetime
scale_y_discrete
scale_y_log10
scale_y_reverse
scale_y_sqrt
scale_y_time
set_display_size
st2png
st_align
st_as_image
st_blank
st_bold
st_caption
st_center
st_clear_grouped
st_clear_reps
st_files
st_new
st_noteconf
st_notes
st_panel
st_rename
st_span
st_span_split
st_units
stable
stable_long
stable_save
stage
stat_bin
stat_bin2d
stat_bin_hex
stat_boxplot
stat_contour
stat_contour_filled
stat_count
stat_density
stat_density_2d
stat_density_2d_filled
stat_ecdf
stat_ellipse
stat_function
stat_identity
stat_qq
stat_qq_line
stat_quantile
stat_smooth
stat_summary
stat_summary_bin
stat_unique
stat_ydensity
tab_clear_reps
theme
theme_bw
theme_classic
theme_dark
theme_gray
theme_grey
theme_light
theme_linedraw
theme_minimal
theme_test
theme_void
unit
vpc
vpc_cat
vpc_cens
vpc_tte
wrap_cont_cat
wrap_cont_cont
wrap_cont_time
wrap_dv_preds
wrap_eta_cont
wrap_hist
wrap_res_time
wres_cat
wres_cont
wres_hist
wres_pred
wres_q
wres_tad
wres_tafd
wres_time
xlab
xlim
ylab
ylim
ys_factors
ys_factors!
```
