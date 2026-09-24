# ============================================================
# TargetSet Constructor — Pair syntax & wide format support
# ============================================================

"""
    TargetSet(df::DataFrame; kwargs...)

Construct a TargetSet from a DataFrame with column role declarations.

# Column Roles (keyword arguments)
- `value` — observed values column (default: `:value`). `:obs => :simvar`
  names the simulated variable it is compared with.
- `lower` — range lower bound column (default: `:lower`)
- `upper` — range upper bound column (default: `:upper`)
- `variable` — solution variable name column
- `weight` — observation weights column
- `condition` — deprecated; use `match`
- `timepoint` — deprecated; use `at`

# Matching simulation output
- `match` — target column(s) holding discrete keys matched against the
  simulation output: `:dose`, `:donor_id => :donor`, or a vector of these
- `at` — one ordered axis within each match group: `:TIME` (a target column
  named like the simulation axis), `:TIME_hr => :TIME`, or `:TIME => 672.0`
  (every target at one point)

With `match`/`at`, the simulated variable defaults to the observed column's
name. See `TargKit/docs/matching.md`.

# Pair Syntax for transforms/recoding
- `:col` — use column as-is
- `:col => fn` — apply transform: `fn(x) -> y`
- `:col => Dict(...)` — recode values: `"old" => :new`

# Wide Format
- `targets` — columns to stack from wide to long format

# Config
- `loss` — loss type (default: `:log`)
- `metadata` — optional YspecMetadata from SpecKit

# Examples
```julia
pct_to_ratio(x) = 1.0 + x / 100.0

ts = TargetSet(df;
    value     = :mean_pct_change => pct_to_ratio,
    lower     = :error_lower => pct_to_ratio,
    upper     = :error_upper => pct_to_ratio,
    condition = :treatment => Dict("Anti-IL5" => :mepolizumab),
    variable  = :outcome_measure => Dict("Blood_Eos" => :Blood_Eos),
    loss = :log,
)

# Concentration 24 h after each dose level
ts = TargetSet(df; match = :dose, value = :Conc, at = :TIME => 24.0)
```
"""
function TargetSet(df::DataFrame;
    value     = :value,
    lower     = :lower,
    upper     = :upper,
    condition = nothing,
    variable  = nothing,
    timepoint = nothing,
    weight    = nothing,
    match     = nothing,
    at        = nothing,
    targets   = nothing,
    loss::Union{Symbol, Function} = :log,
    metadata  = nothing,
)
    matching = !isnothing(match) || !isnothing(at)
    if matching
        isnothing(condition) || throw(ArgumentError(
            "TargetSet: `condition` cannot be combined with `match`/`at`; list the column in `match` instead"))
        isnothing(timepoint) || throw(ArgumentError(
            "TargetSet: `timepoint` cannot be combined with `match`/`at`; use `at` instead"))
    else
        isnothing(condition) || Base.depwarn(
            "TargetSet(...; condition) is deprecated; use `match` instead.", :TargetSet)
        isnothing(timepoint) || Base.depwarn(
            "TargetSet(...; timepoint) is deprecated; use `at` instead.", :TargetSet)
    end

    value, value_variable = _split_value_variable(value)
    result = copy(df)

    # Handle wide format pivot first
    if !isnothing(targets)
        result = _pivot_wide_to_long(result, targets, timepoint)
    end

    # Process column role declarations with Pair syntax
    result = _process_role!(result, :value, value)
    result = _process_role!(result, :lower, lower)
    result = _process_role!(result, :upper, upper)
    result = _process_role!(result, :condition, condition)
    result = _process_role!(result, :variable, variable)
    result = _process_role!(result, :timepoint, timepoint)
    result = _process_role!(result, :weight, weight)

    # Ensure :value exists
    :value in propertynames(result) || error("Data must have a :value column (specify via `value=:colname`)")

    # Fill :lower/:upper with NaN if missing
    if :lower ∉ propertynames(result)
        result[!, :lower] .= NaN
    end
    if :upper ∉ propertynames(result)
        result[!, :upper] .= NaN
    end

    spec = matching ? _match_spec(result, match, at, value, value_variable) : nothing

    # Auto-generate :name from :condition + :variable if not present
    if :name ∉ propertynames(result)
        isnothing(spec) ? _auto_generate_name!(result) : _auto_generate_match_names!(result, spec)
    else
        result[!, :name] = Symbol.(result[!, :name])
    end

    return TargetSet(result, loss, metadata, spec)
