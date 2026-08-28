# ============================================================
# pmplots — Covariate/Scatter Plots
# ============================================================

const PMPLOTS_COVARIATE_FUNCTIONS = [
    :cont_cont, :cont_cat, :cont_hist,
    :pm_scatter, :pm_box,
]

for fn in PMPLOTS_COVARIATE_FUNCTIONS
    @eval begin
        @doc """
            $($fn)(data::DataFrame, args...; kwargs...)

        Thin wrapper around `pmplots::$($fn)()`. All arguments forwarded to R.
        See [pmplots documentation](https://metrumresearchgroup.github.io/pmplots/reference/$($fn).html) for details.

        Returns a `GGPlot`.
        """
        function $(fn)(data::DataFrame, args...; kwargs...)
            _require_pmplots()
            r_data = _robject(plot_data(data))
            robj = _rcall_pkg("pmplots", $(QuoteNode(fn)), (r_data, args...), kwargs)
            GGPlot(robj)
        end
        export $(fn)
    end
end
