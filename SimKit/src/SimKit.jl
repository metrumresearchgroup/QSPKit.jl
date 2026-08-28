"""
    SimKit

*"Simulate it"* — Composable simulation pipelines for multi-phase ODE models.

Provides a pipeline API (`SimContext(prob) |> with |> events |> simulate`) that chains
ConfigKit parameter updates, InjecKit dosing events, and SciML/OrdinaryDiffEq
solves into reproducible, cacheable simulation workflows.
"""
module SimKit

import SciMLBase
import OrdinaryDiffEq
import ConfigKit
import InjecKit
using LRUCache

# Core types
include("types.jl")

# Transparent phase cache
include("cache.jl")

# Constructor
include("init.jl")

# Pipeline operations
include("pipeline.jl")

# Branching and result extraction
include("branch.jl")

# Subject/Population types and multi-subject simulation
include("subjects.jl")

# Parameter sweeps
include("scan.jl")

# Time unit helpers
include("time_helpers.jl")

# Display and inspection
include("display.jl")

# DataFrame conversion
include("dataframe.jl")

# ============================================================
# Exports
# ============================================================

# Types
export SimContext, Phase, Pipeline, PipelineStep, SimulationError, SimRunner, LazyBranch, Subject, Population, PopulationResult

# Pipeline operations
export with, events, keep, simulate, simulate_solution

# Branching, results, and multi-subject
export branch, branch_lazy, result, phases, scan, subjects

# Pipeline composition and inspection
export inspect

# Time helpers
export weeks, days, hours

# DataFrame conversion
export to_dataframe

# Cache control
export disable_cache!, enable_cache!

using PrecompileTools
import DataFrames

@compile_workload begin
    # Exercise Population construction from DataFrame (2.5s first-call JIT)
    _pc_df = DataFrames.DataFrame(
        ID=[1, 1], TIME=[0.0, 1.0], DV=[missing, 5.0],
        AMT=[100.0, 0.0], EVID=[1, 0], CMT=[:Depot, :x])
    Population(_pc_df; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT)
end

end # module
