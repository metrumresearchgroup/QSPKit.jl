# ============================================================
# ggplot2 Themes — theme(), element_*(), preset themes
# ============================================================

# ---- Preset themes (simple wrappers returning GGLayer) ----

const THEME_PRESETS = [
    :theme_bw, :theme_minimal, :theme_classic, :theme_void,
    :theme_grey, :theme_gray, :theme_light, :theme_dark,
    :theme_linedraw, :theme_test,
]

for fn in THEME_PRESETS
    @eval begin
        @doc """
            $($fn)(; kwargs...)

        Apply the `$($fn)` preset theme. Wrapper around `ggplot2::$($fn)()`.
        See [ggplot2 documentation](https://ggplot2.tidyverse.org/reference/$($fn).html) for details.
        """
        function $(fn)(args...; kwargs...)
            robj = _rcall_gg($(QuoteNode(fn)), args, kwargs)
            GGLayer(robj, $(QuoteNode(fn)))
        end
        export $(fn)
    end
end

# ---- theme() — the customization function ----

"""
    theme(; kwargs...) -> GGLayer

Customize ggplot2 theme elements. Underscores in keyword names are converted to dots.

# Example
```julia
theme(
    axis_text_x = element_text(angle=45, hjust=1),
    legend_position = "bottom",
    panel_background = element_blank()
)
```
"""
function theme(; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::theme")
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        rval = _convert_value(v)
        push!(r_kwargs, rname => rval)
    end
    robj = _rcall(r_fn; r_kwargs...)
    GGLayer(robj, :theme)
end

# ---- element_*() functions — return raw R objects for use in theme() ----

"""
    element_text(; kwargs...) -> R element_text object

Create a ggplot2 text element specification for use in `theme()`.

# Example
```julia
theme(axis_title = element_text(size=14, face="bold"))
```
"""
function element_text(; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::element_text")
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => v)
    end
    if isempty(r_kwargs)
        _rcall(r_fn)
    else
        _rcall(r_fn; r_kwargs...)
    end
end

"""
    element_blank() -> R element_blank object

Create a blank element (removes the element from the plot).
"""
function element_blank()
    _require_ggplot2()
    _rcall(_reval("ggplot2::element_blank"))
end

"""
    element_rect(; kwargs...) -> R element_rect object

Create a rectangle element specification for use in `theme()`.
"""
function element_rect(; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::element_rect")
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => v)
    end
    if isempty(r_kwargs)
        _rcall(r_fn)
    else
        _rcall(r_fn; r_kwargs...)
    end
end

"""
    element_line(; kwargs...) -> R element_line object

Create a line element specification for use in `theme()`.
"""
function element_line(; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::element_line")
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => v)
    end
    if isempty(r_kwargs)
        _rcall(r_fn)
    else
        _rcall(r_fn; r_kwargs...)
    end
end
