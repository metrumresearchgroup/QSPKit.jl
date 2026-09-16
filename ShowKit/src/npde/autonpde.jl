# ============================================================
# npde — Normalised prediction distribution errors
# ============================================================

"""
    autonpde(obs::DataFrame, sim::DataFrame; id=:id, x=:time, y=:dv,
             decorr_method="cholesky", ties=true) -> DataFrame

Thin wrapper around `npde::autonpde()`. `obs` should have one row per
observation; `sim` should have repeated simulated observations with the same
ID and independent-variable columns.
"""
function autonpde(obs::DataFrame, sim::DataFrame;
                  id::Symbol=:id,
                  x::Symbol=:time,
                  y::Symbol=:dv,
                  decorr_method::AbstractString="cholesky",
                  ties::Bool=true)
    _require_npde()

    obs_in = DataFrame(id=obs[!, id], x=obs[!, x], y=obs[!, y])
    sim_in = DataFrame(id=sim[!, id], x=sim[!, x], y=sim[!, y])

    r_kwargs = Pair{Symbol, Any}[
        :boolsave => false,
        :verbose => false,
        Symbol("calc.npde") => true,
        Symbol("calc.npd") => true,
        Symbol("decorr.method") => string(decorr_method),
        :ties => ties,
    ]

    fit = try
        _rcall(
            _reval("npde::autonpde"),
            _robject(obs_in),
            _robject(sim_in),
            1,
            2,
            3;
            r_kwargs...,
        )
    catch err
        @warn "ShowKit: npde::autonpde failed; using empirical normal-score fallback" exception=err
        return _empirical_npde(obs_in, sim_in)
    end

    out = _rcopy(DataFrame, _rcall(_reval("function(x) as.data.frame(x['results']['res'])"), fit))
    lower_names = Dict(lowercase(string(name)) => Symbol(name) for name in names(out))

    id_col = get(lower_names, "id", Symbol(names(out)[1]))
    x_col = get(lower_names, "xobs", get(lower_names, "x", Symbol(names(out)[2])))
    ypred_col = get(lower_names, "ypred", nothing)
    pd_col = get(lower_names, "pd", nothing)
    npde_col = get(lower_names, "npde", nothing)
    npde_col === nothing && error("npde::autonpde result did not contain an npde column")

    result = DataFrame(id=out[!, id_col], x=out[!, x_col], NPDE=out[!, npde_col])
    ypred_col === nothing || (result.YPRED = out[!, ypred_col])
    pd_col === nothing || (result.PD = out[!, pd_col])
    result
end

function _normal_quantile(p::Float64)
    p = clamp(p, eps(Float64), 1.0 - eps(Float64))
    _rcopy(Float64, _rcall(_reval("qnorm"), p))
end

function _empirical_npde(obs::DataFrame, sim::DataFrame)
    n_obs = nrow(obs)
    n_obs == 0 && return DataFrame(id=Any[], x=Float64[], NPDE=Float64[], PD=Float64[])
    nrow(sim) % n_obs == 0 ||
        error("empirical NPDE fallback requires simulated rows $(nrow(sim)) " *
              "to be a multiple of observed rows $n_obs")

    n_rep = div(nrow(sim), n_obs)
    npde = Vector{Union{Missing, Float64}}(undef, n_obs)
    pd = Vector{Union{Missing, Float64}}(undef, n_obs)
    for i in 1:n_obs
        y_obs = obs.y[i]
        if ismissing(y_obs)
            npde[i] = missing
            pd[i] = missing
            continue
        end

        sims = skipmissing(sim.y[i + (rep - 1) * n_obs] for rep in 1:n_rep)
        values = collect(Float64, sims)
        if isempty(values)
            npde[i] = missing
            pd[i] = missing
            continue
        end

        n_less = count(<(Float64(y_obs)), values)
        n_equal = count(==(Float64(y_obs)), values)
        p = (n_less + 0.5 * n_equal + 0.5) / (length(values) + 1.0)
        pd[i] = p
        npde[i] = _normal_quantile(p)
    end

    DataFrame(id=obs.id, x=obs.x, NPDE=npde, PD=pd)
end

function _first_nonmissing(values)
    for value in values
        ismissing(value) || return value
    end
    return missing
