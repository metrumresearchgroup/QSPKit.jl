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
        nothing,
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
    if isnothing(ctx)
        _fire_on_eval(obj, obj.failure_penalty, x)
        return obj.failure_penalty
    end

    # Accumulate loss across all targets. TargetSet convention objectives use a
    # prepared column-array plan; custom predictors keep the DataFrameRow path.
    total = obj.prepared_targets === nothing ?
        _evaluate_pair_objective_loss(ctx, obj) :
        _evaluate_prepared_objective_loss(ctx, obj.prepared_targets, obj.default_loss)

    _fire_on_eval(obj, total, x)
    return total
end

function _evaluate_pair_objective_loss(ctx, obj::ObjectiveFunction)
    total = 0.0
    for (df, predict_fn) in obj.target_pairs
        for row in eachrow(df)
            predicted = predict_fn(ctx, row)
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
    objective(ts::TargetSet...; simulate, predict=nothing, params, bounds, kwargs...) -> ObjectiveFunction

Build a callable objective function from TargetSets.

The `simulate` function receives parameter overrides and returns simulation results (Dict/NamedTuple).
The optional `predict` function extracts predictions: `(sim_result, row) -> value`.
Without `predict`, convention-based extraction is used.
"""
function objective(
    targets_in::TargetSet...;
    simulate::Function,
    predict=nothing,
    params::Vector{Symbol},
    bounds::NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}},
    loss::Union{Symbol, Function, Nothing} = nothing,
    failure_penalty::Float64 = 1e10,
    on_eval::Union{Function, Nothing} = nothing,
    print_every::Union{Integer, Nothing} = nothing,
    bounds_penalty::Union{Float64, Nothing} = nothing,
    parameter_scale::Symbol = :log,
)
    # Build df => predict_fn pairs from TargetSets
    predict_fn = if !isnothing(predict)
        predict
    else
        (sim, row) -> _convention_predict(sim, row)
    end

    # Use the loss from the first TargetSet if not explicitly provided.
    effective_loss = isnothing(loss) ? (isempty(targets_in) ? :log : first(targets_in).loss) : loss

    pairs = [Pair{DataFrame, Function}(DataFrame(ts.df), predict_fn) for ts in targets_in]
    prepared_targets = isnothing(predict) ? _prepare_convention_targets(targets_in, effective_loss) : nothing

    return objective_from_pairs(
        pairs;
        simulate=simulate,
        params=params,
        bounds=bounds,
        loss=effective_loss,
        failure_penalty=failure_penalty,
        on_eval=on_eval,
        print_every=print_every,
        bounds_penalty=bounds_penalty,
        parameter_scale=parameter_scale,
        prepared_targets=prepared_targets,
    )
end

"""Internal: build ObjectiveFunction from pre-built pairs."""
function objective_from_pairs(
    pairs::Vector{Pair{DataFrame, Function}};
    simulate, params, bounds, loss, failure_penalty, on_eval, bounds_penalty,
    print_every=nothing,
    parameter_scale=:log,
    prepared_targets=nothing,
)
    length(bounds.lb) == length(params) || error("bounds.lb length must match params length")
    length(bounds.ub) == length(params) || error("bounds.ub length must match params length")

    log_bounds = _objective_transformed_bounds(bounds, parameter_scale)

    return ObjectiveFunction(
        pairs,
        prepared_targets,
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

# ============================================================
# Prepared TargetSet convention objective
# ============================================================

function _prepare_convention_targets(targets_in, default_loss)
    return PreparedConventionTargets[_prepare_convention_targets(ts, default_loss) for ts in targets_in]
end

function _prepare_convention_targets(ts::TargetSet, default_loss)
    df = ts.df
    n = nrow(df)
    names = :name in propertynames(df) ? Symbol.(df[!, :name]) :
        [Symbol(:target_, i) for i in 1:n]
    values = Any[df[i, :value] for i in 1:n]
    series_log_values = Any[_series_log_values(values[i]) for i in 1:n]
    lowers = _float_column_or_default(df, :lower, NaN)
    uppers = _float_column_or_default(df, :upper, NaN)
    weights = _float_column_or_default(df, :weight, 1.0)
    row_losses = _optional_column(df, :loss; missing_value=nothing)
    row_losses === nothing && (row_losses = fill(nothing, n))
    conditions = _optional_column(df, :condition)
    variables = _optional_column(df, :variable)
    timepoints = _optional_column(df, :timepoint)
    series_plan = _prepare_series_plan(values, series_log_values, weights, row_losses,
        conditions, variables, default_loss)

    return PreparedConventionTargets(
        names, values, series_log_values, lowers, uppers, weights, row_losses,
        conditions, variables, timepoints, series_plan,
    )
end

function _prepare_series_plan(values, series_log_values, weights, row_losses,
                              conditions, variables, default_loss)
    variables === nothing && return nothing
    n = length(values)
    times = Vector{Any}(undef, n)
    observed = Vector{Any}(undef, n)
    observed_logs = Vector{Any}(undef, n)
    plan_variables = Vector{Any}(undef, n)
    loss_types = Vector{Symbol}(undef, n)

    for i in 1:n
        value = values[i]
        _is_series_value(value) || return nothing
        ismissing(variables[i]) && return nothing
        lt = _prepared_loss_type(value, row_losses[i], default_loss)
        lt isa Symbol || return nothing
        (lt == :series_log || lt == :series_mse) || return nothing
        times[i] = value.t
        observed[i] = value.y
        observed_logs[i] = series_log_values[i]
        plan_variables[i] = variables[i]
        loss_types[i] = lt
    end

    return PreparedSeriesPlan(conditions, plan_variables, times, observed,
        observed_logs, weights, loss_types)
end

function _series_log_values(value)
    _is_series_value(value) || return nothing
    y = value.y
    logs = Vector{Float64}(undef, length(y))
    @inbounds for i in eachindex(y)
        logs[i] = log(y[i])
    end
    return logs
end

function _optional_column(df::DataFrame, col::Symbol; missing_value=missing)
    col in propertynames(df) || return nothing
    source = df[!, col]
    return Any[ismissing(v) ? missing_value : v for v in source]
end

function _float_column_or_default(df::DataFrame, col::Symbol, default::Float64)
    n = nrow(df)
    out = Vector{Float64}(undef, n)
    if col in propertynames(df)
        source = df[!, col]
        for i in 1:n
            v = source[i]
            out[i] = ismissing(v) ? default : Float64(v)
        end
    else
        fill!(out, default)
    end
    return out
end

function _evaluate_prepared_objective_loss(ctx, prepared_targets, default_loss)
    total = 0.0
    for targets in prepared_targets
        total += _evaluate_prepared_target_loss(ctx, targets, default_loss)
    end
    return total
end

function _evaluate_prepared_target_loss(ctx, targets::PreparedConventionTargets, default_loss)
    targets.series_plan === nothing || return _evaluate_prepared_series_plan(ctx, targets.series_plan)

    total = 0.0
    for i in eachindex(targets.values)
        total += _prepared_row_loss(ctx, targets, i, default_loss)
    end
    return total
end

function _evaluate_prepared_series_plan(sim, plan::PreparedSeriesPlan)
    total = 0.0
    for i in eachindex(plan.variables)
        source = _prepared_series_source(sim, plan, i)
        if source === nothing
            total += plan.weights[i] * 1e6
        elseif _is_prediction_array(source)
            total += compute_loss(source, (t=plan.times[i], y=plan.observed[i]),
                plan.loss_types[i], plan.weights[i])
        else
            total += _evaluate_solution_series_loss(
                source,
                plan.times[i],
                plan.variables[i],
                plan.observed[i],
                plan.observed_logs[i],
                plan.loss_types[i],
                plan.weights[i],
            )
        end
    end
    return total
end

function _prepared_series_source(sim, plan::PreparedSeriesPlan, i::Int)
    if plan.conditions !== nothing && !ismissing(plan.conditions[i])
        cond_result = _safe_getindex(sim, plan.conditions[i])
        cond_result === nothing && return nothing
        if _is_mapping_result(cond_result)
            val = _safe_getindex(cond_result, plan.variables[i])
            val !== nothing && return val
        end
        return cond_result
    end

    if _is_mapping_result(sim)
        val = _safe_getindex(sim, plan.variables[i])
        val !== nothing && return val
    end
    return sim
end

function _prepared_row_loss(sim, targets::PreparedConventionTargets, i::Int, default_loss)
    value = targets.values[i]
    lt = _prepared_loss_type(value, targets.row_losses[i], default_loss)
    w = targets.weights[i]

    if lt == :range_only
        lower = targets.lowers[i]
        upper = targets.uppers[i]
        return (isnan(lower) || isnan(upper)) ? w * 1e6 :
            compute_loss_range_only(_prepared_prediction(sim, targets, i), lower, upper, w)
    end

    return _prepared_prediction_loss(sim, targets, i, value, lt, w)
end

function _prepared_loss_type(value, row_loss, default_loss)
    row_loss !== nothing && row_loss !== missing && return row_loss
    _is_series_value(value) && return :series_log
    return default_loss
end

function _prepared_prediction_loss(sim, targets::PreparedConventionTargets,
                                   i::Int, value, loss_type, weight::Float64)
    source = _prepared_prediction_source(sim, targets, i)
    source === nothing && return compute_loss(NaN, value, loss_type, weight)

    if _is_series_value(value) && _is_prediction_array(source)
        return compute_loss(source, value, loss_type, weight)
    end

    if _is_series_value(value) && !_is_mapping_result(source)
        variable = _prepared_variable(targets, i)
        variable === nothing && return compute_loss(NaN, value, loss_type, weight)
        return _evaluate_solution_series_loss(source, value.t, variable, value.y,
            targets.series_log_values[i], loss_type, weight)
    end

    predicted = _extract_prediction_from_source(source, targets, i, value)
    return compute_loss(predicted, value, loss_type, weight)
end

function _prepared_prediction(sim, targets::PreparedConventionTargets, i::Int)
    source = _prepared_prediction_source(sim, targets, i)
    source === nothing && return NaN
    return _extract_prediction_from_source(source, targets, i, targets.values[i])
end

function _prepared_prediction_source(sim, targets::PreparedConventionTargets, i::Int)
    has_condition = _has_prepared_value(targets.conditions, i)
    has_variable = _has_prepared_value(targets.variables, i)

    if has_condition && has_variable
        cond_result = _safe_getindex(sim, targets.conditions[i])
        cond_result === nothing && return nothing
        if _is_series_value(targets.values[i]) && !_is_mapping_result(cond_result)
            return cond_result
        end
        if _has_prepared_value(targets.timepoints, i) && !_is_mapping_result(cond_result)
            return cond_result
        end
        val = _safe_getindex(cond_result, targets.variables[i])
        val !== nothing && return val
        (_is_series_value(targets.values[i]) || _has_prepared_value(targets.timepoints, i)) &&
            return cond_result
        return nothing
    elseif has_variable
        if _is_series_value(targets.values[i]) && !_is_mapping_result(sim)
            return sim
        end
        val = _safe_getindex(sim, targets.variables[i])
        val !== nothing && return val
        _is_series_value(targets.values[i]) && return sim
        return nothing
    elseif has_condition
        return _safe_getindex(sim, targets.conditions[i])
    else
        return _safe_getindex(sim, targets.names[i])
    end
end

function _extract_prediction_from_source(source, targets::PreparedConventionTargets,
                                         i::Int, value)
    if _is_series_value(value) && _is_prediction_array(source)
        return source
    end

    if _is_series_value(value) && !_is_mapping_result(source)
        variable = _prepared_variable(targets, i)
        variable === nothing && return source
        return _evaluate_solution(source, value.t, variable)
    end

    if _has_prepared_value(targets.timepoints, i) && !_is_mapping_result(source)
        variable = _prepared_variable(targets, i)
        variable === nothing && return NaN
        return _evaluate_solution(source, targets.timepoints[i], variable)
    end

    _is_series_value(value) && return source
    return _extract_scalar(source)
end

_has_prepared_value(values::Nothing, i::Int) = false
_has_prepared_value(values, i::Int) = !ismissing(values[i])

function _prepared_variable(targets::PreparedConventionTargets, i::Int)
    _has_prepared_value(targets.variables, i) && return targets.variables[i]
    return nothing
end

_is_prediction_array(value) = value isa AbstractArray && !hasproperty(value, :prob)

function _evaluate_solution_series_loss(sol, times, variable, observed, observed_log,
                                        loss_type, weight::Float64)
    loss_type isa Function && return loss_type(_evaluate_solution(sol, times, variable), (t=times, y=observed), weight)

    if loss_type == :series_log
        n = length(observed)
        n == 0 && return 0.0
        obsfn = _solution_observed_function(sol, variable)
        loss = 0.0
        for i in 1:n
            p = _evaluate_solution_at(sol, obsfn, times[i], variable)
            y = observed[i]
            if p <= 0 || isnan(p) || y <= 0
                loss += 1e6 / n
            else
                ylog = observed_log === nothing ? log(y) : observed_log[i]
                loss += (log(p) - ylog)^2
            end
        end
        return weight * loss / n
    elseif loss_type == :series_mse
        n = length(observed)
        n == 0 && return 0.0
        obsfn = _solution_observed_function(sol, variable)
        loss = 0.0
        for i in 1:n
            p = _evaluate_solution_at(sol, obsfn, times[i], variable)
            d = p - observed[i]
            loss += d * d
        end
        return weight * loss / n
    else
        predicted = _evaluate_solution(sol, times, variable)
        return compute_loss(predicted, (t=times, y=observed), loss_type, weight)
    end
end

function _evaluate_solution_at(sol, obsfn, t, variable)
    obsfn === nothing && return sol(t; idxs=variable)
    return _evaluate_observed_at(sol, obsfn, t)
end