end

# ============================================================
# Internal: match / at
# ============================================================

"""Split `value = :obs => :simvar` (or `:obs => fn => :simvar`) into the role spec and the variable."""
_split_value_variable(value) = (value, nothing)
_split_value_variable(value::Pair{Symbol, Symbol}) = (first(value), last(value))
_split_value_variable(value::Pair{Symbol, <:Pair{<:Any, Symbol}}) =
    (first(value) => first(last(value)), last(last(value)))

function _match_spec(df::DataFrame, match, at, value, value_variable)
    keys = _match_keys(match)
    for (col, _) in keys
        _require_match_column(df, col, "match")
    end
    at_column, at_axis, at_value = _match_at(at)
    isnothing(at_column) || _require_match_column(df, at_column, "at")

    if any(_is_series_value, df.value)
        throw(ArgumentError("TargetSet: series-valued targets `(t=..., y=...)` are not supported " *
            "with `match`/`at`; use one row per point with `at = :TIME`"))
    end

    has_variable_column = :variable in propertynames(df)
    variable = if !isnothing(value_variable)
        has_variable_column && throw(ArgumentError(
            "TargetSet: the simulated variable is named twice, by `value = ... => :$value_variable` " *
            "and by a :variable column; keep one"))
        value_variable
    elseif has_variable_column
        nothing
    else
        source = value isa Pair ? first(value) : value
        source == :value && throw(ArgumentError(
            "TargetSet: cannot tell which simulated variable the :value column is compared with. " *
            "Name it with `value = :value => :simvar`, or pass the observed column by the " *
            "simulated variable's name (`value = :Conc`)"))
        source
    end

    return MatchSpec(keys, at_column, at_axis, at_value, variable)
end

_match_keys(::Nothing) = Pair{Symbol, Symbol}[]
_match_keys(col::Symbol) = [col => col]
_match_keys(pair::Pair{Symbol, Symbol}) = [pair]
_match_keys(cols::AbstractVector) = reduce(vcat, [_match_keys(c) for c in cols]; init=Pair{Symbol, Symbol}[])
_match_keys(x) = throw(ArgumentError(
    "TargetSet: `match` takes :col, :col => :simkey, or a vector of these; got $(repr(x))"))

_match_at(::Nothing) = (nothing, nothing, nothing)
_match_at(col::Symbol) = (col, col, nothing)
_match_at(pair::Pair{Symbol, Symbol}) = (first(pair), last(pair), nothing)
_match_at(pair::Pair{Symbol, <:Function}) = throw(ArgumentError(
    "TargetSet: `at` does not take transforms; convert the target column first " *
    "(e.g. @transform(df, :TIME = :TIME_hr * 3600)) and pass `at = :TIME`"))
_match_at(pair::Pair{Symbol}) = (nothing, first(pair), last(pair))
_match_at(x) = throw(ArgumentError(
    "TargetSet: `at` takes :col, :col => :axis, or :axis => value; got $(repr(x))"))

function _require_match_column(df::DataFrame, col::Symbol, role::String)
    col in propertynames(df) || throw(ArgumentError(
        "TargetSet: `$role` column :$col not found (columns: $(join(names(df), ", ")))"))
    any(ismissing, df[!, col]) && throw(ArgumentError(
        "TargetSet: `$role` column :$col has missing values"))
    return nothing
end

