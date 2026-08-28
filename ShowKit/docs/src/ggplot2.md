# ggplot2

ShowKit wraps R's ggplot2 with Julia-native types and the same `+` chaining syntax. Every plot object is a real ggplot2 object on the R heap — ShowKit delegates rendering to R, not a Julia reimplementation.

## How It Works

When you write:

```julia
p = ggplot(df, aes(x=:TIME, y=:DV)) + geom_point() + theme_bw()
```

ShowKit:
1. Converts the Julia DataFrame to an R data.frame via RCall
2. Calls `ggplot2::ggplot()` and `ggplot2::aes()` in R, wraps result as `GGPlot`
3. Calls `ggplot2::geom_point()` and `ggplot2::theme_bw()`, wraps as `GGLayer`
4. Each `+` calls R's `+.gg` S3 method via `rcall(Symbol("+"), plot, layer)`
5. Display triggers `ggplot2::ggsave()` to a temp PNG, which is shown inline

## Available Functions

ShowKit auto-generates wrappers for 100+ ggplot2 functions via metaprogramming.

### Geoms

All standard ggplot2 geoms are available:

```julia
geom_point()        geom_line()         geom_bar()          geom_col()
geom_boxplot()      geom_violin()       geom_jitter()
geom_histogram()    geom_density()      geom_freqpoly()     geom_dotplot()
geom_smooth()       geom_rug()
geom_hline()        geom_vline()        geom_abline()
geom_ribbon()       geom_area()         geom_step()
geom_errorbar()     geom_errorbarh()
geom_crossbar()     geom_pointrange()   geom_linerange()
geom_text()         geom_label()
geom_tile()         geom_rect()         geom_raster()
geom_polygon()      geom_path()
geom_segment()      geom_curve()
geom_contour()      geom_contour_filled()
geom_hex()          geom_bin2d()
geom_density_2d()   geom_density_2d_filled()
geom_qq()           geom_qq_line()
geom_sf()           geom_sf_text()      geom_sf_label()
geom_spoke()        geom_quantile()
geom_map()          geom_blank()
```

### Scales

```julia
# Position
scale_x_continuous()    scale_y_continuous()
scale_x_discrete()      scale_y_discrete()
scale_x_log10()         scale_y_log10()
scale_x_sqrt()          scale_y_sqrt()
scale_x_reverse()       scale_y_reverse()
scale_x_date()          scale_y_date()
scale_x_datetime()      scale_y_datetime()
scale_x_binned()        scale_y_binned()

# Color/Fill
scale_color_manual()    scale_fill_manual()
scale_color_brewer()    scale_fill_brewer()
scale_color_gradient()  scale_fill_gradient()
scale_color_gradient2() scale_fill_gradient2()
scale_color_viridis_c() scale_fill_viridis_c()
scale_color_viridis_d() scale_fill_viridis_d()
scale_color_grey()      scale_fill_grey()
scale_color_continuous() scale_fill_continuous()
scale_color_discrete()  scale_fill_discrete()
# ... and more (colour variants also available)

# Other aesthetics
scale_alpha()           scale_size()
scale_shape()           scale_linetype()
```

### Coordinates

```julia
coord_cartesian()   coord_fixed()   coord_flip()
coord_polar()       coord_sf()      coord_trans()
coord_map()         coord_quickmap()
```

### Stats

```julia
stat_count()    stat_bin()      stat_density()    stat_smooth()
stat_ecdf()     stat_ellipse()  stat_function()   stat_qq()
stat_summary()  stat_summary_bin()
# ... and more
```

### Positions

```julia
position_dodge()    position_dodge2()   position_fill()
position_identity() position_jitter()   position_jitterdodge()
position_nudge()    position_stack()
```

### Guides and Annotations

```julia
annotate()          guides()
guide_legend()      guide_colorbar()    guide_axis()    guide_none()
expand_limits()     lims()              xlim()          ylim()
```

## Themes In Depth

### Preset Themes

```julia
theme_bw()          theme_minimal()     theme_classic()
theme_void()        theme_grey()        theme_gray()
theme_light()       theme_dark()        theme_linedraw()
```

### Custom Theme Elements

The `theme()` function accepts keyword arguments with automatic underscore-to-dot conversion:

```julia
p + theme(
    # Text elements
    axis_title = element_text(size=14),
    axis_text_x = element_text(angle=45, hjust=1, size=10),
    plot_title = element_text(face="bold", size=16),
    strip_text = element_text(size=12),

    # Remove elements
    legend_title = element_blank(),
    panel_grid_minor = element_blank(),

    # Rectangle elements
    panel_background = element_rect(fill="white"),
    plot_background = element_rect(fill="grey95"),

    # Line elements
    axis_line = element_line(color="black", linewidth=0.5),

    # Positioning
    legend_position = "bottom",          # "top", "bottom", "left", "right", "none"
    legend_direction = "horizontal",
)
```

### Element Functions

| Function | Purpose | Key args |
|----------|---------|----------|
| `element_text()` | Text styling | `size`, `face`, `color`, `angle`, `hjust`, `vjust`, `family` |
| `element_rect()` | Rectangle styling | `fill`, `color`, `linewidth`, `linetype` |
| `element_line()` | Line styling | `color`, `linewidth`, `linetype`, `arrow` |
| `element_blank()` | Remove element | (no args) |

## Faceting In Depth

### `facet_wrap()`

Wraps panels in a 1D sequence:

```julia
p + facet_wrap(:STUDY)                    # single variable
p + facet_wrap([:STUDY, :SEX])            # multiple variables
p + facet_wrap(:STUDY; ncol=3)            # control columns
p + facet_wrap(:STUDY; scales="free_y")   # independent y-axes
p + facet_wrap("~ STUDY + SEX")           # R formula string
```

### `facet_grid()`

Arranges panels in a 2D grid:

```julia
p + facet_grid(:SEX, :STUDY)              # rows ~ cols
p + facet_grid(:SEX)                       # rows ~ . (columns free)
p + facet_grid("SEX ~ STUDY")             # R formula string
p + facet_grid(:SEX, :STUDY; scales="free")
```

## Labels

```julia
p + labs(
    x = "Time (hr)",
    y = "Concentration (ng/mL)",
    color = "Study",
    title = "PK Concentration-Time Profile",
    subtitle = "All subjects, all doses",
    caption = "Source: synthetic example",
)

# Shortcuts
p + xlab("Time (hr)")
p + ylab("Concentration")
p + ggtitle("My Title"; subtitle="Draft")
```

## Extension Packages

ggplot2 extensions (ggrepel, ggforce, patchwork, ggdist, etc.) work via the
escape hatch when they are already present in the application-managed R
environment. Provision a reviewed version outside ShowKit; the package does not
install extensions at runtime.

```julia
# After provisioning ggrepel in the selected R environment:
p + gg(:geom_text_repel; mapping=aes(label=:ID))
```

## Programmatic Plot Construction

Since layers are just objects, you can build plots programmatically:

```julia
# Conditional layers
layers = GGLayer[]
push!(layers, geom_point())
if show_smooth
    push!(layers, geom_smooth(method="loess"))
end
push!(layers, theme_bw())

p = ggplot(df, aes(x=:TIME, y=:DV)) + layers
```

## Display Configuration

Control how plots render in VS Code / Jupyter:

```julia
set_display_size(width=10.0, height=8.0, dpi=300)
```

Default is 7x5 inches at 150 DPI.
