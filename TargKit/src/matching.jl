# ============================================================
# Matching targets to simulation output (match / at)
# See TargKit/docs/matching.md.
# ============================================================

"""
    MatchError(msg)

A target row did not match exactly one point of the simulation output.
"""
struct MatchError <: Exception
    msg::String
end

Base.showerror(io::IO, e::MatchError) = print(io, "MatchError: ", e.msg)

"""
    KeyedResults(entries)

Simulation results labelled by key values, e.g. one result per scanned dose.
`entries` is a vector of `keys => result` pairs: `keys` maps key names to values,
and `result` is a table, an ODE solution, or anything `match_source` converts.
"""
struct KeyedResults
    entries::Vector{Pair{Dict{Symbol, Any}, Any}}
end

KeyedResults(entries::AbstractVector) =
    KeyedResults(Pair{Dict{Symbol, Any}, Any}[Dict{Symbol, Any}(k) => v for (k, v) in entries])

"""
    match_source(sim)

Convert a simulation output into a form targets can be matched against: a table,
an ODE solution, an `AbstractDict` keyed by one match key, or `KeyedResults`.
Components add methods for their own result types (SimKit: scan results and
`SimContext`). The fallback returns `sim` unchanged.
"""
match_source(sim) = sim

# Dict outputs are keyed by whichever single match key is left when they are reached.
struct _DictResults
    entries::Vector{Pair{Any, Any}}
end

"""Convert a simulation output (recursively) into tables, solutions, and keyed results."""
function _normalize_source(sim)
    source = match_source(sim)
    source isa KeyedResults &&
        return KeyedResults(Pair{Dict{Symbol, Any}, Any}[k => _normalize_source(v) for (k, v) in source.entries])
    source isa AbstractDataFrame && return source
    source isa SciMLBase.AbstractTimeseriesSolution && return source
    source isa AbstractDict &&
        return _DictResults(Pair{Any, Any}[k => _normalize_source(v) for (k, v) in source])
    Tables.istable(source) && return DataFrame(source)
    throw(MatchError("cannot match targets against a simulation output of type $(typeof(source)). " *
        "Return a DataFrame, an ODE solution, a SimKit scan result or SimContext, a Dict, " *
        "or TargKit.KeyedResults from `simulate`."))
end

"""True if any ODE solution in a normalized simulation output failed to solve."""
_has_failed_solution(source::SciMLBase.AbstractTimeseriesSolution) = !SciMLBase.successful_retcode(source)
_has_failed_solution(source::KeyedResults) = any(e -> _has_failed_solution(last(e)), source.entries)
_has_failed_solution(source::_DictResults) = any(e -> _has_failed_solution(last(e)), source.entries)
_has_failed_solution(source) = false

# ============================================================
# Per-target query
# ============================================================

struct _MatchQuery
    name::Any
    keys::Vector{Pair{Symbol, Any}}   # simulation key => target value
    axis::Union{Symbol, Nothing}
    at::Any
    variable::Symbol
end

function _match_query(row, spec::MatchSpec)
    keys = Pair{Symbol, Any}[simkey => row[col] for (col, simkey) in spec.keys]
    at = isnothing(spec.at_axis) ? nothing :
        isnothing(spec.at_column) ? spec.at_value : row[spec.at_column]
    variable = isnothing(spec.variable) ? Symbol(row.variable) : spec.variable
    name = hasproperty(row, :name) ? row.name : nothing
    return _MatchQuery(name, keys, spec.at_axis, at, variable)
end

function _describe(q::_MatchQuery)
    parts = ["$k = $(repr(v))" for (k, v) in q.keys]
    isnothing(q.axis) || push!(parts, "$(q.axis) = $(repr(q.at))")
    where_ = isempty(parts) ? "" : " (" * join(parts, ", ") * ")"
    label = isnothing(q.name) ? "target" : "target :$(q.name)"
    return "$label$where_"
end

_describe_keys(keys) = join(["$k = $(repr(v))" for (k, v) in keys], ", ")

# ============================================================
# Batch and per-row predictions
# ============================================================

"""Predictions for every row of `df`, matched against the simulation output `sim`."""
function _match_predictions(sim, df::AbstractDataFrame, spec::MatchSpec)
    source = _normalize_source(sim)
    return Any[_resolve(source, _match_query(row, spec)) for row in eachrow(df)]
end

"""
    MatchPredictor(spec)

`predict_fn` for TargetSets with `match`/`at`. Scoring and objectives call
`_match_predictions` once per TargetSet; calling it per row also works.
"""
struct MatchPredictor <: Function
    spec::MatchSpec
