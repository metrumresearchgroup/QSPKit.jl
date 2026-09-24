# ============================================================
# Default progress callback
# ============================================================

function _default_on_eval(n, loss, params, is_best)
    if is_best || n % 50 == 0
        tag = is_best ? " ***" : ""
        println("  [eval $n] loss=$(round(loss, digits=4))$tag")
        flush(stdout)
    end
end

# ============================================================
# objective() — build ObjectiveFunction from df => predict_fn pairs
# ============================================================

"""
    objective(pairs...; simulate, params, bounds, kwargs...) -> ObjectiveFunction

Build a callable objective function for optimization.

    obj = objective(
        baseline => predict_fn;
        simulate = overrides -> ...,
        params = [:k6, :k13],
        bounds = get_bounds(keyfile, params),
    )

Pass `print_every = N` to print a status line (eval count, current stage, loss,
best loss, elapsed time) every `N` objective evaluations, across all fit stages.
"""
function objective(
    pairs::Pair{<:AbstractDataFrame, <:Function}...;
    simulate::Function,
    params::Vector{Symbol},
    bounds::NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}},
    loss::Union{Symbol, Function} = :log,
    failure_penalty::Float64 = 1e10,
    on_eval::Union{Function, Nothing} = nothing,
    print_every::Union{Integer, Nothing} = nothing,
    bounds_penalty::Union{Float64, Nothing} = nothing,
    parameter_scale::Symbol = :log,
)
    length(bounds.lb) == length(params) || error("bounds.lb length ($(length(bounds.lb))) must match params length ($(length(params)))")
    length(bounds.ub) == length(params) || error("bounds.ub length ($(length(bounds.ub))) must match params length ($(length(params)))")

    log_bounds = _objective_transformed_bounds(bounds, parameter_scale)
    target_pairs = [Pair{DataFrame, Function}(DataFrame(df), fn) for (df, fn) in pairs]

    return ObjectiveFunction(
        target_pairs,
        simulate,
        params,
        bounds,
        log_bounds,
        failure_penalty,
        on_eval,
        _check_print_every(print_every),
        bounds_penalty,
        loss,
        Val(parameter_scale),
        Val(Tuple(params)),
        Ref(0),
        Ref(Inf),
        ReentrantLock(),
        Ref(""),
        Ref(time()),
    )
end

function _check_print_every(print_every)
    isnothing(print_every) && return nothing
    print_every > 0 || throw(ArgumentError("print_every must be a positive integer or nothing, got $print_every"))
    return Int(print_every)
end

function _objective_transformed_bounds(bounds, parameter_scale::Symbol)
    if parameter_scale == :log
        return (lb = log.(bounds.lb), ub = log.(bounds.ub))
    elseif parameter_scale == :identity
        return (lb = copy(bounds.lb), ub = copy(bounds.ub))
    else
        throw(ArgumentError("parameter_scale must be :log or :identity, got :$parameter_scale"))
    end
end

# ============================================================
# _evaluate_objective — the core evaluation
# ============================================================

function _evaluate_objective(x::AbstractVector, obj::ObjectiveFunction)
    # Soft bounds penalty (early return for NelderMead)
    if !isnothing(obj.bounds_penalty)
        penalty = _compute_bounds_penalty(x, obj.log_bounds, obj.bounds_penalty)
        if penalty > 0
            loss = 1e6 + penalty
            _fire_on_eval(obj, loss, x)
            return loss
        end
    end

    overrides = _objective_overrides!(obj, x)

    # Call simulate. Exceptions propagate; explicit `nothing` remains the
    # signal for callers that intentionally want the configured failure penalty.
    ctx = obj.simulate(overrides)
    if isnothing(ctx) || _failed_matched_simulation(obj, ctx)
        _fire_on_eval(obj, obj.failure_penalty, x)
        return obj.failure_penalty
    end

    total = _evaluate_pair_objective_loss(ctx, obj)

    _fire_on_eval(obj, total, x)
    return total
