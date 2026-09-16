module BookKitBayesKitExt

# Teaches `book_extract` to book a BayesKit posterior result. The reproducibility
# seed (BayesResult.rng_seed) is captured as an in-memory dependency fingerprint —
# under strict reproducibility a reseed reads as a changed input. Bayes runs have
# no convergence flag (convergence is advisory via diagnostics), so status_hint is
# :accepted; pass status= to override.

using BookKit
using BayesKit: BayesResult

function BookKit.book_extract(r::BayesResult)
    # Strip the live log_density runtime before storing: it holds closures/runtime
    # state that JLD2 can't portably serialize (and bloats the blob / makes the
    # result_hash non-deterministic). The stripped result keeps samples, specs,
    # diagnostics, and rng_seed.
    return (kind = :fit,
            payload = BayesKit.strip_log_density(r),
            status_hint = :accepted,
            fingerprints = Dict{String,String}("seed" => string(r.rng_seed)),
            metrics = Dict{String,Any}(
                "n_chains"   => r.n_chains,
                "n_subjects" => r.n_subjects,
                "wall_time"  => r.wall_time,
            ),
            fit_quality = nothing,
            inputs = String[])
end

end # module BookKitBayesKitExt