end

(p::MatchPredictor)(sim, row) = _resolve(_normalize_source(sim), _match_query(row, p.spec))

"""Predictions for all rows: batched for `MatchPredictor`, otherwise `nothing` (call per row)."""
_batch_predictions(predict_fn::MatchPredictor, sim, df) = _match_predictions(sim, df, predict_fn.spec)
_batch_predictions(predict_fn, sim, df) = nothing

# ============================================================
# Resolution
# ============================================================

_resolve(source, q::_MatchQuery) = _resolve(source, q.keys, q)

function _resolve(source::KeyedResults, want, q::_MatchQuery)
    candidates = [e for e in source.entries if _keys_match(first(e), want)]
    if isempty(candidates)
        shared = [k for (k, _) in want if any(e -> haskey(first(e), k), source.entries)]
        available = unique([_describe_keys([k => first(e)[k] for k in shared if haskey(first(e), k)])
                            for e in source.entries])
        throw(MatchError("$(_describe(q)): no simulation result has $(_describe_keys(filter(p -> first(p) in shared, want))). " *
            "Simulated: $(_truncated_list(available)). Make the simulation cover every target, " *
            "e.g. scan over the unique target values."))
    end
    if length(candidates) > 1
        differing = _differing_keys([first(e) for e in candidates])
        unlabelled = [k for (k, _) in want if !any(e -> haskey(first(e), k), source.entries)]
        note = isempty(unlabelled) ? "" :
            " The match key(s) $(_symbol_list(unlabelled)) are not labels of these results " *
            "(labels: $(_symbol_list(unique(reduce(vcat, [collect(keys(first(e))) for e in candidates])))))."
        throw(MatchError("$(_describe(q)): $(length(candidates)) simulation results match. " *
            "They differ in $(_symbol_list(differing)); add $(length(differing) == 1 ? "it" : "them") " *
            "to `match` (with matching target columns).$note"))
    end
    labels, result = only(candidates)
    remaining = filter(p -> !haskey(labels, first(p)), want)
    return _resolve(result, remaining, q)
end

function _resolve(source::_DictResults, want, q::_MatchQuery)
    if length(want) != 1
        throw(MatchError("$(_describe(q)): a Dict simulation output is keyed by one value, but " *
            "$(length(want)) match keys are left to match ($(_symbol_list(first.(want)))). " *
            "Return a table or TargKit.KeyedResults to match several keys."))
    end
    key, value = only(want)
    candidates = [e for e in source.entries if _key_equal(first(e), value)]
    if isempty(candidates)
        throw(MatchError("$(_describe(q)): the simulation output has no entry for $key = $(repr(value)). " *
            "Its keys are $(_truncated_list(repr.(first.(source.entries))))."))
    end
    length(candidates) > 1 && throw(MatchError(
        "$(_describe(q)): $(length(candidates)) simulation entries match $key = $(repr(value)) " *
        "($(join(repr.(first.(candidates)), ", ")))."))
    return _resolve(last(only(candidates)), Pair{Symbol, Any}[], q)
end

function _resolve(df::AbstractDataFrame, want, q::_MatchQuery)
    columns = propertynames(df)
    for (k, _) in want
        k in columns || throw(MatchError("$(_describe(q)): the simulation output has no column :$k " *
            "(columns: $(_symbol_list(columns)))."))
    end
    isnothing(q.axis) || q.axis in columns || throw(MatchError(
        "$(_describe(q)): the simulation output has no `at` column :$(q.axis) (columns: $(_symbol_list(columns)))."))
    q.variable in columns || throw(MatchError(
        "$(_describe(q)): the simulation output has no column :$(q.variable) to compare with " *
        "(columns: $(_symbol_list(columns)))."))

    rows = collect(1:nrow(df))
    for (k, v) in want
        _filter_rows!(rows, df[!, k], v)
    end
    if isempty(rows)
        available = unique([_describe_keys([k => df[r, k] for (k, _) in want]) for r in 1:nrow(df)])
        throw(MatchError("$(_describe(q)): no simulation row has $(_describe_keys(want)). " *
            "Simulated: $(_truncated_list(available))."))
    end

    group = copy(rows)
    isnothing(q.axis) || _filter_rows!(rows, df[!, q.axis], q.at)
    if isempty(rows)
        axis_values = df[group, q.axis]
        ending = q.at isa Real && all(v -> v isa Real, axis_values) && q.at > maximum(axis_values) ?
            " The output ends at $(q.axis) = $(maximum(axis_values)); if the simulation can stop early, " *
            "return `nothing` from simulate so the fit applies failure_penalty." : ""
        in_group = isempty(want) ? "" : " for $(_describe_keys(want))"
        throw(MatchError("$(_describe(q)): no simulation row at $(q.axis) = $(repr(q.at))$in_group. " *
            "The output has $(q.axis) values $(_truncated_list(repr.(unique(axis_values)))). " *
            "Make the simulation output include every target point (for a time axis, add it to saveat).$ending"))
    end
    length(rows) == 1 && return df[only(rows), q.variable]

    matched = vcat(first.(want), isnothing(q.axis) ? Symbol[] : [q.axis])
    differing = [c for c in columns if c ∉ matched && !_all_equal(df[rows, c])]
    hint = if isnothing(q.axis)
        "Use `at` to pick one point along an axis (e.g. `at = :TIME => 24.0`), or add identifying columns to `match`."
    else
        "If those columns identify different simulations (a subject, arm, or scanned value), add them to `match`. " *
        "If they are simulated values, the output has several points at $(q.axis) = $(repr(q.at)), typically " *
        "the values just before and after a dose; target a point just before or after it."
    end
    throw(MatchError("$(_describe(q)): $(length(rows)) simulation rows match. " *
        "They differ in $(_symbol_list(differing)). $hint"))