end

# A failed ODE solve inside matched output gets failure_penalty, like `nothing`.
_failed_matched_simulation(obj::ObjectiveFunction, ctx) =
    any(p -> last(p) isa MatchPredictor, obj.target_pairs) && _has_failed_solution(_normalize_source(ctx))

function _evaluate_pair_objective_loss(ctx, obj::ObjectiveFunction)
    total = 0.0
    for (df, predict_fn) in obj.target_pairs
        batch = _batch_predictions(predict_fn, ctx, df)
        for (i, row) in enumerate(eachrow(df))
            predicted = batch === nothing ? predict_fn(ctx, row) : batch[i]
            lt = _resolve_loss_type(row, obj.default_loss)
            w = _resolve_weight(row)

            if lt == :range_only
                has_lower = hasproperty(row, :lower) && !ismissing(row.lower) && !isnan(row.lower)
                has_upper = hasproperty(row, :upper) && !ismissing(row.upper) && !isnan(row.upper)
                total += (!has_lower || !has_upper) ? w * 1e6 : compute_loss_range_only(predicted, row.lower, row.upper, w)
            else
                total += compute_loss(predicted, row.value, lt, w)
            end
        end
    end
    return total
end

# ============================================================
# Bounds penalty
# ============================================================

function _compute_bounds_penalty(x, log_bounds, coeff)
    penalty = 0.0
    for i in eachindex(x)
        if x[i] < log_bounds.lb[i]
            penalty += coeff * (log_bounds.lb[i] - x[i])^2
        elseif x[i] > log_bounds.ub[i]
            penalty += coeff * (x[i] - log_bounds.ub[i])^2
        end
    end
    return penalty
end

# ============================================================
# on_eval callback
# ============================================================

function _fire_on_eval(obj::ObjectiveFunction, loss, x)
    isnothing(obj.on_eval) && isnothing(obj.print_every) && return nothing

    eval_count, is_best, best_loss = lock(obj._eval_lock) do
        obj._eval_count[] += 1
        is_best = loss < obj._best_loss[]
        is_best && (obj._best_loss[] = loss)
        obj._eval_count[], is_best, obj._best_loss[]
    end

    if !isnothing(obj.print_every) && eval_count % obj.print_every == 0
        _print_eval_status(obj, eval_count, loss, best_loss)
    end
    isnothing(obj.on_eval) || obj.on_eval(eval_count, loss, _objective_params_snapshot(obj, x), is_best)
    return nothing
end

function _print_eval_status(obj::ObjectiveFunction, n, loss, best_loss)
    stage = obj._stage_label[]
    stage_str = isempty(stage) ? "" : " | $stage"
    elapsed = round(time() - obj._start_time[]; digits=1)
    println("  [eval $n$stage_str] loss=$(round(loss; sigdigits=6)) best=$(round(best_loss; sigdigits=6)) ($(elapsed)s)")
    flush(stdout)
end

@generated function _objective_overrides_from_keys(::Val{keys}, ::Val{scale}, x) where {keys, scale}
    values = if scale == :log
        [:(exp(x[$i])) for i in 1:length(keys)]
    elseif scale == :identity
        [:(x[$i]) for i in 1:length(keys)]
    else
        throw(ArgumentError("parameter_scale must be :log or :identity, got :$scale"))
    end
    return :(NamedTuple{$keys}(($(values...),)))
end

function _objective_overrides!(obj::ObjectiveFunction, x)
    return _objective_overrides_from_keys(obj._param_keys, obj._param_scale, x)
end

_objective_param_value(::Val{:log}, x, i) = exp(x[i])
_objective_param_value(::Val{:identity}, x, i) = x[i]

function _objective_params_snapshot(obj::ObjectiveFunction, x)
    params = Dict{Symbol, Float64}()
    @inbounds for i in eachindex(obj.param_names)
        params[obj.param_names[i]] = _objective_param_value(obj._param_scale, x, i)
    end
    return params
