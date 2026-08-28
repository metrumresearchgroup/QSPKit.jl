# ============================================================
# pmplots — Diagnostic Plots
# ============================================================

# ---- Generated wrappers for standard diagnostic functions ----

# DV plots
const PMPLOTS_DV_FUNCTIONS = [
    :dv_pred, :dv_ipred,
    :dv_time, :dv_tad, :dv_tafd,
]

const PMPLOTS_DV_LIST_FUNCTIONS = [
    :dv_preds, :dv_pred_ipred,
]

# Residual/CWRES/WRES/NPDE plots
const PMPLOTS_RESID_FUNCTIONS = [
    # CWRES variants
    :cwres_time, :cwres_tad, :cwres_tafd, :cwres_pred,
    :cwres_cont, :cwres_cat, :cwres_hist, :cwres_q,
    :cwres_panel, :cwres_scatter,
    :cwres_covariate,
    # CWRESI variants
    :cwresi_time, :cwresi_tad, :cwresi_tafd, :cwresi_pred,
    :cwresi_cont, :cwresi_cat, :cwresi_hist, :cwresi_q,
    # WRES variants
    :wres_time, :wres_tad, :wres_tafd, :wres_pred,
    :wres_cont, :wres_cat, :wres_hist, :wres_q,
    # RES variants
    :res_time, :res_tad, :res_tafd, :res_pred,
    :res_cont, :res_cat, :res_hist, :res_q,
    # NPDE variants
    :npde_time, :npde_tad, :npde_tafd, :npde_pred,
    :npde_cont, :npde_cat, :npde_hist, :npde_q,
    :npde_panel, :npde_scatter,
    :npde_covariate,
]

const PMPLOTS_Q_FUNCTIONS = (:cwres_q, :cwresi_q, :wres_q, :res_q, :npde_q)

# Wrapped plots (faceted)
const PMPLOTS_WRAP_FUNCTIONS = [
    :wrap_cont_cont, :wrap_cont_time, :wrap_res_time,
    :wrap_eta_cont, :wrap_hist, :wrap_dv_preds, :wrap_cont_cat,
]

function _split_pmplots_col_label(value)
    value isa AbstractString || return value, nothing
    parts = split(value, "//"; limit=2)
    length(parts) == 2 || return value, nothing
    return parts[1], parts[2]
end

function _pmplots_diagnostic_kwargs(fn::Symbol, kwargs)
    fn in PMPLOTS_Q_FUNCTIONS || return kwargs, nothing
    normalized = Pair{Symbol, Any}[]
    y_label = nothing
    use_y_as_x = haskey(kwargs, :y) && !haskey(kwargs, :x)

    for (k, v) in kwargs
        if k === :x || (k === :y && use_y_as_x)
            col, label = _split_pmplots_col_label(v)
            y_label = label === nothing ? y_label : label
            push!(normalized, :x => col)
        elseif k !== :y
            push!(normalized, k => v)
        end
    end
    return normalized, y_label
end

function _ggplot_list(robj)
    n = _rcopy(Int, _rcall(_reval("length"), robj))
    return [GGPlot(_rcall(Symbol("[["), robj, i)) for i in 1:n]
end

for fn in vcat(PMPLOTS_DV_FUNCTIONS, PMPLOTS_RESID_FUNCTIONS, PMPLOTS_WRAP_FUNCTIONS)
    @eval begin
        @doc """
            $($fn)(data::DataFrame, args...; kwargs...)

        Thin wrapper around `pmplots::$($fn)()`. Pass a DataFrame as the first argument;
        all additional arguments and keyword arguments are forwarded to R.
        See [pmplots documentation](https://metrumresearchgroup.github.io/pmplots/reference/$($fn).html) for details.

        Column mappings use the `col//label` syntax (e.g., `"CWRES//Conditional weighted residual"`).

        Returns a `GGPlot`.
        """
        function $(fn)(data::DataFrame, args...; kwargs...)
            _require_pmplots()
            r_data = _robject(plot_data(data))
            pm_kwargs, qq_y_label = _pmplots_diagnostic_kwargs($(QuoteNode(fn)), kwargs)
            robj = _rcall_pkg("pmplots", $(QuoteNode(fn)), (r_data, args...), pm_kwargs)
            if qq_y_label !== nothing
                robj = _rcall(Symbol("+"), robj, _rcall(_reval("ggplot2::ylab"), qq_y_label))
            end
            GGPlot(robj)
        end
        export $(fn)
    end
end

for fn in PMPLOTS_DV_LIST_FUNCTIONS
    @eval begin
        @doc """
            $($fn)(data::DataFrame, args...; kwargs...) -> Vector{GGPlot}

        Thin wrapper around `pmplots::$($fn)()`. This pmplots function returns
        a list of ggplot objects, so ShowKit returns `Vector{GGPlot}`.
        """
        function $(fn)(data::DataFrame, args...; kwargs...)
            _require_pmplots()
            r_data = _robject(plot_data(data))
            robj = _rcall_pkg("pmplots", $(QuoteNode(fn)), (r_data, args...), kwargs)
            _ggplot_list(robj)
        end
        export $(fn)
    end
end
