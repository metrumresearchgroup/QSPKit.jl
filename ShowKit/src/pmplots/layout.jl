# ============================================================
# pmplots — Layout Functions
# ============================================================

"""
    pm_grid(plots::Vector{GGPlot}; ncol=2, kwargs...) -> GGPlot

Arrange multiple ggplot objects in a grid layout (via pmplots::pm_grid).
"""
function pm_grid(plots::Vector{GGPlot}; ncol=2, kwargs...)
    _require_pmplots()
    isempty(plots) && throw(ArgumentError("ShowKit.pm_grid requires at least one plot"))
    # Build an R list of plot objects
    r_list = _reval("list()")
    for (i, p) in enumerate(plots)
        r_list = _rcall(Symbol("[[<-"), r_list, i, p.robject)
    end
    r_fn = _reval("pmplots::pm_grid")
    r_kwargs = Pair{Symbol, Any}[]
    push!(r_kwargs, :ncol => ncol)
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => _convert_value(v))
    end
    robj = _rcall(r_fn, r_list; r_kwargs...)
    GGPlot(robj)
end

"""
    pm_grid(plots::GGPlot...; ncol=2, kwargs...) -> GGPlot

Varargs convenience: `pm_grid(p1, p2, p3, p4; ncol=2)` forwards to the
`Vector{GGPlot}` method.
"""
pm_grid(plots::GGPlot...; kwargs...) = pm_grid(collect(GGPlot, plots); kwargs...)

"""
    list_plot_x(data::DataFrame, fn::Function, x_vars::Vector{String}; kwargs...) -> Vector{GGPlot}

Apply a plot function over a vector of x-variable names, returning a vector of plots.
Useful for generating covariate plots programmatically.
"""
function list_plot_x(data::DataFrame, fn, x_vars::Vector{String}; kwargs...)
    [fn(data; x=xv, kwargs...) for xv in x_vars]
end
