# ============================================================
# pmplots — ETA Plots
# ============================================================

const PMPLOTS_ETA_FUNCTIONS = [
    :eta_cont, :eta_cat, :eta_hist, :eta_pairs,
    :eta_covariate, :eta_covariate_list,
]

const PMPLOTS_ETA_LITERAL_KWARGS = (:tag_levels,)

function _ggplot_or_list(robj)
    is_plot = _rcopy(Bool, _rcall(
        _reval("function(x) inherits(x, c('gg', 'ggplot', 'ggmatrix', 'patchwork'))"),
        robj,
    ))
    is_plot && return GGPlot(robj)
    return _ggplot_list(robj)
end

for fn in PMPLOTS_ETA_FUNCTIONS
    @eval begin
        @doc """
            $($fn)(data::DataFrame, args...; kwargs...)

        Thin wrapper around `pmplots::$($fn)()`. All arguments forwarded to R.
        See [pmplots documentation](https://metrumresearchgroup.github.io/pmplots/reference/$($fn).html) for details.

        Returns a `GGPlot` when pmplots returns one plot, otherwise
        `Vector{GGPlot}` for vectorized ETA displays.
        """
        function $(fn)(data::DataFrame, args...; kwargs...)
            _require_pmplots()
            r_data = _robject(plot_data(data))
            robj = _rcall_pkg(
                "pmplots",
                $(QuoteNode(fn)),
                (r_data, args...),
                kwargs;
                literal_kwargs=PMPLOTS_ETA_LITERAL_KWARGS,
            )
            _ggplot_or_list(robj)
        end
        export $(fn)
    end
end
