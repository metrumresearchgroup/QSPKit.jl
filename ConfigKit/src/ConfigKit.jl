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

# Cache populated (pre-compiled) systems by name for downstream workflows.
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
# Status:   Still broken in ModelingToolkitBase v1.67.0 (2026-08-27).
#
# The runtime fingerprint below only matches the known generic method while it
# still reads both err.x and err.y. It therefore leaves unrelated overloads
# alone and automatically skips the patch after upstream switches to q1/q2 or
# otherwise changes that implementation.
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
function _getproperty_fields(method::Method)
    code = try
        Base.uncompressed_ast(method).code
    catch err
        @debug "ConfigKit: Could not inspect ModelingToolkitBase.safe_get_unit; skipping the DimensionError workaround." exception = (err, catch_backtrace())
        return nothing
    end

    fields = Set{Symbol}()
    for statement in code
        statement isa Expr || continue
        statement.head === :call || continue
        length(statement.args) == 3 || continue

        callee = statement.args[1]
        callee isa GlobalRef || continue
        callee.mod === Base || continue
        callee.name === :getproperty || continue

        field = statement.args[3]
        field isa QuoteNode || continue
        field.value isa Symbol || continue
        push!(fields, field.value)
    end
    return fields
end

function _is_broken_mtk_safe_get_unit(ext::Module, method::Method)
    method.module === ext || return false
    method.sig == Tuple{typeof(ext.safe_get_unit), Any, Any} || return false

    fields = _getproperty_fields(method)
    fields === nothing && return false
    return all(field -> field in fields, (:DimensionError, :x, :y)) &&
           all(field -> !(field in fields), (:q1, :q2))
end

function _patch_mtk_dimension_error()
    ext = Base.get_extension(MTK, :MTKDynamicQuantitiesExt)
    ext === nothing && return
    isdefined(ext, :safe_get_unit) || return
    (hasfield(DQ.DimensionError, :q1) && hasfield(DQ.DimensionError, :q2)) || return
    (hasfield(DQ.DimensionError, :x) || hasfield(DQ.DimensionError, :y)) && return

    target = try
        which(ext.safe_get_unit, Tuple{Any, Any})
    catch err
        @debug "ConfigKit: Could not resolve ModelingToolkitBase.safe_get_unit(::Any, ::Any); skipping the DimensionError workaround." exception = (err, catch_backtrace())
        return
    end
    _is_broken_mtk_safe_get_unit(ext, target) || return

    # Delete only the fingerprinted generic method. Specialized overloads may
    # belong to upstream or another extension and must remain intact.
    Base.delete_method(target)

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
    return nothing
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
