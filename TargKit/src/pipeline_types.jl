# ============================================================
# Pipeline types for composable fitting
# ============================================================

"""
    StageResult

Record of one completed optimization stage.
"""
struct StageResult
    name::Symbol
    loss_before::Float64
    loss_after::Float64
    converged::Bool
    elapsed::Float64
end

"""
    FitState

Immutable state container that flows through a TargKit fitting pipeline.
Carries the objective, current best parameters, and optimization history.

# Example
```julia
state = setup(targets; simulate=sim_fn, params=[:CL, :V], keyfile=kf)
state = state |> fit(NelderMead(); maxiters=300)
result = finish(state)
```
"""
struct FitState
    obj::ObjectiveFunction
    x::Vector{Float64}            # current best parameters (log-space)
    loss::Float64                  # current best loss
    converged::Bool
    history::Vector{StageResult}
    verbose::Bool
end

"""
    FitPipeline

Composed sequence of FitSteps. Callable on a FitState.
"""
struct FitPipeline
    stages::Vector{NamedTuple{(:name, :fn), Tuple{Symbol, Function}}}
end

function (p::FitPipeline)(state::FitState)
    foldl((s, step) -> step.fn(s), p.stages; init=state)
end

"""
    FitStep

A single curried fitting pipeline step. Supports `|>` for composition.
"""
struct FitStep
    name::Symbol
    fn::Function
end

(s::FitStep)(state::FitState) = s.fn(state)

# |> composition
Base.:(|>)(a::FitStep, b::FitStep) = FitPipeline([(name=a.name, fn=a.fn), (name=b.name, fn=b.fn)])
Base.:(|>)(p::FitPipeline, s::FitStep) = FitPipeline(vcat(p.stages, [(name=s.name, fn=s.fn)]))
Base.:(|>)(s::FitStep, p::FitPipeline) = FitPipeline(vcat([(name=s.name, fn=s.fn)], p.stages))
Base.:(|>)(p1::FitPipeline, p2::FitPipeline) = FitPipeline(vcat(p1.stages, p2.stages))

# |> execution
Base.:(|>)(state::FitState, s::FitStep) = s(state)
Base.:(|>)(state::FitState, p::FitPipeline) = p(state)

# Display
function Base.show(io::IO, state::FitState)
    np = length(state.obj.param_names)
    ns = length(state.history)
    print(io, "FitState(loss=$(round(state.loss; digits=6)), $np params, $ns stages)")
end

function Base.show(io::IO, ::MIME"text/plain", state::FitState)
    show(io, state)
    println(io)
    if !isempty(state.history)
        println(io, "  Stages:")
        for (i, sr) in enumerate(state.history)
            improvement = round(sr.loss_before - sr.loss_after; digits=6)
            println(io, "    $i. :$(sr.name): $(round(sr.loss_before; digits=6)) → $(round(sr.loss_after; digits=6)) (Δ=$improvement, $(round(sr.elapsed; digits=1))s)")
        end
    end
    real_values = exp.(state.x)
    println(io, "  Parameters:")
    for (i, name) in enumerate(state.obj.param_names)
        println(io, "    $name = $(round(real_values[i]; sigdigits=4))")
    end
end

function Base.show(io::IO, p::FitPipeline)
    print(io, "FitPipeline($(length(p.stages)) stages: $(join([s.name for s in p.stages], " → ")))")
end
