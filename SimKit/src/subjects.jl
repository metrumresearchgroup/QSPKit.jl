# ============================================================
# Subject, Population, and multi-subject simulation
# ============================================================

import DataFrames: DataFrame, groupby, nrow, names as df_names

# ----------------------------------------------------------
# Display
# ----------------------------------------------------------

function Base.show(io::IO, s::Subject)
    n_ev = length(s.events)
    n_obs = length(s.obs_times)
    has_dv = s.obs_values !== nothing
    cov_names = keys(s.covariates)
    col_names = keys(s.columns)
    parts = String[]
    push!(parts, "id=$(s.id)")
    n_ev > 0 && push!(parts, "$n_ev event$(n_ev == 1 ? "" : "s")")
    n_obs > 0 && push!(parts, "$n_obs obs$(has_dv ? " (DV)" : "")")
    if s.obs_censors !== nothing
        n_censored = count(!=(:none), s.obs_censors)
        n_censored > 0 && push!(parts, "$n_censored censored")
    end
    !isempty(cov_names) && push!(parts, "params=$(cov_names)")
    length(col_names) > length(cov_names) && push!(parts, "cols=$(col_names)")
    print(io, "Subject(", join(parts, ", "), ")")
end

function Base.show(io::IO, ::MIME"text/plain", pop::Population)
    n = length(pop)
    println(io, "Population: $n subject$(n == 1 ? "" : "s")")
    n_obs = sum(length(s.obs_times) for s in pop; init=0)
    n_ev = sum(length(s.events) for s in pop; init=0)
    has_dv = any(s -> s.obs_values !== nothing, pop)
    n_censored = sum(s -> s.obs_censors === nothing ? 0 : count(!=(:none), s.obs_censors), pop; init=0)
    println(io, "  $n_obs total observations$(has_dv ? " (with DV)" : ""), $n_ev total events")
    n_censored > 0 && println(io, "  $n_censored censored observations")
    if n > 0 && !isempty(keys(pop[1].covariates))
        println(io, "  Parameters: $(keys(pop[1].covariates))")
    end
    if n > 0 && length(keys(pop[1].columns)) > length(keys(pop[1].covariates))
        println(io, "  Columns: $(keys(pop[1].columns))")
    end
    if n <= 10
        for s in pop
            println(io, "  ", s)
        end
    else
        for s in pop[1:5]
            println(io, "  ", s)
        end
        println(io, "  ⋮ ($(n - 10) more)")
        for s in pop[end-4:end]
            println(io, "  ", s)
        end
    end
end

# Reserved column names — never auto-detected as parameter overrides
const _RESERVED_COLUMNS = Set([:ID, :TIME, :DV, :AMT, :EVID, :CMT, :DVID, :RATE, :DURATION, :II, :ADDL, :SS,
                                :BLQ, :LLOQ, :ULOQ, :LOQ, :CENS, :CENSOR, :CENSORED,
                                :id, :time, :dv, :amt, :evid, :cmt, :dvid, :rate, :duration, :ii, :addl, :ss,
                                :blq, :lloq, :uloq, :loq, :cens, :censor, :censored])

# True if a DataFrame column's non-missing element type is numeric
_is_numeric_column(df, col) = Base.nonmissingtype(eltype(df[!, col])) <: Number

# All columns except the excluded ones (for subject.columns — carry_out source)
function _all_carryable_cols(df, excluded_cols::Symbol...)
    excluded = Set(excluded_cols)
    [c for c in Symbol.(df_names(df)) if !(c in excluded)]
end

_missing_to_nothing(value) = (value === nothing || ismissing(value)) ? nothing : value

function _resolve_censoring(df, censoring)
    censoring === nothing && return nothing, :none
    all_cols = Symbol.(df_names(df))
    if censoring isa Pair
        col = Symbol(first(censoring))
        kind = Symbol(last(censoring))
    elseif censoring isa Symbol
        col = censoring
        kind = :left
    else
        error("censoring must be nothing, a column Symbol, or a Pair like :BLQ => :left")
    end
    col in all_cols || error("Censoring column :$col not found in DataFrame")
    kind in (:left, :right) ||
        error("Censoring kind must be :left or :right, got :$kind")
    return col, kind
end

