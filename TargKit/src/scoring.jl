# ============================================================
# Scoring — loss functions and score()
# ============================================================

const _OBSERVED_FUNCTION_CACHE = Dict{Tuple{UInt, Any}, Any}()
const _OBSERVED_FUNCTION_CACHE_LOCK = ReentrantLock()
const _NO_OBSERVED_FUNCTION = gensym(:no_observed_function)

_target_context(target) = isnothing(target) ? "loss" :
    "target $(target isa Symbol ? ":$(target)" : repr(target))"
_index_context(index) = isnothing(index) ? "" : " at index $(index)"

function _require_finite_real(value, role, target; index=nothing)
    context = _target_context(target)
    suffix = _index_context(index)
    value isa Real || throw(ArgumentError(
        "$context $role$suffix must be a real number; got $(typeof(value))"))
    isfinite(value) || throw(DomainError(value,
        "$context $role$suffix must be finite"))
    return value
end

function _validate_finite_data(value, role, target)
    if value isa Real
        _require_finite_real(value, role, target)
    elseif value isa AbstractArray
        for (i, element) in enumerate(value)
            element isa Real && _require_finite_real(element, role, target; index=i)
        end
    elseif value isa NamedTuple && haskey(value, :y) && value.y isa AbstractArray
        for (i, element) in enumerate(value.y)
            element isa Real && _require_finite_real(element, role, target; index=i)
        end
    end
    return value
end

function _validated_loss(value, target)
    _require_finite_real(value, "computed loss", target)
    converted = Float64(value)
    isfinite(converted) || throw(DomainError(value,
        "$(_target_context(target)) computed loss is not representable as finite Float64"))
    return converted
end

function _scalar_prediction(predicted, loss_type; target=nothing)
    predicted isa AbstractArray || return predicted
    length(predicted) == 1 && return only(predicted)
    throw(DimensionMismatch(
        "$(_target_context(target)) with loss $(repr(loss_type)) requires one predicted value, " *
        "but the predictor returned $(length(predicted)) values with size " *
        "$(size(predicted)). Return a scalar prediction or encode the target as a series."))
end

function _series_data(predicted, value, target)
    _is_series_value(value) || throw(ArgumentError(
        "$(_target_context(target)) requires an observed series encoded as `(t=..., y=...)`"))
    predicted isa AbstractVector || throw(ArgumentError(
        "$(_target_context(target)) series prediction must be a vector; got $(typeof(predicted))"))
    value.t isa AbstractVector || throw(ArgumentError(
        "$(_target_context(target)) series timepoints must be a vector; got $(typeof(value.t))"))
    value.y isa AbstractVector || throw(ArgumentError(
        "$(_target_context(target)) observed series must be a vector; got $(typeof(value.y))"))
    length(value.t) == length(value.y) || throw(DimensionMismatch(
        "$(_target_context(target)) has $(length(value.t)) timepoints but $(length(value.y)) observed values"))
    length(predicted) == length(value.y) || throw(DimensionMismatch(
        "$(_target_context(target)) has $(length(predicted)) predicted series values but $(length(value.y)) observed values"))

    for (i, time) in enumerate(value.t)
        _require_finite_real(time, "timepoint", target; index=i)
    end
    for (i, observed) in enumerate(value.y)
        _require_finite_real(observed, "observed series value", target; index=i)
    end
    for (i, prediction) in enumerate(predicted)
        _require_finite_real(prediction, "predicted series value", target; index=i)
    end
    return predicted, value.y
end

