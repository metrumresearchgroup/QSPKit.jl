module InjecKit

import ConfigKit
using DataFrames
import DiffEqCallbacks
using LRUCache
using ModelingToolkitBase
const MTK = ModelingToolkitBase
using SymbolicIndexingInterface
using SymbolicUtils
using Symbolics
using QSPKitCore
import OrdinaryDiffEq
import OrdinaryDiffEq: ODEProblem
import SciMLBase
import SciMLLogging

# Thread-safe caches for fast repeated solves
const CACHE_LOCK = ReentrantLock()

# Cache 1: Extended systems used only for dynamic parameter promotion.
const EXTENDED_SYSTEM_CACHE = LRU{UInt, Any}(maxsize=100)

# Cache 2: pre-resolved event plans. Plans carry validation metadata; the UInt
# cache key is only an LRU lookup hint. A plan can either apply events as
# callbacks/RHS forcing on the existing problem or remake a cached structural
# problem whose ordinary parameters were promoted to dynamic quantities.
const EVENT_PLAN_CACHE = LRU{UInt, Any}(maxsize=256)

# Cache 3: event runners used by direct solve(prob, events, alg). The runner
# cache is keyed by problem shape rather than problem object so ConfigKit.remake
# loops still hit it; solves still pass the current problem into the runner.
const EVENT_RUNNER_CACHE = LRU{UInt, Any}(maxsize=256)

# Cache 4: prepared ConfigKit-update + event solves recovered from the common
# `updated = ConfigKit.update(...); solve(updated, events, alg)` script pattern.
const PREPARED_UPDATE_EVENT_SOLVE_CACHE = LRU{UInt, Any}(maxsize=512)

"""Ensure the EVENT_PLAN_CACHE can hold at least `n` entries without eviction."""
function ensure_cache_capacity!(n::Int)
    lock(CACHE_LOCK) do
        current_max = EVENT_PLAN_CACHE.maxsize
        if n > current_max
            resize!(EVENT_PLAN_CACHE; maxsize=n + 10)  # small buffer
        end
    end
end


# Core functionality organized by purpose
include("variable_resolution.jl")    # Variable/parameter resolution and lookup
include("event_types.jl")            # IEvent struct and constructors
include("infusion_handling.jl")      # Infusion parameter calculation
include("system_extensions.jl")      # System creation and extension utilities
include("event_processing.jl")       # Event analysis and callback creation
include("constructor_core.jl")       # Core optimized constructor logic
include("event_runner.jl")           # Shared prepared event executor
include("ode_constructors_new.jl")   # ODEProblem constructor interfaces
include("CustomSolve.jl")            # Custom solve methods
include("event_composition.jl")      # seq, combine for event composition
include("regimen_templates.jl")      # QD, BID, Q4W, loading_then templates

export ODEProblem, ev, setevent, IEvent, MTK
export expand_repeated_events, get_infusion_parameters
export seq, combine, QD, BID, Q4W, loading_then
export EventRunner, PreparedEventSolve, solve_event_runner,
    with_prepared_event_problem, with_prepared_event_solve,
    with_prepared_active_tunable_sensitivity_problem, tunable_parameter_index

using PrecompileTools

@compile_workload begin
    # Exercise IEvent construction and event processing
    _pc_ev = IEvent(0.0, :Depot, 100.0, nothing, nothing, 1,
                    nothing, nothing, nothing,
                    Dict{Union{Symbol, MTK.Num}, Float64}())
    # The ODEProblem(sys, ..., events) path requires an MTK system
    # which is too expensive to create during precompilation.
    # The 25s JIT is in the MTK callback compilation, not InjecKit itself.
end

end # module