end

# ============================================================
# reset!
# ============================================================

"""
    reset!(obj::ObjectiveFunction)

Reset the evaluation counter, best loss tracker, and `print_every` clock.
"""
function reset!(obj::ObjectiveFunction)
    lock(obj._eval_lock) do
        obj._eval_count[] = 0
        obj._best_loss[] = Inf
        obj._stage_label[] = ""
        obj._start_time[] = time()
    end
    nothing
end

# ============================================================
# TargetSet-based objective
# ============================================================

"""
    objective(ts::TargetSet...; simulate, match, at, variable, params, bounds, kwargs...) -> ObjectiveFunction
    objective(ts::TargetSet...; simulate, predict, params, bounds, kwargs...) -> ObjectiveFunction
    objective(ts => Match(...), ...; simulate, params, bounds, kwargs...) -> ObjectiveFunction

Build a callable objective function from TargetSets.

`simulate` receives parameter overrides and returns the simulation output. Say
how the TargetSets' rows line up with it: `match`/`at`/`variable` (see `Match`),
or `predict = (sim, row) -> value`. With several TargetSets that line up
differently, pair each with its own `Match` or predict function.

Each TargetSet's rows use that TargetSet's loss; `loss` overrides them all. A
per-row `loss` column wins over both.
"""
function objective(
    targets_in::TargetSet...;
    predict=nothing,
    match=nothing,
    at=nothing,
    variable=nothing,
    kwargs...,
)
    mapping = _keyword_mapping(predict, match, at, variable, "objective")
    return objective((ts => mapping for ts in targets_in)...; kwargs...)
end

function objective(
    pairs::Pair{TargetSet}...;
    simulate::Function,
    params::Vector{Symbol},
    bounds::NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}},
    loss::Union{Symbol, Function, Nothing} = nothing,
    failure_penalty::Float64 = 1e10,
    on_eval::Union{Function, Nothing} = nothing,
    print_every::Union{Integer, Nothing} = nothing,
    bounds_penalty::Union{Float64, Nothing} = nothing,
    parameter_scale::Symbol = :log,
)
    bound = Pair{DataFrame, Function}[]
    for (ts, mapping) in pairs
        df, predictor = _bind(ts, mapping, "objective")
        if :loss ∉ propertynames(df)
            # Series targets keep their automatic series loss.
            row_loss = something(loss, ts.loss)
            df[!, :loss] = Any[_is_series_value(v) ? missing : row_loss for v in df.value]
        end
        push!(bound, df => predictor)
    end
    default_loss = something(loss, isempty(pairs) ? :log : first(first(pairs)).loss)

    return objective_from_pairs(
        bound;
        simulate=simulate,
        params=params,
        bounds=bounds,
        loss=default_loss,
        failure_penalty=failure_penalty,
        on_eval=on_eval,
        print_every=print_every,
        bounds_penalty=bounds_penalty,
        parameter_scale=parameter_scale,
    )
end

"""Internal: build ObjectiveFunction from pre-built pairs."""
function objective_from_pairs(
    pairs::Vector{Pair{DataFrame, Function}};
    simulate, params, bounds, loss, failure_penalty, on_eval, bounds_penalty,
    print_every=nothing,
    parameter_scale=:log,
)
    length(bounds.lb) == length(params) || error("bounds.lb length must match params length")
    length(bounds.ub) == length(params) || error("bounds.ub length must match params length")

    log_bounds = _objective_transformed_bounds(bounds, parameter_scale)

    return ObjectiveFunction(
        pairs,
        simulate,
        params,
        bounds,
        log_bounds,
        failure_penalty,
        on_eval,
        _check_print_every(print_every),
        bounds_penalty,
        loss,
        Val(parameter_scale),
        Val(Tuple(params)),
        Ref(0),
        Ref(Inf),
        ReentrantLock(),
        Ref(""),
        Ref(time()),
    )
end
