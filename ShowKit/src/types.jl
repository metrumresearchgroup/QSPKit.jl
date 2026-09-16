# ============================================================
# Core Types
# ============================================================

"""
    GGPlot

A Julia wrapper around an R ggplot2 plot object. Supports `+` operator
chaining with `GGLayer` objects, just like R's ggplot2.

# Example
```julia
p = ggplot(df, aes(x=:TIME, y=:DV)) +
    geom_point() +
    theme_bw()
```
"""
struct GGPlot
    robject::Any    # RCall.RObject — the R ggplot object on the R heap
end

"""
    GGLayer

A ggplot2 layer, theme, scale, or other modifier that can be added to a
`GGPlot` via the `+` operator.
"""
struct GGLayer
    robject::Any    # RCall.RObject — the R layer object
    name::Symbol    # e.g., :geom_point, :theme_bw
    columns::Vector{Symbol}  # column names referenced in aes() (for validation)
end

GGLayer(robject, name::Symbol) = GGLayer(robject, name, Symbol[])

"""
    PMTable

A Julia wrapper around an R pmtables object (before rendering to LaTeX).
Supports `st_*()` pipeline functions via `|>`.
"""
struct PMTable
    robject::Any    # RCall.RObject — the R pmtable object
end

"""
    LaTeXTable

A rendered LaTeX table string from `stable()` or `stable_long()`.
"""
struct LaTeXTable
    latex::String
end

# ---- + operator for ggplot2 chaining ----

function Base.:+(p::GGPlot, layer::GGLayer)
    new_robj = _rcall(Symbol("+"), p.robject, layer.robject)
    GGPlot(new_robj)
end

function Base.:+(p::GGPlot, layers::Vector{GGLayer})
    foldl(+, layers; init=p)
end

# Allow GGLayer + GGLayer to produce a combined layer (for pre-building layer sets)
function Base.:+(a::GGLayer, b::GGLayer)
    new_robj = _rcall(Symbol("+"), a.robject, b.robject)
    GGLayer(new_robj, :combined)
end
