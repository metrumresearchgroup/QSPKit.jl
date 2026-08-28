module BookKitTargKitExt

# Teaches `book_extract` how to book a TargKit fit result with zero ceremony:
# status from convergence, metrics from loss/report, and dependency fingerprints
# for the parameters and the producing source code (the latter computed inside
# TargKit.fit() and carried on FitResult.source_fp).

using BookKit
using TargKit: FitResult
using SHA

function BookKit.book_extract(r::FitResult)
    fps = Dict{String,String}("params" => _params_hash(r.params))
    r.source_fp !== nothing && (fps["source"] = r.source_fp)

    metrics = Dict{String,Any}("loss" => r.loss, "method" => String(r.method))
    if r.report !== nothing
        metrics["n_met"] = r.report.n_met
        metrics["n_total"] = r.report.n_total
        metrics["total_loss"] = r.report.total_loss
    end

    return (kind = :fit,
            payload = r,
            status_hint = r.converged ? :accepted : :rejected,
            fingerprints = fps,
            metrics = metrics,
            fit_quality = r.report,
            inputs = String[])
end

# Bit-exact, order-independent hash of a Float64 parameter dict: sorted keys, each
# value hashed by its raw UInt64 bit pattern (reproducible, and correct for
# -0.0/NaN unlike a printed representation).
function _params_hash(p::Dict{Symbol,Float64})
    io = IOBuffer()
    for k in sort(collect(keys(p)); by=string)
        print(io, string(k), "=")
        write(io, reinterpret(UInt64, p[k]))
        print(io, ";")
    end
    return bytes2hex(sha256(take!(io)))
end

end # module BookKitTargKitExt
