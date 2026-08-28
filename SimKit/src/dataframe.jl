# ============================================================
# to_dataframe — convert branch results to a tidy DataFrame
# ============================================================

import DataFrames: DataFrame
import SymbolicIndexingInterface

"""
    to_dataframe(results::Dict; key_col=nothing, arm=nothing, vars=nothing, kwargs...)
    to_dataframe(sol::SciMLBase.AbstractODESolution; vars=nothing)

Convert branch results to a long-format DataFrame.

By default, MTK-backed solutions include both state variables and observed
variables from `observed(sys)`. Pass `vars` to request an exact variable list.

Each dictionary value can be a `SimContext` (single simulation), an `ODESolution`,
or a `Vector{NamedTuple}` (scan results). Scan parameter columns are preserved.
By default, the key column is `:ARM` for SimKit contexts/scans and `:SIM_NAME`
for raw `ODESolution` dictionaries such as `result(ctx)`. Pass
`key_col=:COLUMN` to override the key column name. `arm=:COLUMN` is retained as
an alias for existing callers.

# Example
```julia
# Simple branch
results = branch(baseline,
    :quiet => with(:input_level => 0.2) >> simulate(18.0),
    :nominal => with(:input_level => 0.75) >> simulate(18.0),
    :burst => with(:input_level => 1.4) >> simulate(18.0),
)
df = to_dataframe(results)

# Branch with scan inside each arm
results = branch(baseline,
    :pulse => scan(:input_level => [0.25, 0.75, 1.5],
                   :interval => [1.5, 4.0]) do c, p
        c |> events(make_events(p, :InputA)) |> simulate(18.0)
    end,
    :step => scan(:input_level => [0.4, 1.1, 2.0],
                  :interval => [2.0, 5.5]) do c, p
        c |> events(make_events(p, :InputB)) |> simulate(18.0)
    end,
)
df = to_dataframe(results)
```
"""
function to_dataframe(results::Dict; key_col::Union{Symbol, Nothing}=nothing,
                      arm::Union{Symbol, Nothing}=nothing, vars=nothing, kwargs...)
    column = _dict_key_column(results, key_col, arm)
    dfs = DataFrame[]
    for (arm_name, res) in results
        if res isa SimContext
            isempty(res.phases) && continue
            sol = res.phases[end].sol
            df = _sol_to_df(sol, vars)
        elseif res isa SciMLBase.AbstractODESolution
            df = _sol_to_df(res, vars)
        elseif res isa Vector
            df = to_dataframe(res; vars=vars, kwargs...)
        else
            error("Unsupported branch result type: $(typeof(res))")
        end
        df[!, column] .= string(arm_name)
        push!(dfs, df)
    end
    reduce(vcat, dfs)
end

to_dataframe(sol::SciMLBase.AbstractODESolution; vars=nothing) = _sol_to_df(sol, vars)

function to_dataframe(ctx::SimContext; vars=nothing)
    isempty(ctx.phases) && error("to_dataframe requires at least one completed simulation phase")
    sol = ctx.phases[end].sol
    _sol_to_df(sol, vars)
end