"""
    compute_loss(predicted, value, loss_type, weight; target=nothing) -> Float64

Compute the loss for a single target. `loss_type` is a Symbol (built-in) or
a Function `(predicted, observed, weight) -> scalar`.
Invalid numeric inputs raise descriptive errors. `target` is an optional name used
to add target context to those errors.
"""
function compute_loss(predicted, value, loss_type, weight::Float64; target=nothing)::Float64
    _require_finite_real(weight, "weight", target)

    # Custom function: (predicted, observed, weight) -> scalar
    if loss_type isa Function
        _validate_finite_data(predicted, "prediction", target)
        _validate_finite_data(value, "observation", target)
        return _validated_loss(loss_type(predicted, value, weight), target)
    end

    if loss_type in (:log, :squared)
        predicted = _scalar_prediction(predicted, loss_type; target=target)
    end

    if loss_type == :log
        _require_finite_real(predicted, "prediction", target)
        _require_finite_real(value, "observation", target)
        predicted > 0 || throw(DomainError(predicted,
            "$(_target_context(target)) log-loss prediction must be positive"))
        value > 0 || throw(DomainError(value,
            "$(_target_context(target)) log-loss observation must be positive"))
        return _validated_loss(weight * (log(predicted) - log(value))^2, target)
    elseif loss_type == :squared
        _require_finite_real(predicted, "prediction", target)
        _require_finite_real(value, "observation", target)
        return _validated_loss(weight * (predicted - value)^2, target)
    elseif loss_type == :range_only
        throw(ArgumentError(
            "$(_target_context(target)) range_only loss requires lower/upper bounds; use compute_loss_range_only instead"))
    elseif loss_type == :series_mse
        prediction, observed = _series_data(predicted, value, target)
        isempty(observed) && return 0.0
        return _validated_loss(weight * mean((prediction .- observed).^2), target)
    elseif loss_type == :series_log
        prediction, observed = _series_data(predicted, value, target)
        n = length(observed)
        n == 0 && return 0.0
        loss = 0.0
        for i in 1:n
            p = prediction[i]
            observed_value = observed[i]
            p > 0 || throw(DomainError(p,
                "$(_target_context(target)) log-series prediction at index $i must be positive"))
            observed_value > 0 || throw(DomainError(observed_value,
                "$(_target_context(target)) log-series observation at index $i must be positive"))
            loss += (log(p) - log(observed_value))^2
        end
        return _validated_loss(weight * loss / n, target)
    else
        throw(ArgumentError("Unknown loss type: $loss_type"))
    end
end

"""
    compute_loss_range_only(predicted, lower, upper, weight; target=nothing) -> Float64

Range-only loss: zero inside [lower, upper], quadratic penalty outside.
"""
function compute_loss_range_only(predicted, lower, upper, weight::Float64; target=nothing)::Float64
    predicted = _scalar_prediction(predicted, :range_only; target=target)
    _require_finite_real(predicted, "prediction", target)
    _require_finite_real(lower, "lower bound", target)
    _require_finite_real(upper, "upper bound", target)
    _require_finite_real(weight, "weight", target)
    lower <= upper || throw(ArgumentError(
        "$(_target_context(target)) lower bound $lower exceeds upper bound $upper"))
    if predicted < lower
        return _validated_loss(weight * (lower - predicted)^2, target)
    elseif predicted > upper
        return _validated_loss(weight * (predicted - upper)^2, target)
    else
        return 0.0
    end
end

"""
    _resolve_loss_type(row, default_loss) -> Union{Symbol, Function}

Determine loss type for a row: per-row :loss column > auto-detect > default.
"""
function _resolve_loss_type(row, default_loss)
    if hasproperty(row, :loss) && !ismissing(row.loss)
        return row.loss
    end
    # Auto-detect: series values get :series_log
    if row.value isa NamedTuple && haskey(row.value, :t) && haskey(row.value, :y)
        return :series_log
    end
    return default_loss
end

"""
    _resolve_weight(row) -> Float64

Get weight from row, defaulting to 1.0.
"""
function _resolve_weight(row)::Float64
    hasproperty(row, :weight) && !ismissing(row.weight) ? Float64(row.weight) : 1.0
end

function _optional_bound(row, column::Symbol, target)
    hasproperty(row, column) || return nothing
    value = getproperty(row, column)
    ismissing(value) && return nothing
    value isa Real || throw(ArgumentError(
        "$(_target_context(target)) $(column) bound must be a real number; got $(typeof(value))"))
    isnan(value) && return nothing
    return value
end

