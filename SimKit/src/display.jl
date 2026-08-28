# ============================================================
# Display and inspection methods
# ============================================================

# Note: Base.show methods for SimContext, Pipeline, Phase, and SimulationError
# are defined in pipeline.jl alongside the operations.

# ----------------------------------------------------------
# inspect — detailed inspection
# ----------------------------------------------------------

"""
    inspect(ctx::SimContext)

Print a full inspection of a SimContext, including all phases,
staged parameters, events, and solver configuration.
"""
function inspect(ctx::SimContext)
    println("SimContext")
    println("  Problem: $(typeof(ctx.prob))")
    println("  Solution: $(ctx.sol === nothing ? "none" : typeof(ctx.sol))")

    if !isempty(ctx.phases)
        println("  Phases ($(length(ctx.phases))):")
        for (i, p) in enumerate(ctx.phases)
            println("    $i. :$(p.name)  ($(p.duration) days)")
        end
    else
        println("  Phases: none")
    end

    if !isempty(ctx.params)
        println("  Staged params ($(length(ctx.params))):")
        for (k, v) in sort(collect(pairs(ctx.params)); by=first)
            println("    :$k => $v")
        end
    else
        println("  Staged params: none")
    end

    if !isempty(ctx.events)
        println("  Staged events: $(length(ctx.events))")
    else
        println("  Staged events: none")
    end

    if ctx.persist
        println("  Persist: true (keep() active)")
    end

    if ctx.solver !== nothing
        println("  Solver: $(ctx.solver)")
    end
    if !isempty(pairs(ctx.solve_kwargs))
        println("  Solver kwargs: $(ctx.solve_kwargs)")
    end
end

# ----------------------------------------------------------
# PopulationResult display
# ----------------------------------------------------------

function Base.show(io::IO, pr::PopulationResult)
    n_subj = length(pr.population)
    n_sim = length(pr.contexts)
    n_err = length(pr.errors)
    simulated = any(!isempty(ctx.phases) for ctx in values(pr.contexts))
    status = simulated ? "simulated" : "staged"
    err_str = n_err > 0 ? ", $n_err failed" : ""
    print(io, "PopulationResult($n_subj subjects, $n_sim $status$err_str)")
end

function Base.show(io::IO, ::MIME"text/plain", pr::PopulationResult)
    n_subj = length(pr.population)
    n_sim = length(pr.contexts)
    n_err = length(pr.errors)
    simulated = any(!isempty(ctx.phases) for ctx in values(pr.contexts))
    status = simulated ? "simulated" : "staged"
    println(io, "PopulationResult: $n_subj subjects ($n_sim $status, $n_err failed)")
    if n_err > 0
        println(io, "  Failed IDs: $(collect(keys(pr.errors)))")
    end
end
