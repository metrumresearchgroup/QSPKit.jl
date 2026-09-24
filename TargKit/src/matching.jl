# ============================================================
# Matching targets to simulation output (Match: keys / at / variable)
# See TargKit/docs/matching.md.
# ============================================================

"""
    Match(keys...; at = nothing, variable = nothing)

How a TargetSet's rows line up with one simulation's output. Pass it to
`fit`/`setup`/`objective`/`score` as `match`/`at`/`variable` keywords, or pair it
with a TargetSet: `fit(pk => Match(:dose; at = :TIME, variable = :Conc), ...)`.

- `keys` — target columns holding discrete keys that pick a simulation: `:dose`,
  or `:CONC => :dose` when the simulation names it differently.
- `at` — the point within it, along one ordered axis: `:TIME` (a target column
  named like the simulation axis), `:TIME_hr => :TIME`, or `:TIME => 672.0`
  (every target at one point).
- `variable` — the simulated variable each row's value is compared with: a name
  (`:Conc`), or a `Dict` translating the TargetSet's `variable` column
  (`Dict("plasma" => :Conc)`). Omit it when that column already holds
  simulated names.
"""
struct Match
    keys::Vector{Pair{Symbol, Symbol}}   # target column => simulation key
    at_column::Union{Symbol, Nothing}    # target column holding each row's `at`
    at_axis::Union{Symbol, Nothing}      # simulation axis; nothing = no `at`
    at_value::Any                        # constant `at` when at_column === nothing
    variable::Any                        # Symbol, AbstractDict, or nothing (the TargetSet's :variable column)

    function Match(keys...; at = nothing, variable = nothing)
        at_column, at_axis, at_value = _match_at(at)
        variable === nothing || variable isa Symbol || variable isa AbstractDict || throw(ArgumentError(
            "Match: `variable` is a simulated variable name or a Dict of measured => simulated names; got $(repr(variable))"))
        new(_match_keys(collect(Any, keys)), at_column, at_axis, at_value, variable)
    end
end

function Base.show(io::IO, m::Match)
    keys = [t == k ? repr(t) : "$(repr(t)) => $(repr(k))" for (t, k) in m.keys]
    options = String[]
    if m.at_axis !== nothing
        push!(options, "at = " * (m.at_column === nothing ? "$(repr(m.at_axis)) => $(repr(m.at_value))" :
            m.at_column == m.at_axis ? repr(m.at_axis) : "$(repr(m.at_column)) => $(repr(m.at_axis))"))
    end
    m.variable === nothing || push!(options, "variable = $(repr(m.variable))")
    print(io, "Match(", join(keys, ", "), isempty(options) ? "" : "; " * join(options, ", "), ")")
end

_match_keys(::Nothing) = Pair{Symbol, Symbol}[]
_match_keys(col::Symbol) = [col => col]
_match_keys(pair::Pair{Symbol, Symbol}) = [pair]
_match_keys(cols::AbstractVector) = reduce(vcat, [_match_keys(c) for c in cols]; init=Pair{Symbol, Symbol}[])
_match_keys(x) = throw(ArgumentError(
    "Match: keys are :col, :col => :simkey, or a vector of these; got $(repr(x))"))

_match_at(::Nothing) = (nothing, nothing, nothing)
_match_at(col::Symbol) = (col, col, nothing)
_match_at(pair::Pair{Symbol, Symbol}) = (first(pair), last(pair), nothing)
_match_at(pair::Pair{Symbol, <:Function}) = throw(ArgumentError(
    "Match: `at` does not take transforms; convert the target column first " *
    "(e.g. @transform(df, :TIME = :TIME_hr * 3600)) and pass `at = :TIME`"))
_match_at(pair::Pair{Symbol}) = (nothing, first(pair), last(pair))
_match_at(x) = throw(ArgumentError(
    "Match: `at` is :col, :col => :axis, or :axis => value; got $(repr(x))"))

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
# Binding a TargetSet to its mapping
# ============================================================

"""
The mapping declared by `match`/`at`/`variable` keywords, or `predict`
(`nothing` when neither was given). The two are alternatives.
"""
function _keyword_mapping(predict, match, at, variable, caller::AbstractString)
    isnothing(match) && isnothing(at) && isnothing(variable) && return predict
    isnothing(predict) || throw(ArgumentError(
        "$caller: pass either `predict` or `match`/`at`/`variable`, not both"))
    keys = isnothing(match) ? () : match isa AbstractVector ? Tuple(match) : (match,)
    return Match(keys...; at = at, variable = variable)
end

