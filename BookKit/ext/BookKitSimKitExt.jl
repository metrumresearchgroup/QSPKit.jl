module BookKitSimKitExt

# Teaches `book_extract` to book a SimKit simulation as a `:prediction` with
# in-memory dependency fingerprints. The MTK system is a RuntimeGeneratedFunction
# (invisible to IR source tracing), so the model is fingerprinted *structurally*
# from its equations. Solver config, parameters, and dosing events are
# fingerprinted too. All are in-memory deps → diff-at-rebook staleness.

using BookKit
using SimKit: SimContext, PopulationResult
using ModelingToolkit: equations
using SHA

function BookKit.book_extract(c::SimContext)
    fps = Dict{String,String}()

    # Structural model fingerprint (order-independent over equations).
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
            payload = c,
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
            payload = pr,
            status_hint = :accepted,
            fingerprints = fps,
            metrics = Dict{String,Any}("n_subjects" => length(ctxs)),
            fit_quality = nothing,
            inputs = String[])
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
