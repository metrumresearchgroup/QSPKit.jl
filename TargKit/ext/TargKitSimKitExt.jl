module TargKitSimKitExt

# Lets TargKit match targets against SimKit results directly. A scan result is
# labelled by its scanned values, and a SimContext contributes its last phase's
# solution: the same phase `to_dataframe` reports.

using ..TargKit
using ..SimKit: SimContext, PopulationResult

TargKit.match_source(ctx::SimContext) = _last_solution(ctx)

TargKit.match_source(results::Vector{<:NamedTuple{(:params, :result)}}) =
    TargKit.KeyedResults([Dict{Symbol, Any}(e.params) => e.result for e in results])

TargKit.match_source(::PopulationResult) = throw(TargKit.MatchError(
    "cannot match targets against a PopulationResult yet; convert it with to_dataframe(...)"))

function _last_solution(ctx::SimContext)
    isempty(ctx.phases) && throw(TargKit.MatchError(
        "the SimContext has no simulated phases; call simulate(...) before matching targets"))
    return ctx.phases[end].sol
end

end # module TargKitSimKitExt