"""
Pair a TargetSet with its mapping for scoring: a copy of its rows (renamed after
the `Match` keys when the names were generated) and the row predictor.
"""
function _bind(ts::TargetSet, mapping, caller::AbstractString)
    mapping === nothing && throw(ArgumentError(
        "$caller: nothing says how the TargetSet's rows line up with the simulation output. " *
        "Pass `match`/`at`/`variable`, e.g. `match = :dose, at = :TIME => 24.0, variable = :Conc`, " *
        "or `predict = (sim, row) -> value`. With several TargetSets, pair each with its own: " *
        "`fit(pk => Match(:dose; at = :TIME, variable = :Conc), pd => ...; ...)`."))
    df = DataFrame(ts.df)
    if mapping isa Match
        _check_match(ts, mapping, caller)
        ts.auto_names && _match_names!(df, mapping)
        return Pair{DataFrame, Function}(df, MatchPredictor(mapping))
    end
    mapping isa Function || throw(ArgumentError(
        "$caller: pair each TargetSet with a Match(...) or a predict function; got $(typeof(mapping))"))
    return Pair{DataFrame, Function}(df, mapping)
end

function _check_match(ts::TargetSet, m::Match, caller::AbstractString)
    df = ts.df
    for (col, _) in m.keys
        _require_target_column(df, col, "match", caller)
    end
    isnothing(m.at_column) || _require_target_column(df, m.at_column, "at", caller)
    any(_is_series_value, df.value) && throw(ArgumentError(
        "$caller: series-valued targets `(t=..., y=...)` cannot be matched; " *
        "use one row per point with `at = :TIME`, or a `predict` function"))

    has_column = :variable in propertynames(df)
    if m.variable isa Symbol
        has_column && throw(ArgumentError(
            "$caller: the TargetSet names each row's measured variable (its `variable` column); " *
            "translate those names with `variable = Dict(\"<measured>\" => :<simulated>)`, " *
            "or omit `variable` if they already are simulated names"))
    elseif m.variable isa AbstractDict
        has_column || throw(ArgumentError(
            "$caller: `variable = Dict(...)` translates the TargetSet's `variable` column, " *
            "but it has none; pass the simulated name instead, e.g. `variable = :Conc`"))
        unmapped = unique([v for v in df.variable if _lookup_variable(m.variable, v) === nothing])
        isempty(unmapped) || throw(ArgumentError(
            "$caller: `variable` has no simulated name for $(join(repr.(unmapped), ", "))"))
    else
        has_column || throw(ArgumentError(
            "$caller: name the simulated variable to compare with, e.g. `variable = :Conc`"))
    end
    return nothing
end

function _require_target_column(df::DataFrame, col::Symbol, role::String, caller::AbstractString)
    col in propertynames(df) || throw(ArgumentError(
        "$caller: `$role` column :$col is not in the TargetSet (columns: $(join(names(df), ", ")))"))
    any(ismissing, df[!, col]) && throw(ArgumentError(
        "$caller: `$role` column :$col has missing values"))
    return nothing
end

function _lookup_variable(mapping::AbstractDict, measured)
    for (k, v) in mapping
        _key_equal(k, measured) && return Symbol(v)
    end
    return nothing
end

"""Name rows after their measured variable, match keys, and `at` column: `:"dose=10.0,TIME=24.0"`."""
function _match_names!(df::DataFrame, m::Match)
    cols = Symbol[first(k) for k in m.keys]
    isnothing(m.at_column) || push!(cols, m.at_column)
    per_row_variable = :variable in propertynames(df)
    (isempty(cols) && !per_row_variable) && return df
    df[!, :name] = map(eachrow(df)) do row
        parts = ["$c=$(row[c])" for c in cols]
        per_row_variable && pushfirst!(parts, string(row.variable))
        Symbol(join(parts, ","))
    end
    return df
end

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

function _match_query(row, m::Match)
    keys = Pair{Symbol, Any}[simkey => row[col] for (col, simkey) in m.keys]
    at = isnothing(m.at_axis) ? nothing :
        isnothing(m.at_column) ? m.at_value : row[m.at_column]
    variable = m.variable isa Symbol ? m.variable :
        m.variable === nothing ? Symbol(row.variable) : _lookup_variable(m.variable, row.variable)
    name = hasproperty(row, :name) ? row.name : nothing
    return _MatchQuery(name, keys, m.at_axis, at, variable)
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
function _match_predictions(sim, df::AbstractDataFrame, m::Match)
    source = _normalize_source(sim)
    return Any[_resolve(source, _match_query(row, m)) for row in eachrow(df)]
end

"""
    MatchPredictor(match)

`predict_fn` for a TargetSet bound to a `Match`. Scoring and objectives call
`_match_predictions` once per TargetSet; calling it per row also works.
"""
struct MatchPredictor <: Function
    match::Match
end

(p::MatchPredictor)(sim, row) = _resolve(_normalize_source(sim), _match_query(row, p.match))

"""Predictions for all rows: batched for `MatchPredictor`, otherwise `nothing` (call per row)."""
_batch_predictions(predict_fn::MatchPredictor, sim, df) = _match_predictions(sim, df, predict_fn.match)
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