function _optional_range_bounds(row, target)
    lower = _optional_bound(row, :lower, target)
    upper = _optional_bound(row, :upper, target)
    if isnothing(lower) != isnothing(upper)
        throw(ArgumentError(
            "$(_target_context(target)) must provide both :lower and :upper bounds or neither"))
    end
    isnothing(lower) && return nothing
    return (lower=lower, upper=upper)
end

function _required_range_bounds(row, target)
    bounds = _optional_range_bounds(row, target)
    bounds === nothing && throw(ArgumentError(
        "$(_target_context(target)) uses :range_only but is missing :lower and :upper bounds"))
    return bounds
end

"""
    _check_in_range(predicted, row; target=nothing) -> Union{Bool, Nothing}

Check if predicted is within [lower, upper]. Returns nothing if no range or non-scalar.
"""
function _check_in_range(predicted, row; target=nothing)::Union{Bool, Nothing}
    bounds = _optional_range_bounds(row, target)
    bounds === nothing && return nothing
    _require_finite_real(bounds.lower, "lower bound", target)
    _require_finite_real(bounds.upper, "upper bound", target)
    bounds.lower <= bounds.upper || throw(ArgumentError(
        "$(_target_context(target)) lower bound $(bounds.lower) exceeds upper bound $(bounds.upper)"))
    !(predicted isa Real) && return nothing
    _require_finite_real(predicted, "prediction", target)
    return bounds.lower <= predicted <= bounds.upper
end

# ============================================================
# score() — score target pairs against a context
# ============================================================

"""
    score(pairs...; ctx) -> ScoreReport

Score one or more `df => predict_fn` pairs against a provided context.

    report = score(baseline => predict_fn; ctx=(sol=my_sol,))
"""
function score(pairs::Pair{<:AbstractDataFrame, <:Function}...; ctx, loss::Union{Symbol, Function}=:log)
    all_rows = NamedTuple[]
    for (df, predict_fn) in pairs
        for row in eachrow(df)
            predicted = predict_fn(ctx, row)
            lt = _resolve_loss_type(row, loss)
            w = _resolve_weight(row)

            row_loss = if lt == :range_only
                bounds = _required_range_bounds(row, row.name)
                compute_loss_range_only(predicted, bounds.lower, bounds.upper, w; target=row.name)
            else
                compute_loss(predicted, row.value, lt, w; target=row.name)
            end

            in_range = _check_in_range(predicted, row; target=row.name)

            # Build output row with all metadata columns preserved
            out = (name=row.name, predicted=predicted, value=row.value, loss=row_loss, in_range=in_range)
            # Copy metadata columns
            for col in propertynames(row)
                col in (:name, :value, :lower, :upper, :weight, :loss) && continue
                out = merge(out, NamedTuple{(col,)}((getproperty(row, col),)))
            end
            push!(all_rows, out)
        end
    end

    if isempty(all_rows)
        details = DataFrame(name=Symbol[], predicted=Any[], value=Any[], loss=Float64[], in_range=Union{Bool,Nothing}[])
        return ScoreReport(0.0, 0, 0, details)
    end

    details = DataFrame(all_rows)
    total_loss = sum(details.loss)
    n_met = count(x -> x === true, details.in_range)
    n_total = count(x -> !isnothing(x), details.in_range)
    return ScoreReport(total_loss, n_met, n_total, details)
end

# ============================================================
# score() — TargetSet-based scoring
# ============================================================