end

function _resolve(sol::SciMLBase.AbstractTimeseriesSolution, want, q::_MatchQuery)
    isempty(want) || throw(MatchError("$(_describe(q)): match key(s) $(_symbol_list(first.(want))) " *
        "were not found in the simulation output. An ODE solution has no keys; label results by " *
        "these values (e.g. a SimKit scan over them) or return a table with these columns."))
    isnothing(q.axis) && throw(MatchError("$(_describe(q)): an ODE solution needs `at` to pick a time " *
        "(e.g. `at = :TIME => 24.0`)."))
    SciMLBase.successful_retcode(sol) || throw(MatchError(
        "$(_describe(q)): the simulation failed (retcode $(sol.retcode))."))

    t = q.at
    t isa Real || throw(MatchError("$(_describe(q)): `at` must be a time for an ODE solution; got $(repr(t))."))
    t0, t1 = first(sol.t), last(sol.t)
    if (t < t0 && !isapprox(t, t0)) || (t > t1 && !isapprox(t, t1))
        throw(MatchError("$(_describe(q)): $(q.axis) = $t is outside the simulated time span [$t0, $t1]."))
    end
    tol = sqrt(eps(Float64)) * abs(t)
    n_saved = searchsortedlast(sol.t, t + tol) - searchsortedfirst(sol.t, t - tol) + 1
    n_saved > 1 && throw(MatchError("$(_describe(q)): the solution has $n_saved points at t = $t, " *
        "a discontinuity such as a dose at that time; the value there is ambiguous. " *
        "Target a time just before or after it."))
    if n_saved == 0 && !_has_dense_output(sol)
        throw(MatchError("$(_describe(q)): t = $t is not a saved point, and the solution has no dense " *
            "output (it was saved with `saveat`), so its value there would be interpolated between saved " *
            "points. Add the target times to `saveat`, or drop `saveat`."))
    end
    return _evaluate_solution(sol, t, q.variable)
end

_resolve(source, want, q::_MatchQuery) = _resolve(_normalize_source(source), want, q)

_has_dense_output(sol) = hasproperty(sol, :dense) && sol.dense

# ============================================================
# Key comparison
# ============================================================

_key_equal(a::Real, b::Real) = isapprox(a, b)
_key_equal(a::Union{Symbol, AbstractString}, b::Union{Symbol, AbstractString}) = string(a) == string(b)
_key_equal(a, b) = isequal(a, b)

_keys_match(keys::AbstractDict, want) = all(p -> !haskey(keys, first(p)) || _key_equal(keys[first(p)], last(p)), want)

function _filter_rows!(rows::Vector{Int}, column::AbstractVector, value)
    filter!(r -> _key_equal(column[r], value), rows)
end

_all_equal(values) = all(v -> _key_equal(v, first(values)), values)

function _differing_keys(dicts)
    names = unique(reduce(vcat, [collect(keys(d)) for d in dicts]))
    return [k for k in names if !_all_equal([get(d, k, missing) for d in dicts])]
end

_symbol_list(names) = isempty(names) ? "no columns" : join([":$n" for n in names], ", ")

function _truncated_list(items; limit::Int=10)
    strs = string.(items)
    length(strs) <= limit && return join(strs, "; ")
    return join(strs[1:limit], "; ") * "; … ($(length(strs)) total)"
end