"""
    to_dataframe(scan_results::Vector; vars=nothing, carry_out=Symbol[], kwargs...)

Convert scan results (from `scan()`) to a long-format DataFrame.
Each scanned parameter becomes a column alongside TIME, state variables, and
MTK observed variables when available.
Works with both SimContext and PopulationResult scan entries.

For `SimContext` entries, `carry_out` looks up model parameters by name.
For `PopulationResult` entries, `carry_out` and other `kwargs` (e.g., `obsonly`)
are forwarded to the PopulationResult `to_dataframe`.

# Example
```julia
# Single-subject scan
sweep = scan(ctx, :damping => [0.2, 0.5, 0.8]) do c, p
    c |> with(p) |> simulate(12.0)
end
df = to_dataframe(sweep; vars=[sys.state_a], carry_out=[:scale, :group_value])

# Population scan
sweep = scan(ctx, :baseline_level => [2.0, 4.0, 6.0]) do c, p
    c |> with(p) |> subjects(pop) |> simulate()
end
df = to_dataframe(sweep; obsonly=true, carry_out=[:GROUP])
```
"""
function to_dataframe(scan_results::Vector{<:NamedTuple}; vars=nothing,
                      carry_out::Union{Vector{Symbol}, Symbol}=Symbol[], kwargs...)
    dfs = DataFrame[]
    for entry in scan_results
        res = entry.result
        if res isa PopulationResult
            df = to_dataframe(res; vars=vars, carry_out=carry_out, kwargs...)
        else
            isempty(res.phases) && error("to_dataframe requires each scan SimContext to have at least one completed simulation phase")
            sol = res.phases[end].sol
            df = _sol_to_df(sol, vars)

            # carry_out for SimContext: read from model parameters
            # skip any that are already scanned params (added below)
            cols = carry_out === :auto ? Symbol[] : carry_out
            for col in cols
                haskey(entry.params, col) && continue
                if _has_parameter(res.prob, col)
                    df[!, col] .= _get_parameter(res.prob, col)
                else
                    avail = [_param_name(s) for s in SciMLBase.parameter_symbols(res.prob)]
                    error("carry_out: :$col not found. Available parameters: $avail")
                end
            end
        end
        # Add scanned parameter columns
        for (k, v) in entry.params
            df[!, k] .= v
        end
        push!(dfs, df)
    end
    reduce(vcat, dfs)
end

# ----------------------------------------------------------
# to_dataframe — PopulationResult → tidy DataFrame
# ----------------------------------------------------------

"""
    to_dataframe(pr::PopulationResult; vars=nothing, obsonly::Bool=false,
                 carry_out::Union{Vector{Symbol}, Symbol}=Symbol[])

Convert population simulation results to a tidy DataFrame.

# Arguments
- `vars`: Variables to include (default: all state variables plus MTK observed
  variables when available)
- `obsonly`: If `true`, output only at observation times and include DV column
- `carry_out`: Columns to carry into output rows.
  - `:auto` — carry all columns from `subject.columns` (everything from the input DataFrame)
  - `[:WT, :STUDY]` — carry specific columns
  Looks up each name in subject columns, then model parameters. Errors if not found.

# Output columns
`ID`, `TIME`, state variables (or `vars`), optionally `DV`, and `carry_out` columns.
"""
function to_dataframe(pr::PopulationResult; vars=nothing, obsonly::Bool=false,
                      carry_out::Union{Vector{Symbol}, Symbol}=Symbol[])
    dfs = DataFrame[]
    for subj in pr.population
        id = subj.id
        haskey(pr.contexts, id) || continue
        ctx = pr.contexts[id]
        isempty(ctx.phases) && continue

        sol = ctx.phases[end].sol

        if obsonly
            isempty(subj.obs_times) && continue  # skip dose-only subjects
            df = _sol_to_df_at(sol, subj.obs_times, vars)
            if subj.obs_values !== nothing
                df[!, :DV] = subj.obs_values
            end
        else
            df = _sol_to_df(sol, vars)
        end

        df[!, :ID] .= id

        # Resolve carry_out columns
        carry_cols = if carry_out === :auto
            collect(keys(subj.columns))
        else
            carry_out
        end

        for col in carry_cols
            if haskey(subj.columns, col)
                df[!, col] .= subj.columns[col]
            elseif _has_parameter(ctx.prob, col)
                df[!, col] .= _get_parameter(ctx.prob, col)
            else
                avail = collect(keys(subj.columns))
                avail_params = [_param_name(s) for s in SciMLBase.parameter_symbols(ctx.prob)]
                error("carry_out: :$col not found. Available columns: $avail, parameters: $avail_params")
            end
        end

        push!(dfs, df)
    end

    isempty(dfs) ? DataFrame() : reduce(vcat, dfs)
end

"""
    to_dataframe(; kwargs...)

Curried form for pipeline use: `pr |> to_dataframe(; obsonly=true)`.
"""
to_dataframe(; kwargs...) = PipelineStep(:to_dataframe, pr -> to_dataframe(pr; kwargs...))

