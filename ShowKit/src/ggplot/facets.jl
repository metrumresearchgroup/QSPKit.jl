# ============================================================
# ggplot2 Facets — facet_wrap(), facet_grid()
# ============================================================

"""
    facet_wrap(cols::Union{Symbol, Vector{Symbol}}; kwargs...) -> GGLayer

Wrap panels by one or more variables.

# Example
```julia
p + facet_wrap(:STUDY)
p + facet_wrap([:STUDY, :SEX]; ncol=2)
```
"""
function facet_wrap(cols::Symbol; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::facet_wrap")
    r_formula = _reval("~ $(cols)")
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => v)
    end
    robj = if isempty(r_kwargs)
        _rcall(r_fn, r_formula)
    else
        _rcall(r_fn, r_formula; r_kwargs...)
    end
    GGLayer(robj, :facet_wrap)
end

function facet_wrap(cols::Vector{Symbol}; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::facet_wrap")
    formula_str = "~ " * join(string.(cols), " + ")
    r_formula = _reval(formula_str)
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => v)
    end
    robj = if isempty(r_kwargs)
        _rcall(r_fn, r_formula)
    else
        _rcall(r_fn, r_formula; r_kwargs...)
    end
    GGLayer(robj, :facet_wrap)
end

# String form for complex formulas
function facet_wrap(formula::AbstractString; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::facet_wrap")
    r_formula = _reval(formula)
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => v)
    end
    robj = if isempty(r_kwargs)
        _rcall(r_fn, r_formula)
    else
        _rcall(r_fn, r_formula; r_kwargs...)
    end
    GGLayer(robj, :facet_wrap)
end

"""
    facet_grid(rows, cols; kwargs...) -> GGLayer
    facet_grid(formula::String; kwargs...) -> GGLayer

Create a grid of panels by row and column variables.

# Example
```julia
p + facet_grid(:SEX, :STUDY)
p + facet_grid("SEX ~ STUDY")
```
"""
function facet_grid(rows::Symbol, cols::Symbol; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::facet_grid")
    r_formula = _reval("$(rows) ~ $(cols)")
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => v)
    end
    robj = if isempty(r_kwargs)
        _rcall(r_fn, r_formula)
    else
        _rcall(r_fn, r_formula; r_kwargs...)
    end
    GGLayer(robj, :facet_grid)
end

function facet_grid(formula::AbstractString; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::facet_grid")
    r_formula = _reval(formula)
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => v)
    end
    robj = if isempty(r_kwargs)
        _rcall(r_fn, r_formula)
    else
        _rcall(r_fn, r_formula; r_kwargs...)
    end
    GGLayer(robj, :facet_grid)
end

# Single-variable facet_grid (rows ~ .)
function facet_grid(rows::Symbol; kwargs...)
    facet_grid("$(rows) ~ ."; kwargs...)
end
