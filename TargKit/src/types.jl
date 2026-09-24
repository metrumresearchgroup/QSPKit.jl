# ============================================================
# Types — v2 DataFrame-based calibration targets
# ============================================================

# ============================================================
# Stage — one step in an optimization pipeline
# ============================================================

struct Stage
    solver      # any Optimization.jl solver
    maxiters::Int
    restarts::Int
end

Stage(solver; maxiters::Int, restarts::Int=1) = Stage(solver, maxiters, restarts)

# ============================================================
# ScoreReport — scoring output (DataFrame-based details)
# ============================================================

struct ScoreReport
    total_loss::Float64
    n_met::Int
    n_total::Int
    details::DataFrame  # :name, :predicted, :value, :loss, :in_range, + metadata
end

# ============================================================
# FitResult — output of fit()
# ============================================================

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
    simulate::Function
    param_names::Vector{Symbol}
    bounds::NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}}
    log_bounds::NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}}
    failure_penalty::Float64
    on_eval::Union{Function, Nothing}
    print_every::Union{Int, Nothing}
    bounds_penalty::Union{Float64, Nothing}
    default_loss::Union{Symbol, Function}
    _param_scale::Any
    _param_keys::Any
    _eval_count::Base.RefValue{Int}
    _best_loss::Base.RefValue{Float64}
    _eval_lock::ReentrantLock
    _stage_label::Base.RefValue{String}   # set by _run_stage, shown in print_every lines
    _start_time::Base.RefValue{Float64}
end

(obj::ObjectiveFunction)(x) = _evaluate_objective(x, obj)
(obj::ObjectiveFunction)(x, p) = _evaluate_objective(x, obj)