function _resolve_censor_limit_source(df, loq)
    loq === nothing && return nothing
    loq isa Symbol || loq isa Real ||
        error("loq must be nothing, a numeric constant, or a column Symbol")
    if loq isa Symbol
        loq in Symbol.(df_names(df)) || error("LOQ column :$loq not found in DataFrame")
    end
    return loq
end

function _row_is_censored(value)
    (value === nothing || ismissing(value)) && return false
    value isa Bool && return value
    value isa Number && return value != 0
    value isa AbstractString && return !(_is_missing_str(value) || value == "0" || lowercase(value) == "false")
    return Bool(value)
end

function _row_censor_limit(row, limit_source)
    limit_source === nothing &&
        error("Censored observations require `loq` as a numeric value or column Symbol")
    value = limit_source isa Symbol ? row[limit_source] : limit_source
    limit = _to_float64(value)
    limit === nothing && error("Censored observation has missing censoring limit")
    limit > 0 || error("Censoring limit must be positive, got $limit")
    return limit
end

# Extract columns from a row, keeping original types (missing → nothing)
function _extract_all_columns(row, cols::Vector{Symbol})
    isempty(cols) && return NamedTuple()
    vals = Tuple(let v = row[col]; ismissing(v) ? nothing : v end for col in cols)
    NamedTuple{Tuple(cols)}(vals)
end

function _extract_event_param_changes(row, cols::Vector{Symbol}, excluded_cols)
    changes = Dict{Union{Symbol, InjecKit.MTK.Num}, Float64}()
    for col in cols
        (col in _RESERVED_COLUMNS || col in excluded_cols) && continue
        value = row[col]
        (ismissing(value) || value === nothing) && continue
        value isa Number || continue
        changes[col] = Float64(value)
    end
    return changes
end

# ----------------------------------------------------------
# Population constructor — NONMEM event-level data
# ----------------------------------------------------------

"""
    Population(df::DataFrame; id, time, dv=nothing, amt=nothing, evid=nothing,
               cmt=nothing, dvid=nothing, parameters=:auto, events=nothing, idata=nothing,
               censoring=nothing, loq=nothing)

Construct a Population from a DataFrame. Supports three construction paths:

**Path 1 — NONMEM event-level data** (when `time` and `evid` are provided):
Multiple rows per subject with dosing events and observations embedded.

    pop = Population(df; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT)

**Path 2 — idata-style** (when `events` kwarg is provided):
One row per subject, shared dosing events for all subjects.

    pop = Population(df; id=:ID, events=QD(100.0, :Depot))

**Path 3 — Combined** (when `idata` kwarg supplements event-level data):
Event-level data drives timeline; idata provides per-subject covariates joined on ID.

    pop = Population(df; id=:ID, time=:TIME, amt=:AMT, evid=:EVID, idata=idata_df)

**Multi-endpoint observations:**
- `dvid=:DVID` — column labeling each observation's endpoint (e.g., `:CONC`, `:EFFECT`)
- Values are converted to Symbols and stored in `subject.obs_names`
- Required when one subject contributes multiple observed endpoints

**Censored observations / BLQ:**
- `censoring=(:BLQ => :left), loq=10.0` keeps BLQ observations and stores
  per-observation censor metadata for likelihoods that support censoring.
- `loq` may be a numeric constant or a column name such as `:LLOQ`.

**Parameter override handling (mrgsolve/NONMEM-style):**
- `parameters=:auto` (default) — all numeric non-reserved columns become parameter overrides.
  At simulation time, the prepared QSPKit update/event executor matches them to model
  parameters and silently ignores non-matching ones.
- `parameters=[:WT, :AGE]` — only those columns become parameter overrides

All non-reserved columns (numeric and non-numeric) are always stored on each Subject
for use with `carry_out` in `to_dataframe`.
"""
function Population(df::DataFrame;
                    id::Symbol=:ID,
                    time::Union{Symbol, Nothing}=nothing,
                    dv::Union{Symbol, Nothing}=nothing,
                    amt::Union{Symbol, Nothing}=nothing,
                    evid::Union{Symbol, Nothing}=nothing,
                    cmt::Union{Symbol, Nothing}=nothing,
                    dvid::Union{Symbol, Nothing}=nothing,
                    parameters::Union{Vector{Symbol}, Symbol}=:auto,
                    events::Union{Vector{InjecKit.IEvent}, Nothing}=nothing,
                    idata::Union{DataFrame, Nothing}=nothing,
                    censoring=nothing,
                    loq=nothing)

    # Validate ID column exists
    id in Symbol.(df_names(df)) || error("Column :$id not found in DataFrame")

    if events !== nothing
        # Path 2: idata-style — one row per subject, shared events
        return _population_from_idata(df, id, parameters, events)
    elseif time !== nothing && evid !== nothing
        # Path 1 or 3: NONMEM event-level data (±idata supplement)
        return _population_from_data(df, id, time, dv, amt, evid, cmt, dvid,
                                     parameters, idata, censoring, loq)
    else
        error("Must provide either `time` + `evid` (NONMEM data) or `events` (idata-style)")
    end
