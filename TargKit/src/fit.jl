# ============================================================
# fit() — optimization with pluggable Stage pipeline
# ============================================================

using Optimization
using OptimizationOptimJL

# ============================================================
# Named strategy presets
# ============================================================

function _resolve_strategy(s::Symbol)
    s == :pso_nm && return [
        Stage(ParticleSwarm(n_particles=20); maxiters=75, restarts=3),
        Stage(NelderMead(); maxiters=300),
    ]
    s == :nm && return [Stage(NelderMead(); maxiters=300)]
    s == :lbfgs && return [Stage(LBFGS(); maxiters=200)]
    error("Unknown strategy preset :$s. Use :pso_nm, :nm, :lbfgs, or a Vector{Stage}.")
end
_resolve_strategy(stages::AbstractVector{Stage}) = stages
_resolve_strategy(stages::AbstractVector) = Stage[s for s in stages]  # coerce element type

# ============================================================
# fit() with Pair syntax: df => predict_fn
# ============================================================

"""
    fit(pairs...; simulate, params, bounds, strategy=:pso_nm, kwargs...) -> FitResult

Fit targets to a simulation model.

    result = fit(
        baseline => (ctx, row) -> ctx.sol[row.name][end];
        simulate = overrides -> ...,
        params = [:k6, :k13],
        bounds = get_bounds(keyfile, params),
        x0 = collect(get_values(keyfile, params)),
    )
"""
function fit(
    pairs::Pair{<:AbstractDataFrame, <:Function}...;
    simulate::Function,
    params::Vector{Symbol},
    bounds::NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}},
    strategy::Union{Symbol, AbstractVector} = :pso_nm,
    x0::Union{Vector{Float64}, Nothing} = nothing,
    loss::Union{Symbol, Function} = :log,
    failure_penalty::Float64 = 1e10,
    on_eval::Union{Function, Nothing} = nothing,
    bounds_penalty::Union{Float64, Nothing} = nothing,
    verbose::Bool = true,
)
    obj = objective(pairs...; simulate=simulate, params=params, bounds=bounds,
                    loss=loss, failure_penalty=failure_penalty, on_eval=on_eval,
                    bounds_penalty=bounds_penalty)
    return fit(obj; strategy=strategy, x0=x0, verbose=verbose)
end

# ============================================================
# fit() with pre-built ObjectiveFunction
# ============================================================

"""
    fit(obj::ObjectiveFunction; strategy=:pso_nm, x0=nothing, verbose=true) -> FitResult
"""
function fit(
    obj::ObjectiveFunction;
    strategy::Union{Symbol, AbstractVector} = :pso_nm,
    x0::Union{Vector{Float64}, Nothing} = nothing,
    verbose::Bool = true,
)
    stages = _resolve_strategy(strategy)
    method_name = strategy isa Symbol ? strategy : :custom

    reset!(obj)

    lb = obj.log_bounds.lb
    ub = obj.log_bounds.ub
    np = length(obj.param_names)
    n_targets = sum(nrow(df) for (df, _) in obj.target_pairs; init=0)

    # x0 in natural space → log space
    x_current = if isnothing(x0)
        0.5 .* (lb .+ ub)
    else
        log.(x0)
    end

    if verbose
        println("TargKit.fit: strategy=$(repr(strategy)), $np params, $n_targets targets")
    end

    best_x = copy(x_current)
    best_loss = Inf
    converged = false

    for (stage_idx, stage) in enumerate(stages)
        stage_x, stage_loss, stage_converged = _run_stage(obj, stage, x_current, lb, ub, verbose, stage_idx, length(stages))
        if stage_loss < best_loss
            best_loss = stage_loss
            best_x = copy(stage_x)
        end
        converged = stage_converged
        x_current = copy(best_x)
    end

    # Build result
    real_values = exp.(best_x)
    params = Dict{Symbol, Float64}(obj.param_names[i] => real_values[i] for i in eachindex(obj.param_names))
    report = _build_fit_report(obj, best_x)

    if verbose
        println("  Final loss: $(round(best_loss; digits=6)), converged: $converged")
        if !isnothing(report)
            println("  Targets met: $(report.n_met)/$(report.n_total)")
        end
        n_at_bounds = _count_at_bounds(best_x, lb, ub)
        n_at_bounds > 0 && println("  WARNING: $n_at_bounds params at bounds")
    end

    # Source fingerprinting must never destroy a completed fit; log and fall back.
    source_fp = try
        _SourceFP.combined_fingerprint(obj.simulate)
    catch e
        @warn "TargKit: source fingerprinting failed; FitResult.source_fp=nothing" exception=e
        nothing
    end
    return FitResult(params, best_loss, report, converged, method_name, source_fp)
