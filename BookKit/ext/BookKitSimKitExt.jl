module BookKitSimKitExt

# Teaches `book_extract` to book a SimKit simulation as a `:prediction` with
# in-memory dependency fingerprints. The stored payload is a data-only snapshot;
# executable SciML/MTK objects contain generated functions and are neither
# portable nor safe to round-trip through JLD2. The MTK system is fingerprinted
# *structurally* from its equations (Route 3), while solver config, parameters,
# and dosing events are fingerprinted separately. All are in-memory deps →
# diff-at-rebook staleness.

using ..BookKit
using ..SimKit: SimContext, PopulationResult, to_dataframe
using ModelingToolkit: equations
using SHA

function BookKit.book_extract(c::SimContext)
    fps = Dict{String,String}()

    # Route 3: structural model fingerprint (order-independent over equations).
    if c.sys !== nothing
        m = try
            bytes2hex(sha256(join(sort(string.(equations(c.sys))), "\n")))
        catch
            nothing   # non-MTK / un-introspectable sys → skip the model dimension
        end
        m !== nothing && (fps["model"] = m)
    end

    fps["solver"] = _h(string(typeof(c.solver)) * "|" * string(c.solve_kwargs))
    fps["params"] = _h(_canon_params(c))
    fps["doses"]  = _h(string(c.events))

    return (kind = :prediction,
            payload = _prediction_snapshot(c),
            status_hint = :accepted,
            fingerprints = fps,
            metrics = Dict{String,Any}(),
            fit_quality = nothing,
            inputs = String[])
end

function BookKit.book_extract(pr::PopulationResult)
    fps = Dict{String,String}()
    ctxs = pr.contexts
    if !isempty(ctxs)
        ks = sort(collect(keys(ctxs)); by=string)   # deterministic subject order
        c1 = ctxs[ks[1]]
        if c1.sys !== nothing
            m = try
                bytes2hex(sha256(join(sort(string.(equations(c1.sys))), "\n")))
            catch
                nothing
            end
            m !== nothing && (fps["model"] = m)
        end
        fps["solver"] = _h(string(typeof(c1.solver)) * "|" * string(c1.solve_kwargs))
        fps["params"] = _h(join([_canon_params(ctxs[k]) for k in ks], "||"))
        fps["doses"]  = _h(join([string(ctxs[k].events) for k in ks], "||"))
    end
    return (kind = :prediction,
            payload = _prediction_snapshot(pr),
            status_hint = :accepted,
            fingerprints = fps,
            metrics = Dict{String,Any}("n_subjects" => length(ctxs)),
            fit_quality = nothing,
            inputs = String[])
end

function _prediction_snapshot(c::SimContext)
    return (
        format = "BookKit.SimKitPrediction",
        schema_version = 1,
        kind = :sim_context,
        phases = [_phase_snapshot(phase) for phase in c.phases],
        solver = string(typeof(c.solver)),
        solve_kwargs = string(c.solve_kwargs),
        staged_parameters = _canon_params(c),
        staged_events = string(c.events),
    )
end

function _prediction_snapshot(pr::PopulationResult)
    ids = sort(collect(keys(pr.contexts)); by=string)
    error_ids = sort(collect(keys(pr.errors)); by=string)
    return (
        format = "BookKit.SimKitPrediction",
        schema_version = 1,
        kind = :population_result,
        subjects = [(id=string(id), prediction=_prediction_snapshot(pr.contexts[id])) for id in ids],
        errors = [(id=string(id), message=sprint(showerror, pr.errors[id])) for id in error_ids],
    )
end

function _phase_snapshot(phase)
    df = to_dataframe(phase.sol)
    columns = [(name=string(name), values=collect(getproperty(df, name)))
               for name in propertynames(df)]
    return (
        name = string(phase.name),
        duration = phase.duration,
        retcode = string(phase.sol.retcode),
        columns = columns,
    )
end

_h(s::AbstractString) = bytes2hex(sha256(s))

# Prefer the staged params (the human-meaningful diff between bookings); fall back
# to the problem's parameter vector when nothing is staged.
function _canon_params(c::SimContext)
    p = c.params
    if p === nothing || (p isa AbstractDict && isempty(p)) || (p isa NamedTuple && isempty(p))
        return string(c.prob.p)
    elseif p isa AbstractDict
        return join(["$(k)=$(p[k])" for k in sort(collect(keys(p)); by=string)], ";")
    elseif p isa NamedTuple
        return join(["$(k)=$(getfield(p, k))" for k in sort(collect(keys(p)); by=string)], ";")
    else
        return string(p)
    end
end

end # module BookKitSimKitExt