end

# ----------------------------------------------------------
# Path 1/3: NONMEM event-level data → Population
# ----------------------------------------------------------

function _population_from_data(df::DataFrame, id::Symbol, time::Symbol,
                                dv::Union{Symbol, Nothing}, amt::Union{Symbol, Nothing},
                                evid::Symbol, cmt::Union{Symbol, Nothing},
                                dvid::Union{Symbol, Nothing},
                                covariates::Union{Vector{Symbol}, Symbol},
                                idata::Union{DataFrame, Nothing},
                                censoring,
                                loq)
    # Validate dvid column exists if specified
    if dvid !== nothing
        dvid in Symbol.(df_names(df)) || error("DVID column :$dvid not found in DataFrame")
    end
    censor_col, censor_kind = _resolve_censoring(df, censoring)
    limit_source = _resolve_censor_limit_source(df, loq)

    # Collect non-nothing column names to exclude from auto-covariate detection
    excluded = Symbol[id, time, evid]
    dv !== nothing && push!(excluded, dv)
    amt !== nothing && push!(excluded, amt)
    cmt !== nothing && push!(excluded, cmt)
    dvid !== nothing && push!(excluded, dvid)
    censor_col !== nothing && push!(excluded, censor_col)
    limit_source isa Symbol && push!(excluded, limit_source)

    # Build idata lookup if provided; resolve covariates against idata when available
    idata_lookup = nothing
    if idata !== nothing
        cov_cols = _resolve_covariates(idata, covariates, id)
        idata_lookup = Dict(row[id] => _extract_covariates(row, cov_cols) for row in eachrow(idata))
    else
        cov_cols = _resolve_covariates(df, covariates, excluded...)
    end

    # All columns except ID for the columns field (carry_out support)
    all_cols = _all_carryable_cols(df, id)

    subjects = Subject[]
    grouped = groupby(df, id)

    for group in grouped
        subj_id = first(group[!, id])

        # Extract events (EVID != 0)
        subj_events = InjecKit.IEvent[]
        obs_times = Float64[]
        obs_values = dv !== nothing ? Float64[] : nothing
        obs_names = dvid !== nothing ? Symbol[] : nothing
        obs_censors = censor_col !== nothing ? Symbol[] : nothing
        obs_limits = censor_col !== nothing ? Float64[] : nothing

        for row in eachrow(group)
            ev_id = _to_int(row[evid])
            t = _to_float64(row[time])

            if ev_id == 0
                censor = censor_col === nothing ? :none :
                    (_row_is_censored(row[censor_col]) ? censor_kind : :none)
                limit = censor === :none ? NaN : _row_censor_limit(row, limit_source)
                # Observation record — skip if uncensored DV is missing ("." or empty).
                # Censored rows are retained because their likelihood is a CDF
                # evaluated at `limit`, not a density at DV.
                dv_val = dv !== nothing ? _to_float64(row[dv]) : nothing
                if dv !== nothing && dv_val === nothing && censor === :none
                    continue  # missing DV → skip this observation
                end
                push!(obs_times, t)
                if obs_values !== nothing
                    push!(obs_values, dv_val === nothing ? limit : dv_val)
                end
                if obs_names !== nothing
                    push!(obs_names, Symbol(row[dvid]))
                end
                if obs_censors !== nothing
                    push!(obs_censors, censor)
                    push!(obs_limits, limit)
                end
            elseif ev_id == 1
                # Dosing event
                ev_cmt = cmt !== nothing ? _missing_to_nothing(row[cmt]) : nothing
                ev_amt = amt !== nothing ? _to_float64(row[amt]) : nothing
                ev_rate = _get_optional(row, :RATE, :rate)
                ev_ii = _get_optional(row, :II, :ii)
                ev_addl = _get_optional_int(row, :ADDL, :addl)
                ev_ss = _get_optional_int(row, :SS, :ss)
                ev_duration = _get_optional(row, :DURATION, :duration)

                push!(subj_events, InjecKit.IEvent(
                    t, ev_cmt, ev_amt, ev_rate, ev_duration,
                    ev_id, ev_ii, ev_addl, ev_ss,
                    Dict{Union{Symbol, InjecKit.MTK.Num}, Float64}()
                ))
            elseif ev_id in (2, 3, 4)
                # Other event types. For EVID=2, preserve NONMEM-style
                # parameter-change columns as IEvent.param_changes.
                ev_cmt = cmt !== nothing ? _missing_to_nothing(row[cmt]) : nothing
                ev_amt = amt !== nothing && !ismissing(row[amt]) ? _to_float64(row[amt]) : nothing
                param_changes = ev_id == 2 ?
                    _extract_event_param_changes(row, Symbol.(df_names(group)), Set(excluded)) :
                    Dict{Union{Symbol, InjecKit.MTK.Num}, Float64}()
                push!(subj_events, InjecKit.IEvent(
                    t, ev_cmt, ev_amt, nothing, nothing,
                    ev_id, nothing, nothing, nothing,
                    param_changes
                ))
            end
        end

        # Extract covariates (numeric, for parameter overrides) — from idata if available, else from first row
        subj_covariates = if idata_lookup !== nothing
            haskey(idata_lookup, subj_id) || error("Subject $subj_id not found in idata")
            idata_lookup[subj_id]
        elseif !isempty(cov_cols)
            _extract_covariates(first(eachrow(group)), cov_cols)
        else
            NamedTuple()
        end

        # Extract all non-reserved columns (original types, for carry_out)
        subj_columns = !isempty(all_cols) ? _extract_all_columns(first(eachrow(group)), all_cols) : NamedTuple()

        push!(subjects, Subject(subj_id, subj_events, obs_times, obs_values, obs_names,
                                obs_censors, obs_limits, subj_covariates, subj_columns))
    end

    return subjects