end

# ============================================================
# _run_stage — execute one Stage (with restarts)
# ============================================================

function _run_stage(obj, stage::Stage, x_start, lb, ub, verbose, stage_idx, n_stages)
    requested_solver = stage.solver
    solver_name = nameof(typeof(requested_solver))
    solver, bound_mode = _bounded_solver(requested_solver)

    best_x = copy(x_start)
    best_loss = Inf
    best_success = false

    for r in 1:stage.restarts
        x_init = r == 1 ? copy(x_start) : lb .+ rand(length(lb)) .* (ub .- lb)
        x_init = clamp.(x_init, lb, ub)

        if bound_mode == :box
            x_init = _box_interior(x_init, lb, ub)
            f = OptimizationFunction((x, p) -> obj(x), Optimization.AutoFiniteDiff())
            prob = OptimizationProblem(f, x_init; lb=lb, ub=ub)
        elseif bound_mode == :native
            f = OptimizationFunction((x, p) -> obj(x))
            prob = OptimizationProblem(f, x_init; lb=lb, ub=ub)
        else
            error("Internal error: unsupported bound mode $(repr(bound_mode))")
        end

        sol = solve(prob, solver; maxiters=stage.maxiters)
        candidate_x = _project_numerical_bound_overshoot(sol.u, lb, ub, requested_solver)
        candidate_loss = candidate_x == sol.u ? sol.objective : obj(candidate_x)

        if verbose
            restart_str = stage.restarts > 1 ? " restart $r/$(stage.restarts)" : ""
            println("  Stage $stage_idx/$n_stages ($solver_name$restart_str): loss = $(round(candidate_loss; digits=6)), retcode = $(sol.retcode)")
        end

        if candidate_loss < best_loss
            best_loss = candidate_loss
            best_x = candidate_x
            best_success = _is_success(sol)   # did the BEST restart actually converge?
        end
    end

    # converged reflects the optimizer's retcode on the winning restart, not merely
    # "produced a finite loss" (which was always true).
    return best_x, best_loss, best_success
end

# ============================================================
# Solver bound handling
# ============================================================

_bounded_solver(solver::ParticleSwarm) = (solver, :native)
_bounded_solver(solver::NelderMead) = (Optim.Fminbox(solver), :box)
_bounded_solver(solver::LBFGS) = (Optim.Fminbox(solver), :box)
_bounded_solver(solver::Optim.Fminbox) = (solver, :box)

function _bounded_solver(solver)
    throw(ArgumentError(
        "TargKit cannot guarantee parameter bounds with solver $(typeof(solver)). " *
        "Use ParticleSwarm for native bounds, NelderMead or LBFGS for automatic " *
        "Fminbox wrapping, or pass an explicit Optim.Fminbox solver."
    ))
end

function _box_interior(x, lb, ub)
    return map(x, lb, ub) do value, lower, upper
        width = upper - lower
        width > 0 || throw(ArgumentError("parameter bounds must satisfy lower < upper"))
        offset = min(sqrt(eps(Float64)) * max(1.0, width), width / 4)
        clamp(value, lower + offset, upper - offset)
    end
end

function _project_numerical_bound_overshoot(x, lb, ub, solver)
    violations = Int[]
    for i in eachindex(x)
        scale = max(1.0, abs(lb[i]), abs(ub[i]))
        tolerance = sqrt(eps(Float64)) * scale
        if !isfinite(x[i]) || x[i] < lb[i] - tolerance || x[i] > ub[i] + tolerance
            push!(violations, i)
        end
    end
    if !isempty(violations)
        values = x[violations]
        throw(ErrorException(
            "$(typeof(solver)) returned parameters materially outside the declared bounds " *
            "at indices $violations (values=$values); refusing to return an invalid fit."
        ))
    end
    return clamp.(collect(x), lb, ub)
