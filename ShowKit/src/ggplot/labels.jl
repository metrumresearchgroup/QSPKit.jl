# ============================================================
# ggplot2 Labels — labs(), xlab(), ylab(), ggtitle()
# ============================================================

"""
    labs(; kwargs...) -> GGLayer

Set plot labels (title, subtitle, x, y, color, fill, etc.).

# Example
```julia
p + labs(x="Time (hr)", y="Concentration (ng/mL)", title="PK Profile")
```
"""
function labs(; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::labs")
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => v)
    end
    robj = _rcall(r_fn; r_kwargs...)
    GGLayer(robj, :labs)
end

"""
    xlab(label::AbstractString) -> GGLayer
"""
function xlab(label::AbstractString)
    _require_ggplot2()
    robj = _rcall(_reval("ggplot2::xlab"), label)
    GGLayer(robj, :xlab)
end

"""
    ylab(label::AbstractString) -> GGLayer
"""
function ylab(label::AbstractString)
    _require_ggplot2()
    robj = _rcall(_reval("ggplot2::ylab"), label)
    GGLayer(robj, :ylab)
end

"""
    ggtitle(title::AbstractString; subtitle=nothing) -> GGLayer
"""
function ggtitle(title::AbstractString; subtitle=nothing)
    _require_ggplot2()
    r_fn = _reval("ggplot2::ggtitle")
    if isnothing(subtitle)
        robj = _rcall(r_fn, title)
    else
        robj = _rcall(r_fn, title; subtitle=subtitle)
    end
    GGLayer(robj, :ggtitle)
end