end

# ----------------------------------------------------------
# Path 2: idata-style → Population
# ----------------------------------------------------------

function _population_from_idata(df::DataFrame, id::Symbol,
                                 covariates::Union{Vector{Symbol}, Symbol},
                                 events::Vector{InjecKit.IEvent})
    cov_cols = _resolve_covariates(df, covariates, id)
    all_cols = _all_carryable_cols(df, id)

    subjects = Subject[]
    for row in eachrow(df)
        subj_id = row[id]
        subj_covariates = _extract_covariates(row, cov_cols)
        subj_columns = !isempty(all_cols) ? _extract_all_columns(row, all_cols) : NamedTuple()
        # All subjects share the same events; no observations for idata-style
        push!(subjects, Subject(subj_id, copy(events), Float64[], nothing, nothing, subj_covariates, subj_columns))
    end

    return subjects
end

# ----------------------------------------------------------
# Covariate resolution helpers
# ----------------------------------------------------------

function _resolve_covariates(df::DataFrame, covariates::Vector{Symbol}, excluded_cols::Symbol...)
    # Explicit list — validate columns exist
    all_cols = Symbol.(df_names(df))
    for c in covariates
        c in all_cols || error("Covariate column :$c not found in DataFrame")
    end
    return covariates
end

function _resolve_covariates(df::DataFrame, covariates::Symbol, excluded_cols::Symbol...)
    if covariates == :auto
        # Auto-detect: numeric non-reserved columns only (mrgsolve-style)
        all_cols = Symbol.(df_names(df))
        excluded = union(_RESERVED_COLUMNS, Set(excluded_cols))
        return [c for c in all_cols if !(c in excluded) && _is_numeric_column(df, c)]
    else
        error("parameters must be a Vector{Symbol} or :auto, got :$covariates")
    end
