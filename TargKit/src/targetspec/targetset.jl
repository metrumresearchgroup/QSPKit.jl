# ============================================================
# TargetSet Constructor — Pair syntax & wide format support
# ============================================================

"""
    TargetSet(df::DataFrame; kwargs...)

Construct a TargetSet from a DataFrame with column role declarations.

# Column Roles (keyword arguments)
- `value` — observed values column (default: `:value`)
- `lower` — range lower bound column (default: `:lower`)
- `upper` — range upper bound column (default: `:upper`)
- `condition` — simulation condition identifier column
- `variable` — solution variable name column
- `timepoint` — observation timepoint column
- `weight` — observation weights column

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
normalize_reading(x) = x / 10.0

ts = TargetSet(df;
    value     = :raw_reading => normalize_reading,
    lower     = :raw_lower => normalize_reading,
    upper     = :raw_upper => normalize_reading,
    condition = :mode => Dict("Nominal" => :nominal),
    variable  = :measure => Dict("Controller gain" => :gain),
    loss = :squared,
)
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
    targets   = nothing,
    loss::Union{Symbol, Function} = :log,
    metadata  = nothing,
)
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

    # Auto-generate :name from :condition + :variable if not present
    if :name ∉ propertynames(result)
        _auto_generate_name!(result)
    else
        result[!, :name] = Symbol.(result[!, :name])
    end

    return TargetSet(result, loss, metadata)
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
        if spec != role && spec in propertynames(df)
            if role ∉ propertynames(df)
                DataFrames.rename!(df, spec => role)
            end
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