"""
    score(ts::TargetSet...; sim, predict=nothing) -> ScoreReport

Score one or more TargetSets against simulation results.

# Convention-based extraction
If the TargetSet has `:condition` and `:variable` columns, predictions are
auto-extracted as `sim[condition][variable]` for endpoint values. If the target
value is a series `(t=..., y=...)` and `sim[condition]` is solution-like, the
prediction is evaluated as `sim[condition](value.t; idxs=variable)`.

# Custom predict
    score(ts; sim=sims, predict=(sims, target) -> sims[target.condition][target.variable][end])

# Arguments
- `ts...` — one or more TargetSets
- `sim` — Dict or NamedTuple of simulation results, keyed by condition
- `predict` — optional `(sim, row) -> predicted_value` function
"""
function score(targets_in::TargetSet...; sim, predict=nothing)
    all_rows = NamedTuple[]

    for ts in targets_in
        default_loss = ts.loss

        for row in eachrow(ts.df)
            predicted = if !isnothing(predict)
                predict(sim, row)
            else
                _convention_predict(sim, row)
            end

            lt = _resolve_loss_type(row, default_loss)
            w = _resolve_weight(row)

            row_loss = if lt == :range_only
                bounds = _required_range_bounds(row, row.name)
                compute_loss_range_only(predicted, bounds.lower, bounds.upper, w; target=row.name)
            else
                compute_loss(predicted, row.value, lt, w; target=row.name)
            end

            in_range = _check_in_range(predicted, row; target=row.name)

            out = (name=row.name, predicted=predicted, value=row.value, loss=row_loss, in_range=in_range)
            for col in propertynames(row)
                col in (:name, :value, :lower, :upper, :weight, :loss) && continue
                out = merge(out, NamedTuple{(col,)}((getproperty(row, col),)))
            end
            push!(all_rows, out)
        end
    end

    if isempty(all_rows)
        details = DataFrame(name=Symbol[], predicted=Any[], value=Any[], loss=Float64[], in_range=Union{Bool,Nothing}[])
        return ScoreReport(0.0, 0, 0, details)
    end

    details = DataFrame(all_rows)
    total_loss = sum(details.loss)
    n_met = count(x -> x === true, details.in_range)
    n_total = count(x -> !isnothing(x), details.in_range)
    return ScoreReport(total_loss, n_met, n_total, details)
end

# ============================================================
# Convention-based prediction
# ============================================================

"""Extract prediction using convention: sim[condition][variable] or sim[name]."""
function _convention_predict(sim, row)
    has_condition = hasproperty(row, :condition) && !ismissing(row.condition)
    has_variable = hasproperty(row, :variable) && !ismissing(row.variable)

    if has_condition && has_variable
        cond_result = _safe_getindex(sim, row.condition)
        isnothing(cond_result) && throw(ArgumentError(
            "$(_target_context(row.name)) has no prediction source: condition $(repr(row.condition)) is missing"))
        return _predict_condition_variable(cond_result, row)
    elseif has_variable
        if _is_series_value(row.value) && !_is_mapping_result(sim)
            return _evaluate_solution(sim, row.value.t, row.variable)
        end
        val = _safe_getindex(sim, row.variable)
        isnothing(val) && throw(ArgumentError(
            "$(_target_context(row.name)) has no prediction source: variable $(repr(row.variable)) is missing"))
        return _extract_prediction(val, row)
    elseif has_condition
        val = _safe_getindex(sim, row.condition)
        isnothing(val) && throw(ArgumentError(
            "$(_target_context(row.name)) has no prediction source: condition $(repr(row.condition)) is missing"))
        return _extract_prediction(val, row)
    else
        # Try by :name
        val = _safe_getindex(sim, row.name)
        isnothing(val) && throw(ArgumentError(
            "$(_target_context(row.name)) has no prediction source: key $(repr(row.name)) is missing. " *
            "Provide a `predict` function or add :condition/:variable columns."))
        return _extract_prediction(val, row)
    end
end

"""Extract prediction for a row with both condition and variable roles."""
function _predict_condition_variable(cond_result, row)
    if _is_series_value(row.value) && !_is_mapping_result(cond_result)
        return _evaluate_solution(cond_result, row.value.t, row.variable)
    end

    if hasproperty(row, :timepoint) && !ismissing(row.timepoint) && !_is_mapping_result(cond_result)
        return _evaluate_solution(cond_result, row.timepoint, row.variable)
    end

    val = _safe_getindex(cond_result, row.variable)
    if !isnothing(val)
        return _extract_prediction(val, row)
    end

    _is_mapping_result(cond_result) && throw(ArgumentError(
        "$(_target_context(row.name)) has no prediction source: variable $(repr(row.variable)) " *
        "is missing from condition $(repr(row.condition))"))

    if _is_series_value(row.value)
        return _evaluate_solution(cond_result, row.value.t, row.variable)
    end

    if hasproperty(row, :timepoint) && !ismissing(row.timepoint)
        return _evaluate_solution(cond_result, row.timepoint, row.variable)
    end

    throw(ArgumentError(
        "$(_target_context(row.name)) has no prediction source for variable $(repr(row.variable)) " *
        "under condition $(repr(row.condition))"))