end

# ============================================================
# _build_fit_report — final ScoreReport from best x
# ============================================================

function _build_fit_report(obj::ObjectiveFunction, x)
    ctx = obj.simulate(_objective_overrides!(obj, x))
    isnothing(ctx) && return nothing

    return score(obj.target_pairs...; ctx=ctx, loss=obj.default_loss)
end

# ============================================================
# Internal helpers
# ============================================================

function _is_success(sol)
    sol.retcode == Optimization.ReturnCode.Success
end

function _count_at_bounds(x, lb, ub; tol=1e-6)
    count(i -> abs(x[i] - lb[i]) < tol || abs(x[i] - ub[i]) < tol, eachindex(x))
end

# ============================================================
# fit() with TargetSets
# ============================================================

"""
    fit(ts::TargetSet...; simulate, params, bounds=nothing, strategy=:pso_nm, kwargs...) -> FitResult

Fit one or more TargetSets to a simulation model.

`params` accepts two formats:
- **Symbol vector** (existing): `params=[:k6, :k13], bounds=(lb=[0.01, 0.01], ub=[10.0, 5.0])`
- **Optic pairs** (new): `params=[@param(k6) => bounds_from(kf, :k6), @param(k13) => (0.01, 5.0)]`

With optic pairs, bounds are co-located with parameter names — can't get out of sync.
"""
function fit(
    targets_in::TargetSet...;
    simulate::Function,
    predict=nothing,
    params,
    bounds::Union{NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}}, Nothing} = nothing,
    keyfile = nothing,
    strategy::Union{Symbol, AbstractVector, FitPipeline, FitStep} = :pso_nm,
    x0::Union{Vector{Float64}, Nothing} = nothing,
    loss::Union{Symbol, Function} = :log,
    failure_penalty::Float64 = 1e10,
    on_eval::Union{Function, Nothing} = nothing,
    bounds_penalty::Union{Float64, Nothing} = nothing,
    verbose::Bool = true,
)
    state = setup(targets_in...;
        simulate=simulate, predict=predict, params=params,
        bounds=bounds, keyfile=keyfile, x0=x0, loss=loss,
        failure_penalty=failure_penalty, on_eval=on_eval,
        bounds_penalty=bounds_penalty, verbose=verbose)

    pipeline = _strategy_to_pipeline(strategy)
    state = state |> pipeline
    return finish(state)
end

function _strategy_to_pipeline(s::Symbol)
    s == :pso_nm && return PSO_NM
    s == :nm     && return NM_ONLY
    s == :lbfgs  && return LBFGS_ONLY
    error("Unknown strategy preset :$s. Use :pso_nm, :nm, :lbfgs, or a FitPipeline.")
end
_strategy_to_pipeline(p::FitPipeline) = p
_strategy_to_pipeline(s::FitStep) = FitPipeline([(name=s.name, fn=s.fn)])
_strategy_to_pipeline(stages::AbstractVector) = reduce(|>, [fit(s) for s in stages])

"""
    _resolve_params(params, bounds) -> (names::Vector{Symbol}, bounds::NamedTuple)

Handle both param formats:
- `params::Vector{Symbol}` + `bounds::NamedTuple` (existing)
- `params::Vector{Pair}` (optic specs, bounds=nothing) — lens => bounds_tuple pairs
"""
function _resolve_params(params::Vector{Symbol}, bounds)
    isnothing(bounds) && error("bounds must be provided when params is a Vector{Symbol}")
    return params, bounds
end

function _resolve_params(params::Vector{<:Pair}, bounds)
    !isnothing(bounds) && @warn "bounds kwarg is ignored when params are optic pairs (bounds are in the pairs)"
    names = Symbol[]
    lb = Float64[]
    ub = Float64[]
    for (lens, bnds) in params
        key = if hasproperty(lens, :key)
            Symbol(lens.key)
        else
            error("Parameter spec must be a lens with a .key field, got $(typeof(lens))")
        end
        push!(names, key)
        push!(lb, Float64(bnds[1]))
        push!(ub, Float64(bnds[2]))
    end
    return names, (lb=lb, ub=ub)
end
