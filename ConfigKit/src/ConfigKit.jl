"""
    ConfigKit

*"Config it"* - A Julia package for YAML-based parameter management and
data loading for MTK (ModelingToolkitBase) models.
"""
module ConfigKit

# Standard library
using Logging
import Base: getproperty, propertynames, show, getindex, keys, values, length, iterate, haskey

# External dependencies
using YAML
using OrderedCollections
using Unitful
import DynamicQuantities as DQ
using DynamicQuantities: @us_str  # Re-exported for model unit annotations (symbolic, no magnitude)
using MacroTools
using Setfield: @set!

# SciML ecosystem
using ModelingToolkitBase
using SciMLBase
using SciMLStructures
using SymbolicIndexingInterface: parameter_values, state_values, setp, setu, is_parameter, is_variable, parameter_index, variable_index
import SymbolicIndexingInterface   # used qualified as SymbolicIndexingInterface.remake_buffer in update.jl
using SymbolicUtils
using Symbolics

const MTK = ModelingToolkitBase

# Cache populated (pre-compiled) systems by name for downstream use (BayesKit).
# mtkcompile strips symbolic identity, making compiled systems unreliable for
# system extension + recompilation. This cache lets consumers retrieve the
# pre-compiled system transparently.
const POPULATED_SYSTEMS = Dict{Symbol, Any}()
const POPULATED_SYSTEMS_LOCK = ReentrantLock()

function cache_populated_system!(sys)
    lock(POPULATED_SYSTEMS_LOCK) do
        POPULATED_SYSTEMS[nameof(sys)] = sys
    end
    return sys
end

function get_populated_system(name::Symbol, default)
    return lock(POPULATED_SYSTEMS_LOCK) do
        get(POPULATED_SYSTEMS, name, default)
    end
end

# ============================================================
# Include source files
# ============================================================

include("keyfile/structs.jl")
include("keyfile/utils.jl")
include("keyfile/variants.jl")
include("keyfile/parser.jl")
include("keyfile/value.jl")
include("keyfile/populate.jl")

include("parameter_set.jl")
include("update.jl")
include("macros.jl")
include("optics.jl")

# ============================================================
# Public API Exports
# ============================================================

# Loading
export load_keyfile

# Accessors
export value, get_values, get_bounds, get_all_values, ParameterSet

# Variants
export get_variant_diff, list_available_variants

# Updates
export update, update!, with_update_cache, thread_update_cache,
       with_thread_update_cache, UpdateCache, BindingUpdateError,
       PreparedUpdateSource, prepared_update_source

# Population
export populate, populate!

# Re-export MTK alias for convenience
export MTK

# Macros
export @observed, @common_constants

# Optics (Accessors.jl)
export MTKParamLens, @param, bounds_from

# Re-export DynamicQuantities' @us_str for model unit annotations.
# Use us"s", us"mol/L", us"nmol/L" on @parameters and @variables.
# These are symbolic units (dimension-only, no magnitude) so MTK validation works correctly.
# Keyfile units still use Unitful strings ("nM", "L/s", etc.) and are converted automatically.
export @us_str

# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# TEMPORARY PIRATE PATCH — REMOVE WHEN FIXED UPSTREAM
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
# Bug: ModelingToolkitBase's MTKDynamicQuantitiesExt.safe_get_unit
#      accesses err.x / err.y on DynamicQuantities.DimensionError,
#      but those fields have ALWAYS been .q1 / .q2. The code was
#      never correct — it just never fired because the error path
#      only triggers on actual unit mismatches.
#
# We pirate-patch the method at runtime (__init__) so that unit
# validation actually works instead of crashing. The patch is
# skipped during precompilation (Core.eval is forbidden there).
#
# Upstream: https://github.com/SciML/ModelingToolkit.jl
#           lib/ModelingToolkitBase/ext/MTKDynamicQuantitiesExt.jl:221
# Status:   Broken in every MTKBase release as of v1.26.0 (2026-03-31)
#
# To check if this is still needed:
#   grep -n "err\.x" ~/.julia/packages/ModelingToolkitBase/*/ext/MTKDynamicQuantitiesExt.jl
# If that returns nothing, DELETE THIS ENTIRE BLOCK and the __init__.
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
function _patch_mtk_dimension_error()
    ext = Base.get_extension(MTK, :MTKDynamicQuantitiesExt)
    ext === nothing && return
    isdefined(ext, :safe_get_unit) || return
    hasfield(DQ.DimensionError, :q1) || return

    # Delete the broken method first to avoid "Method definition overwritten" warning
    for m in methods(ext.safe_get_unit)
        Base.delete_method(m)
    end

    Core.eval(ext, quote
        function safe_get_unit(term, info)
            side = nothing
            try
                side = get_unit(term)
            catch err
                if err isa DynamicQuantities.DimensionError
                    @warn("$info: $(err.q1) and $(err.q2) are not dimensionally compatible.")
                elseif err isa ValidationError
                    @warn(info * err.message)
                elseif err isa MethodError
                    @warn("$info: no method matching $(err.f) for arguments $(typeof.(err.args)).")
                else
                    rethrow()
                end
            end
            return side
        end
    end)
end

function __init__()
    # Core.eval into extension modules is forbidden during precompilation
    ccall(:jl_generating_output, Cint, ()) != 0 && return
    _patch_mtk_dimension_error()
end

using PrecompileTools

@compile_workload begin
    # Intentionally empty: ConfigKit.update is MTK-only, and constructing a
    # representative MTK ODEProblem here would pull in heavier extensions during
    # package precompilation.
end

end # module
