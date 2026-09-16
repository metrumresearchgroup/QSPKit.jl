# ============================================================
# Scoring — loss functions and score()
# ============================================================

const _OBSERVED_FUNCTION_CACHE = Dict{Tuple{UInt, Any}, Any}()
const _OBSERVED_FUNCTION_CACHE_LOCK = ReentrantLock()
const _NO_OBSERVED_FUNCTION = gensym(:no_observed_function)

function _scalar_prediction(predicted, loss_type)
    predicted isa AbstractArray || return predicted
    length(predicted) == 1 && return only(predicted)
    throw(DimensionMismatch(
        "Scalar target with loss $(repr(loss_type)) requires one predicted value, " *
        "but the predictor returned $(length(predicted)) values with size " *
        "$(size(predicted)). Return a scalar prediction or encode the target as a series."))
end

"""
    compute_loss(predicted, value, loss_type, weight) -> Float64

Compute the loss for a single target. `loss_type` is a Symbol (built-in) or
a Function `(predicted, observed, weight) -> scalar`.
"""
function compute_loss(predicted, value, loss_type, weight::Float64)::Float64
    # Custom function: (predicted, observed, weight) -> scalar
    if loss_type isa Function
        return loss_type(predicted, value, weight)
    end

    if loss_type in (:log, :squared)
        predicted = _scalar_prediction(predicted, loss_type)
    end

    # Guard: NaN/Inf scalar predictions get large penalty
    if predicted isa Real && (isnan(predicted) || isinf(predicted))
        return weight * 1e6
    end

    if loss_type == :log
        if (predicted isa Real && predicted <= 0) || (value isa Real && value <= 0)
            return weight * 1e6
        end
        return weight * (log(predicted) - log(value))^2
    elseif loss_type == :squared
        return weight * (predicted - value)^2
    elseif loss_type == :range_only
        error("range_only loss requires lower/upper bounds; use compute_loss_range_only instead")
    elseif loss_type == :series_mse
        return weight * mean((predicted .- value.y).^2)
    elseif loss_type == :series_log
        tgt = value.y
        n = length(tgt)
        n == 0 && return 0.0
        loss = 0.0
        for i in 1:n
            p = predicted[i]
            t_val = tgt[i]
            if p <= 0 || isnan(p) || t_val <= 0
                loss += 1e6 / n
            else
                loss += (log(p) - log(t_val))^2
            end
        end
        return weight * loss / n
    else
        error("Unknown loss type: $loss_type")
    end
end

"""
    compute_loss_range_only(predicted, lower, upper, weight) -> Float64

Range-only loss: zero inside [lower, upper], quadratic penalty outside.
"""
function compute_loss_range_only(predicted, lower, upper, weight::Float64)::Float64
    predicted = _scalar_prediction(predicted, :range_only)
    if predicted < lower
        return weight * (lower - predicted)^2
    elseif predicted > upper
        return weight * (predicted - upper)^2
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

"""
    _check_in_range(predicted, row) -> Union{Bool, Nothing}

Check if predicted is within [lower, upper]. Returns nothing if no range or non-scalar.
"""
function _check_in_range(predicted, row)::Union{Bool, Nothing}
    !(predicted isa Real) && return nothing
    has_lower = hasproperty(row, :lower) && !ismissing(row.lower) && !isnan(row.lower)
    has_upper = hasproperty(row, :upper) && !ismissing(row.upper) && !isnan(row.upper)
    (!has_lower || !has_upper) && return nothing
    return row.lower <= predicted <= row.upper
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
                has_lower = hasproperty(row, :lower) && !ismissing(row.lower) && !isnan(row.lower)
                has_upper = hasproperty(row, :upper) && !ismissing(row.upper) && !isnan(row.upper)
                (!has_lower || !has_upper) && error("range_only loss requires :lower and :upper on target :$(row.name)")
                compute_loss_range_only(predicted, row.lower, row.upper, w)
            else
                compute_loss(predicted, row.value, lt, w)
            end

            in_range = _check_in_range(predicted, row)

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
                has_lower = hasproperty(row, :lower) && !ismissing(row.lower) && !isnan(row.lower)
                has_upper = hasproperty(row, :upper) && !ismissing(row.upper) && !isnan(row.upper)
                (!has_lower || !has_upper) && error("range_only loss requires :lower and :upper on target :$(row.name)")
                compute_loss_range_only(predicted, row.lower, row.upper, w)
            else
                compute_loss(predicted, row.value, lt, w)
            end

            in_range = _check_in_range(predicted, row)

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
        isnothing(cond_result) && return NaN
        return _predict_condition_variable(cond_result, row)
    elseif has_variable
        if _is_series_value(row.value) && !_is_mapping_result(sim)
            return _evaluate_solution(sim, row.value.t, row.variable)
        end
        val = _safe_getindex(sim, row.variable)
        if isnothing(val) && _is_series_value(row.value)
            return _evaluate_solution(sim, row.value.t, row.variable)
        end
        isnothing(val) && return NaN
        return _extract_prediction(val, row)
    elseif has_condition
        val = _safe_getindex(sim, row.condition)
        isnothing(val) && return NaN
        return _extract_prediction(val, row)
    else
        # Try by :name
        val = _safe_getindex(sim, row.name)
        isnothing(val) && error("Cannot extract prediction for target :$(row.name). " *
            "Provide a `predict` function or add :condition/:variable columns.")
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

    if _is_series_value(row.value)
        return _evaluate_solution(cond_result, row.value.t, row.variable)
    end

    if hasproperty(row, :timepoint) && !ismissing(row.timepoint)
        return _evaluate_solution(cond_result, row.timepoint, row.variable)
    end

    return NaN
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
