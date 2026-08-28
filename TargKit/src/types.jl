# ============================================================
# Types — v2 DataFrame-based calibration targets
# ============================================================

# ============================================================
# Stage — one step in an optimization pipeline
# ============================================================

"""
    Stage(solver; maxiters, restarts=1)

One solver stage in a fitting strategy. `solver` is an Optimization.jl solver,
`maxiters` bounds each run, and `restarts` repeats the stage from its best point.
"""
struct Stage
    solver      # any Optimization.jl solver
    maxiters::Int
    restarts::Int
end

Stage(solver; maxiters::Int, restarts::Int=1) = Stage(solver, maxiters, restarts)

# ============================================================
# ScoreReport — scoring output (DataFrame-based details)
# ============================================================

"""
    ScoreReport

Summary returned by [`score`](@ref). `total_loss` is the summed target loss;
`n_met` and `n_total` count targets with configured ranges; and `details` holds
the target-level predictions, observations, losses, range results, and metadata.
"""
struct ScoreReport
    total_loss::Float64
    n_met::Int
    n_total::Int
    details::DataFrame  # :name, :predicted, :value, :loss, :in_range, + metadata
end

# ============================================================
# Prepared convention-scoring plan
# ============================================================

struct PreparedConventionTargets
    names::Vector{Symbol}
    values::Vector{Any}
    series_log_values::Vector{Any}
    lowers::Vector{Float64}
    uppers::Vector{Float64}
    weights::Vector{Float64}
    row_losses::Vector{Any}
    conditions::Union{Nothing, Vector{Any}}
    variables::Union{Nothing, Vector{Any}}
    timepoints::Union{Nothing, Vector{Any}}
    series_plan::Any
end

struct PreparedSeriesPlan
    names::Vector{Symbol}
    conditions::Union{Nothing, Vector{Any}}
    variables::Vector{Any}
    times::Vector{Any}
    observed::Vector{Any}
    observed_logs::Vector{Any}
    weights::Vector{Float64}
    loss_types::Vector{Symbol}
end

# ============================================================
# FitResult — output of fit()
# ============================================================

"""
    FitResult

Result returned by [`fit`](@ref), containing natural-scale fitted parameters,
the final loss, an optional [`ScoreReport`](@ref), convergence and method
metadata, and an optional source fingerprint.
"""
struct FitResult
    params::Dict{Symbol, Float64}
    loss::Float64
    report::Union{ScoreReport, Nothing}
    converged::Bool
    method::Symbol   # :pso_nm, :custom, etc.
    # Per-method source fingerprint of the objective closure (combined hash), or
    # `nothing` if not computed. Lets provenance tooling detect code-change
    # staleness without coupling TargKit to a provenance package.
    source_fp::Union{String, Nothing}
end

# Back-compatible 5-arg constructor (source_fp defaults to nothing).
FitResult(params, loss, report, converged, method) =
    FitResult(params, loss, report, converged, method, nothing)

# ============================================================
# ObjectiveFunction — internal callable for optimization
# ============================================================

struct ObjectiveFunction
    target_pairs::Vector{Pair{DataFrame, Function}}  # df => predict_fn
    prepared_targets::Union{Nothing, Vector{PreparedConventionTargets}}
    simulate::Function
    param_names::Vector{Symbol}
    bounds::NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}}
    log_bounds::NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}}
    failure_penalty::Float64
    on_eval::Union{Function, Nothing}
    bounds_penalty::Union{Float64, Nothing}
    default_loss::Union{Symbol, Function}
    _param_scale::Any
    _param_keys::Any
    _eval_count::Base.RefValue{Int}
    _best_loss::Base.RefValue{Float64}
    _eval_lock::ReentrantLock
end

(obj::ObjectiveFunction)(x) = _evaluate_objective(x, obj)
(obj::ObjectiveFunction)(x, p) = _evaluate_objective(x, obj)
