# ============================================================
# vpc — Visual Predictive Checks (Ron Keizer's vpc package)
# ============================================================
#
# Wraps https://github.com/ronkeizer/vpc — see https://vpc.ronkeizer.com
# All functions return ggplot objects (`GGPlot`) that compose with `+`.

const VPC_FUNCTIONS = [
    :vpc,        # continuous data
    :vpc_cens,   # censored data (BLOQ/ALOQ)
    :vpc_cat,    # categorical data
    :vpc_tte,    # time-to-event data
]

for fn in VPC_FUNCTIONS
    @eval begin
        @doc """
            $($fn)(; sim=nothing, obs=nothing, kwargs...)

        Thin wrapper around `vpc::$($fn)()`. Pass `sim` and/or `obs` as Julia
        `DataFrame`s; all other keyword arguments are forwarded to R (with
        underscore→dot translation, e.g. `pred_corr=true` → `pred.corr=TRUE`).

        See [vpc documentation](https://vpc.ronkeizer.com/) for stratification,
        binning, prediction-correction, and CI options.

        Returns a `GGPlot`.
        """
        function $(fn)(; sim::Union{DataFrame, Nothing}=nothing,
                         obs::Union{DataFrame, Nothing}=nothing,
                         kwargs...)
            _require_vpc()
            extra = Pair{Symbol, Any}[]
            isnothing(sim) || push!(extra, :sim => _robject(plot_data(sim)))
            isnothing(obs) || push!(extra, :obs => _robject(plot_data(obs)))
            all_kwargs = vcat(extra, collect(pairs(kwargs)))
            robj = _rcall_pkg("vpc", $(QuoteNode(fn)), (), all_kwargs)
            GGPlot(robj)
        end
        export $(fn)
    end
end