end

"""True for series-valued targets encoded as `(t=..., y=...)`."""
_is_series_value(value) = value isa NamedTuple && haskey(value, :t) && haskey(value, :y)

"""True when a condition result should be probed as `result[variable]` first."""
_is_mapping_result(value) = value isa AbstractDict || value isa NamedTuple

"""Evaluate a solution-like object at `times`, optionally selecting `idxs`."""
function _evaluate_solution(sol, times, variable)
    obsfn = _solution_observed_function(sol, variable)
    obsfn === nothing && return sol(times; idxs=variable)
    return _evaluate_observed_solution(sol, obsfn, times)
end

function _solution_observed_function(sol, variable)
    hasproperty(sol, :prob) || return nothing
    prob = getproperty(sol, :prob)
    hasproperty(prob, :f) || return nothing
    SymbolicIndexingInterface.variable_index(prob, variable) !== nothing && return nothing
    f = getproperty(prob, :f)
    key = (objectid(f), variable)

    cached = lock(_OBSERVED_FUNCTION_CACHE_LOCK) do
        get(_OBSERVED_FUNCTION_CACHE, key, nothing)
    end
    if cached !== nothing && cached.f === f
        cached.obsfn === _NO_OBSERVED_FUNCTION && return nothing
        return cached.obsfn
    end

    obsfn = if applicable(SymbolicIndexingInterface.is_observed, f, variable) &&
               SymbolicIndexingInterface.is_observed(f, variable)
        # MTK compiles observed functions lazily through a Dict-backed cache.
        # Serialize only that compile/retrieval step, then evaluate the returned
        # function directly without re-entering ODESolution symbolic indexing.
        QSPKitCore.with_symbolic_compilation_lock() do
            SymbolicIndexingInterface.observed(f, variable)
        end
    else
        _NO_OBSERVED_FUNCTION
    end

    stored = lock(_OBSERVED_FUNCTION_CACHE_LOCK) do
        current = get(_OBSERVED_FUNCTION_CACHE, key, nothing)
        if current !== nothing && current.f === f
            current
        else
            entry = (f = f, obsfn = obsfn)
            _OBSERVED_FUNCTION_CACHE[key] = entry
            entry
        end
    end
    stored.obsfn === _NO_OBSERVED_FUNCTION ? nothing : stored.obsfn
end

function _evaluate_observed_solution(sol, obsfn, times)
    times isa Number && return _evaluate_observed_at(sol, obsfn, times)
    return [_evaluate_observed_at(sol, obsfn, t) for t in times]
end

function _evaluate_observed_at(sol, obsfn, t)
    value = obsfn(sol(t), sol.prob.p, t)
    return _unwrap_observed_value(value)
end

function _unwrap_observed_value(value)
    value isa AbstractArray && length(value) == 1 && return only(value)
    return value
end

"""Extract either a whole series prediction or the scalar endpoint convention."""
function _extract_prediction(val, row)
    _is_series_value(row.value) && return val
    return _extract_scalar(val)
end

"""Safely index into a Dict/NamedTuple/property container, returning nothing on absence."""
_safe_getindex(container::AbstractDict, key) = get(container, key, nothing)

function _safe_getindex(container::NamedTuple, key)
    sym = _property_key(key)
    sym === nothing && return nothing
    return haskey(container, sym) ? getfield(container, sym) : nothing
end

function _safe_getindex(container, key)
    sym = _property_key(key)
    if sym !== nothing && hasproperty(container, sym)
        return getproperty(container, sym)
    end
    return nothing
end

_property_key(key::Symbol) = key
_property_key(key::AbstractString) = Symbol(key)
_property_key(key) = nothing

"""Extract a scalar from a value — if it's indexable with `end`, take the last element."""
function _extract_scalar(val)
    val isa Real && return val
    try
        return val[end]
    catch
        return val
    end
end