"""Name matched targets after their variable, match keys, and `at` column: `:"dose=10.0,TIME=24.0"`."""
function _auto_generate_match_names!(df::DataFrame, spec::MatchSpec)
    cols = Symbol[first(k) for k in spec.keys]
    isnothing(spec.at_column) || push!(cols, spec.at_column)
    per_row_variable = isnothing(spec.variable)

    if isempty(cols) && !per_row_variable
        df[!, :name] = [Symbol("target_$i") for i in 1:nrow(df)]
        return df
    end
    df[!, :name] = map(eachrow(df)) do row
        parts = ["$c=$(row[c])" for c in cols]
        per_row_variable && pushfirst!(parts, string(row.variable))
        Symbol(join(parts, ","))
    end
    return df
end

# ============================================================
# Internal: Process column role with Pair syntax
# ============================================================

"""
Process a column role declaration. Handles three forms:
- `:col` — rename column to role name
- `:col => fn` — apply function transform, then rename
- `:col => Dict(...)` — recode values, then rename
- `nothing` — skip
"""
function _process_role!(df::DataFrame, role::Symbol, spec)
    isnothing(spec) && return df

    if spec isa Symbol
        # :col — use as-is, rename if needed
        if spec != role
            spec in propertynames(df) || throw(ArgumentError(
                "TargetSet: `$role` column :$spec not found (columns: $(join(names(df), ", ")))"))
            role in propertynames(df) && throw(ArgumentError(
                "TargetSet: cannot use :$spec as `$role` because the data already has a :$role column"))
            DataFrames.rename!(df, spec => role)
        end
    elseif spec isa Pair
        src_col, transform = spec
        src_col::Symbol
        src_col in propertynames(df) || error("Column :$src_col not found in DataFrame")

        if transform isa Function
            # :col => fn — apply function
            df[!, role] = [_safe_transform(transform, v) for v in df[!, src_col]]
        elseif transform isa Dict
            # :col => Dict(...) — recode
            df[!, role] = [_recode(v, transform) for v in df[!, src_col]]
        else
            error("Pair value must be a Function or Dict, got $(typeof(transform))")
        end
    else
        error("Column role spec must be a Symbol or Pair, got $(typeof(spec))")
    end

    return df
end

"""Apply a recode Dict to a value. Unmatched values pass through as Symbols."""
function _recode(val, mapping::Dict)
    str_val = strip(string(val))
    # Try exact match first
    for (k, v) in mapping
        if string(k) == str_val
            return v
        end
    end
    # No match — symbolify as-is
    return Symbol(str_val)
end

"""Apply transform, handling NaN/missing gracefully."""
function _safe_transform(fn, val)
    (ismissing(val) || (val isa Real && isnan(val))) ? NaN : fn(val)
end

# ============================================================
# Internal: Wide format pivot
# ============================================================

"""Pivot wide format columns into long format with :variable and :value."""
function _pivot_wide_to_long(df::DataFrame, target_cols::Vector{Symbol}, _timepoint)
    rows = NamedTuple[]
    other_cols = [c for c in Symbol.(names(df)) if c ∉ target_cols]

    for row in eachrow(df)
        base = NamedTuple{Tuple(other_cols)}(Tuple(getproperty(row, c) for c in other_cols))
        for col in target_cols
            new_row = merge(base, (variable=col, value=getproperty(row, col)))
            push!(rows, new_row)
        end
    end

    isempty(rows) ? DataFrame() : DataFrame(rows)
end

# ============================================================
# Internal: Auto-generate :name
# ============================================================

"""Auto-generate :name from :condition + :variable + :timepoint columns."""
function _auto_generate_name!(df::DataFrame)
    dim_cols = Symbol[]
    for col in (:condition, :variable, :timepoint)
        col in propertynames(df) && push!(dim_cols, col)
    end

    if isempty(dim_cols)
        # Fall back: use :value index
        if :value in propertynames(df)
            df[!, :name] = [Symbol("target_$i") for i in 1:nrow(df)]
        else
            error("Cannot auto-generate :name — no :condition, :variable, or :timepoint columns")
        end
    else
        df[!, :name] = map(eachrow(df)) do row
            parts = [string(getproperty(row, c)) for c in dim_cols]
            Symbol(join(parts, "_"))
        end
    end
end