end

function _extract_covariates(row, cov_cols::Vector{Symbol})
    isempty(cov_cols) && return NamedTuple()
    vals = Tuple(_coerce_covariate(row, c) for c in cov_cols)
    return NamedTuple{Tuple(cov_cols)}(vals)
end

function _coerce_covariate(row, col::Symbol)
    v = row[col]
    if ismissing(v) || (v isa AbstractString && _is_missing_str(v))
        error("Missing covariate :$col. Covariate columns must not contain missing values — " *
              "fill or drop missing rows before constructing the Population.")
    end
    return v isa AbstractString ? parse(Float64, v) : Float64(v)
end

# ----------------------------------------------------------
# Optional column helpers (case-insensitive lookup)
# ----------------------------------------------------------

_is_missing_str(x::AbstractString) = x == "." || isempty(x)
_to_float64(::Missing) = nothing
_to_float64(x::AbstractString) = _is_missing_str(x) ? nothing : parse(Float64, x)
_to_float64(x::Number) = Float64(x)

_to_int(::Missing) = nothing
_to_int(x::AbstractString) = _is_missing_str(x) ? nothing : parse(Int, x)
_to_int(x::Number) = Int(x)

function _get_optional(row, upper::Symbol, lower::Symbol)
    for col in (upper, lower)
        if hasproperty(row, col)
            val = row[col]
            if !ismissing(val) && val !== nothing
                return _to_float64(val)
            end
        end
    end
    return nothing
end

function _get_optional_int(row, upper::Symbol, lower::Symbol)
    for col in (upper, lower)
        if hasproperty(row, col)
            val = row[col]
            if !ismissing(val) && val !== nothing
                return _to_int(val)
            end
        end
    end
    return nothing
end

# ----------------------------------------------------------
# subjects() — pipeline verb for multi-subject simulation
# ----------------------------------------------------------

"""
    subjects(ctx::SimContext, pop::Population; parallel::Bool=true)

Stage per-subject covariates and dosing events from a Population onto a base SimContext.

For each subject:
1. Applies covariates as parameter overrides via `with()`, skipping any
   that were explicitly staged before `subjects()` (e.g., from a scan)
2. Stages dosing events via `events()`

Returns a `PopulationResult` with staged (not yet simulated) contexts.
Pipe into `simulate()` to run, then `to_dataframe()` to extract results.

# Example
```julia
pr = SimContext(prob) |> subjects(pop) |> simulate() |> to_dataframe(; obsonly=true)

# Scan overrides take precedence over per-subject dataset values
scan(ctx, :baseline_level => [2.0, 4.0]) do c, p
    c |> with(p) |> subjects(pop) |> simulate()
end
```
"""
function subjects(ctx::SimContext, pop::Population; parallel::Bool=true)
    n = length(pop)
    ids = [s.id for s in pop]
    results = Vector{SimContext}(undef, n)
    # Params explicitly staged before subjects() take precedence over per-subject covariates
    pre_staged = ctx.params

    _simulate_subject = function(i)
        s = pop[i]
        c = ctx
        # Apply covariates as parameter overrides, but don't overwrite pre-staged params
        if !isempty(keys(s.covariates))
            covs = [(k, v) for (k, v) in pairs(s.covariates) if !haskey(pre_staged, Symbol(k))]
            if !isempty(covs)
                c = with(c, covs)
            end
        end
        # Stage dosing events
        if !isempty(s.events)
            c = events(c, s.events)
        end
        return c
    end

    if parallel && n > 1 && Threads.nthreads() > 1
        Threads.@threads for i in 1:n
            results[i] = _simulate_subject(i)
        end
    else
        for i in 1:n
            results[i] = _simulate_subject(i)
        end
    end

    return PopulationResult(pop, Dict{Any, SimContext}(ids[i] => results[i] for i in 1:n), Dict{Any, Exception}())
end

"""
    subjects(pop::Population; parallel::Bool=true)

Curried form — returns a PipelineStep for use with `|>`.

# Example
```julia
results = sim_ctx |> subjects(pop) |> simulate() |> to_dataframe
```
"""
subjects(pop::Population; parallel::Bool=true) = PipelineStep(:subjects, ctx -> subjects(ctx, pop; parallel))
