# ============================================================
# Pipeline API for composable fitting
# ============================================================

"""
    setup(targets...; simulate, predict, params, keyfile, bounds, x0, loss, verbose, ...) -> FitState

Prepare a fitting problem without running any optimization.
Returns a FitState ready for piping through `fit(solver)` stages.

# Example
```julia
state = setup(targets;
    simulate = sim_fn,
    predict  = pred_fn,
    params   = [:CL, :V],
    keyfile  = kf,
)
state = state |> fit(NelderMead(); maxiters=300) |> finish
```
"""
function setup(
    targets_in::TargetSet...;
    simulate::Function,
    predict=nothing,
    params,
    bounds::Union{NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}}, Nothing} = nothing,
    keyfile = nothing,
    x0::Union{Vector{Float64}, Nothing} = nothing,
    loss::Union{Symbol, Function, Nothing} = nothing,
    failure_penalty::Float64 = 1e10,
    on_eval::Union{Function, Nothing} = nothing,
    bounds_penalty::Union{Float64, Nothing} = nothing,
    verbose::Bool = true,
)
    # Auto-extract from keyfile
    if keyfile !== nothing && params isa Vector{Symbol}
        isnothing(bounds) && (bounds = ConfigKit.get_bounds(keyfile, params))
        isnothing(x0) && (x0 = ConfigKit.get_values(keyfile, params))
    end

    param_names, param_bounds = _resolve_params(params, bounds)
    obj = objective(targets_in...; simulate=simulate, predict=predict, params=param_names,
                    bounds=param_bounds, loss=loss, failure_penalty=failure_penalty,
                    on_eval=on_eval, bounds_penalty=bounds_penalty)
    reset!(obj)

    lb = obj.log_bounds.lb
    ub = obj.log_bounds.ub

    x_initial = if isnothing(x0)
        0.5 .* (lb .+ ub)
    else
        log.(x0)
    end

    initial_loss = obj(x_initial)

    if verbose
        np = length(obj.param_names)
        n_targets = sum(nrow(df) for (df, _) in obj.target_pairs; init=0)
        println("TargKit.setup: $np params, $n_targets targets, initial loss = $(round(initial_loss; digits=6))")
    end

    FitState(obj, x_initial, initial_loss, false, StageResult[], verbose)
end

# ============================================================
# fit(solver) — curried pipeline step
# ============================================================

"""
    fit(solver; maxiters, restarts=1) -> FitStep

Create a pipeline step that runs one optimization stage.

# Example
```julia
state |> fit(ParticleSwarm(n_particles=50); maxiters=1000, restarts=3) |>
         fit(NelderMead(); maxiters=300)
```
"""
function fit(solver; maxiters::Int, restarts::Int=1)
    stage = Stage(solver; maxiters=maxiters, restarts=restarts)
    solver_name = Symbol(nameof(typeof(solver)))
    FitStep(solver_name, state -> _run_pipeline_stage(state, stage))
end

"""
    fit(stage::Stage) -> FitStep

Create a pipeline step from an existing Stage.
"""
function fit(stage::Stage)
    solver_name = Symbol(nameof(typeof(stage.solver)))
    FitStep(solver_name, state -> _run_pipeline_stage(state, stage))
end

function _run_pipeline_stage(state::FitState, stage::Stage)
    obj = state.obj
    lb = obj.log_bounds.lb
    ub = obj.log_bounds.ub
    loss_before = state.loss

    t_start = time()
    best_x, best_loss, converged = _run_stage(obj, stage, state.x, lb, ub,
                                               state.verbose, length(state.history) + 1,
                                               length(state.history) + 1)
    elapsed = time() - t_start

    solver_name = Symbol(nameof(typeof(stage.solver)))
    sr = StageResult(solver_name, loss_before, best_loss, converged, elapsed)

    FitState(obj, best_x, best_loss, converged, vcat(state.history, [sr]), state.verbose)
end

# ============================================================
# finish() — convert FitState to FitResult
# ============================================================

"""
    finish(state::FitState) -> FitResult

Finalize a fitting pipeline and return the standard FitResult.

# Example
```julia
result = setup(...) |> fit(NelderMead(); maxiters=300) |> finish
```
"""
function finish(state::FitState)
    obj = state.obj
    real_values = exp.(state.x)
    params = Dict{Symbol, Float64}(obj.param_names[i] => real_values[i] for i in eachindex(obj.param_names))
    report = _build_fit_report(obj, state.x)

    method_name = if isempty(state.history)
        :none
    elseif length(state.history) == 1
        state.history[1].name
    else
        Symbol(join([string(sr.name) for sr in state.history], "_"))
    end

    if state.verbose
        println("TargKit.finish: loss=$(round(state.loss; digits=6)), converged=$(state.converged)")
        if !isnothing(report)
            println("  Targets met: $(report.n_met)/$(report.n_total)")
        end
        lb = obj.log_bounds.lb
        ub = obj.log_bounds.ub
        n_at_bounds = _count_at_bounds(state.x, lb, ub)
        n_at_bounds > 0 && println("  WARNING: $n_at_bounds params at bounds")
    end

    source_fp = try
        _SourceFP.combined_fingerprint(state.obj.simulate)
    catch e
        @warn "TargKit: source fingerprinting failed; FitResult.source_fp=nothing" exception=e
        nothing
    end
    FitResult(params, state.loss, report, state.converged, method_name, source_fp)
end

# Curried form for piping
finish() = FitStep(:finish, state -> finish(state))

# ============================================================
# Diagnostic pipeline steps
# ============================================================

"""
    inspect_fit() -> FitStep

Print current FitState without modifying it. Insert between stages for diagnostics.
"""
function inspect_fit()
    FitStep(:inspect, function(state)
        show(stdout, MIME("text/plain"), state)
        return state
    end)
end

"""
    score_fit() -> FitStep

Run a full scoring report at the current parameters and print it.
"""
function score_fit()
    FitStep(:score, function(state)
        report = _build_fit_report(state.obj, state.x)
        if !isnothing(report)
            show(stdout, MIME("text/plain"), report)
        end
        return state
    end)
end

"""
    checkpoint(callback::Function) -> FitStep

Call `callback(state)` for side effects, return state unchanged.

# Example
```julia
state |> fit(PSO; maxiters=500) |>
         checkpoint(s -> @info "After PSO" s.loss) |>
         fit(NelderMead(); maxiters=300)
```
"""
function checkpoint(callback::Function)
    FitStep(:checkpoint, function(state)
        callback(state)
        return state
    end)
end

# ============================================================
# Named presets
# ============================================================

const PSO_NM = fit(ParticleSwarm(n_particles=20); maxiters=75, restarts=3) |>
               fit(NelderMead(); maxiters=300)

const NM_ONLY = fit(NelderMead(); maxiters=300)

const LBFGS_ONLY = fit(LBFGS(); maxiters=200)