# ----------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------

_param_name(s) = Symbol(SciMLBase.getname(s))
_var_name(v::Symbol) = v
_var_name(v) = Symbol(SciMLBase.getname(v))

function _solution_system(sol)
    return try
        sol.prob.f.sys
    catch
        nothing
    end
end

function _observed_equations(sys)
    return try
        ConfigKit.MTK.observed(sys)
    catch
        try
            getproperty(sys, :observed)
        catch
            Any[]
        end
    end
end

function _observed_symbols(sol)
    sys = _solution_system(sol)
    sys === nothing && return Any[]
    return [eq.lhs for eq in _observed_equations(sys)]
end

function _default_symbols(sol)
    symbols = Any[]
    seen = Set{Symbol}()

    for s in SciMLBase.variable_symbols(sol)
        name = _var_name(s)
        if name ∉ seen
            push!(symbols, s)
            push!(seen, name)
        end
    end

    for s in _observed_symbols(sol)
        name = _var_name(s)
        if name ∉ seen
            push!(symbols, s)
            push!(seen, name)
        end
    end

    return symbols
end

function _dict_key_column(results::Dict, key_col::Union{Symbol, Nothing},
                          arm::Union{Symbol, Nothing})
    if key_col !== nothing && arm !== nothing
        throw(ArgumentError("Pass either `key_col` or `arm`, not both."))
    end

    key_col !== nothing && return key_col
    arm !== nothing && return arm
    return _default_dict_key_column(results)
end

function _default_dict_key_column(results::Dict)
    vals = collect(values(results))
    if !isempty(vals) && all(res -> res isa SciMLBase.AbstractODESolution, vals)
        return :SIM_NAME
    end

    return :ARM
end

function _raw_state_columns(values)
    isempty(values) && return Pair{Symbol, Any}[]
    first_value = first(values)
    if first_value isa Number
        return [:u => values]
    end

    n = length(first_value)
    return [Symbol(:u, i) => [u[i] for u in values] for i in 1:n]
end

function _raw_solution_df(sol, times)
    values = [sol(t) for t in times]
    df = DataFrame(:TIME => times)
    for (name, col) in _raw_state_columns(values)
        df[!, name] = col
    end
    return df
end

"""Check whether `name` (Symbol) is a parameter in the ODEProblem."""
function _has_parameter(prob, name::Symbol)
    for s in SciMLBase.parameter_symbols(prob)
        _param_name(s) == name && return true
    end
    return false
end

"""Get the value of parameter `name` from the ODEProblem."""
function _get_parameter(prob, name::Symbol)
    for s in SciMLBase.parameter_symbols(prob)
        if _param_name(s) == name
            getter = SymbolicIndexingInterface.getp(prob, s)
            return getter(prob)
        end
    end
    error("parameter :$name not found")
end

"""Interpolate solution at specific time points."""
function _sol_to_df_at(sol, times::Vector{Float64}, vars)
    if vars === nothing
        syms = _default_symbols(sol)
        isempty(syms) && return _raw_solution_df(sol, times)

        df = DataFrame(:TIME => times)
        for s in syms
            col_name = _var_name(s)
            df[!, col_name] = [sol(t, idxs=s) for t in times]
        end
        return df
    else
        df = DataFrame(:TIME => times)
        for v in vars
            col_name = _var_name(v)
            df[!, col_name] = [sol(t, idxs=v) for t in times]
        end
        return df
    end
end

function _sol_to_df(sol, vars)
    t = sol.t
    if vars === nothing
        syms = _default_symbols(sol)
        if isempty(syms)
            df = DataFrame(:TIME => t)
            for (name, col) in _raw_state_columns(sol.u)
                df[!, name] = col
            end
            return df
        end

        df = DataFrame(:TIME => t)
        for s in syms
            col_name = _var_name(s)
            df[!, col_name] = sol[s]
        end
        return df
    else
        df = DataFrame(:TIME => t)
        for v in vars
            col_name = _var_name(v)
            df[!, col_name] = sol[v]
        end
        return df
    end
end
