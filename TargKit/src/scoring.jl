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
    tables = Vector{NamedTuple}[]
    for (df, predict_fn) in pairs
        rows = NamedTuple[]
        batch = _batch_predictions(predict_fn, ctx, df)
        for (i, row) in enumerate(eachrow(df))
            predicted = batch === nothing ? predict_fn(ctx, row) : batch[i]
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
            push!(rows, out)
        end
        push!(tables, rows)
    end

    return _score_report(tables)
end

"""
The ScoreReport for per-table rows. Tables with different metadata columns (e.g.
TargetSets keyed by `dose` and by `dose_mg`) stack with `missing` in the gaps.
"""
function _score_report(tables)
    frames = [DataFrame(rows) for rows in tables if !isempty(rows)]
    if isempty(frames)
        details = DataFrame(name=Symbol[], predicted=Any[], value=Any[], loss=Float64[], in_range=Union{Bool,Nothing}[])
        return ScoreReport(0.0, 0, 0, details)
    end
    details = reduce((a, b) -> vcat(a, b; cols = :union), frames)
    total_loss = sum(details.loss)
    n_met = count(x -> x === true, details.in_range)
    n_total = count(x -> !isnothing(x), details.in_range)
    return ScoreReport(total_loss, n_met, n_total, details)
end

# ============================================================
# score() — TargetSet-based scoring
# ============================================================

"""
    score(ts::TargetSet...; sim, match, at, variable) -> ScoreReport
    score(ts::TargetSet...; sim, predict) -> ScoreReport
    score(ts => Match(...), ...; sim) -> ScoreReport

Score one or more TargetSets against simulation output `sim`. Say how the rows
line up with it: `match`/`at`/`variable` (see `Match` and
`TargKit/docs/matching.md`), or `predict = (sim, row) -> value`. With several
TargetSets that line up differently, pair each with its own `Match` or predict
function. Each TargetSet is scored with its own loss.

    score(ts; sim = scan_result, match = :dose, at = :TIME, variable = :Conc)
"""
function score(targets_in::TargetSet...; sim, predict=nothing, match=nothing, at=nothing, variable=nothing)
    mapping = _keyword_mapping(predict, match, at, variable, "score")
    return score((ts => mapping for ts in targets_in)...; sim=sim)
end

function score(pairs::Pair{TargetSet}...; sim)
    tables = Vector{NamedTuple}[]

    for (ts, mapping) in pairs
        rows = NamedTuple[]
        default_loss = ts.loss
        df, predictor = _bind(ts, mapping, "score")
        batch = _batch_predictions(predictor, sim, df)

        for (i, row) in enumerate(eachrow(df))
            predicted = batch === nothing ? predictor(sim, row) : batch[i]

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
            push!(rows, out)
        end
        push!(tables, rows)
    end

    return _score_report(tables)
end

"""True for series-valued targets encoded as `(t=..., y=...)`."""
_is_series_value(value) = value isa NamedTuple && haskey(value, :t) && haskey(value, :y)

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