end

function _npde_draw_cols(df::DataFrame)
    :DRAW in propertynames(df) && return [:DRAW]
    [col for col in (:CHAIN, :ITER) if col in propertynames(df)]
end

function _npde_sort_cols(draw_cols::Vector{Symbol}, design_cols::Vector{Symbol})
    isempty(draw_cols) ? design_cols : vcat(draw_cols, design_cols)
end

"""
    add_npde!(residuals::DataFrame, ppc::DataFrame; by=:ENDPOINT) -> DataFrame

Add an `NPDE` column to `posterior_residuals(ppc)` output using
`npde::autonpde()` and the posterior predictive `DVREP` draws.
"""
function add_npde!(residuals::DataFrame, ppc::DataFrame;
                   by::Union{Symbol,Vector{Symbol}}=:ENDPOINT,
                   id::Symbol=:ID,
                   time::Symbol=:TIME,
                   dv::Symbol=:DV,
                   dvrep::Symbol=:DVREP,
                   obs_index::Union{Nothing,Symbol}=nothing)
    by_cols = by isa Symbol ? [by] : by
    if obs_index === nothing && :OBS_INDEX in propertynames(ppc) &&
            :OBS_INDEX in propertynames(residuals)
        obs_index = :OBS_INDEX
    end
    if obs_index !== nothing
        obs_index in propertynames(ppc) ||
            error("obs_index column $obs_index is not present in ppc")
        obs_index in propertynames(residuals) ||
            error("obs_index column $obs_index is not present in residuals")
    end

    residuals.NPDE = Vector{Union{Missing, Float64}}(missing, nrow(residuals))

    design_cols = obs_index === nothing ? [id, time] : [id, time, obs_index]
    key_cols = vcat(design_cols, by_cols)
    residual_row = Dict(
        Tuple(row[col] for col in key_cols) => i
        for (i, row) in enumerate(eachrow(residuals))
    )

    draw_cols = _npde_draw_cols(ppc)
    for sub in groupby(ppc, by_cols)
        obs_source = DataFrame(sub)
        sim_source = obs_source
        if obs_index === nothing
            obs = combine(groupby(obs_source, [id, time]), dv => _first_nonmissing => :dv)
            rename!(obs, id => :id, time => :time)
            obs._NPDE_OBS_ORDER = 1:nrow(obs)

            sim_group_cols = isempty(draw_cols) ? [id, time] : vcat(draw_cols, [id, time])
            sim_source = combine(groupby(sim_source, sim_group_cols),
                dvrep => _first_nonmissing => :dv)
            sim_source = leftjoin(sim_source, select(obs, :id, :time, :_NPDE_OBS_ORDER);
                on=[id => :id, time => :time])
            sort!(sim_source, _npde_sort_cols(draw_cols, [:_NPDE_OBS_ORDER]))
            sim = select(sim_source, id => :id, time => :time, :dv)
        else
            sort!(obs_source, _npde_sort_cols(draw_cols, [obs_index]))
            ref = if isempty(draw_cols)
                obs_source
            else
                first_draw = Tuple(obs_source[1, col] for col in draw_cols)
                filter(row -> Tuple(row[col] for col in draw_cols) == first_draw, obs_source)
            end

            obs = select(ref, id => :id, time => :time, dv => :dv, obs_index => :obs_index)
            sim = select(obs_source, id => :id, time => :time, dvrep => :dv)
        end

        n_obs = nrow(obs)
        n_obs == 0 && continue
        nrow(sim) % n_obs == 0 ||
            error("npde simulation rows $(nrow(sim)) are not a multiple of observed rows $n_obs")
        npde = autonpde(obs, sim; id=:id, x=:time, y=:dv)
        nrow(npde) == n_obs ||
            error("npde returned $(nrow(npde)) rows for $n_obs observations")
        by_values = [first(sub[!, col]) for col in by_cols]

        for (i, row) in enumerate(eachrow(obs))
            base_values = obs_index === nothing ?
                Any[row.id, row.time] :
                Any[row.id, row.time, row.obs_index]
            key = Tuple(vcat(base_values, by_values))
            residuals[residual_row[key], :NPDE] = npde.NPDE[i]
        end
    end
    return residuals
end

export autonpde, add_npde!
