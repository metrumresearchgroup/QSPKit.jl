"""
ODEProblem constructor interfaces for InjecKit.

This module provides the public ODEProblem constructor functions that delegate
to the optimized constructor core for different event data types.
"""

# Type alias for all supported event types
const EventTypes = Union{DataFrame,
                        IEvent,
                        EventSchedule,
                        Vector{IEvent},
                        MTK.SymbolicDiscreteCallback,
                        Vector{<:MTK.SymbolicDiscreteCallback}}

# Type alias for u0/p map types
const MapTypes = Union{AbstractDict, Vector{<:Pair}, Vector{Any}}

#=
4-argument constructors (modern style)
These are the preferred constructors that follow MTK v10 best practices
=#

# Specific constructors for each event type with AbstractDict to avoid ambiguity
function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::AbstractDict, tspan::Tuple{<:Real, <:Real}, events::DataFrame; kwargs...)
    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::AbstractDict, tspan::Tuple{<:Real, <:Real}, events::Vector{IEvent}; kwargs...)
    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::AbstractDict, tspan::Tuple{<:Real, <:Real}, events::EventSchedule; kwargs...)
    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::AbstractDict, tspan::Tuple{<:Real, <:Real}, events::MTK.SymbolicDiscreteCallback; kwargs...)
    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::AbstractDict, tspan::Tuple{<:Real, <:Real}, events::Vector{<:MTK.SymbolicDiscreteCallback}; kwargs...)
    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

# Specific constructors for each event type with Vector{<:Pair} to avoid ambiguity
function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::Vector{<:Pair}, tspan::Tuple{<:Real, <:Real}, events::DataFrame; kwargs...)
    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::Vector{<:Pair}, tspan::Tuple{<:Real, <:Real}, events::Vector{IEvent}; kwargs...)
    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::Vector{<:Pair}, tspan::Tuple{<:Real, <:Real}, events::EventSchedule; kwargs...)
    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::Vector{<:Pair}, tspan::Tuple{<:Real, <:Real}, events::MTK.SymbolicDiscreteCallback; kwargs...)
    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::Vector{<:Pair}, tspan::Tuple{<:Real, <:Real}, events::Vector{<:MTK.SymbolicDiscreteCallback}; kwargs...)
    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

# Generic 4-arg constructor for all event types with empty Vector{Any}
function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::Vector{Any}, tspan::Tuple{<:Real, <:Real}, events::EventTypes; kwargs...)
    if isempty(u0_p_map)
        return optimized_ode_constructor(sys, Dict(), tspan, events; kwargs...)
    else
        # Try to convert to pairs if possible
        return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
    end
end

#=
5-argument constructors (deprecated style)
These constructors maintain backward compatibility but issue deprecation warnings
=#

# Helper function to convert various u0/p types to Dict
function _to_dict(x)
    if x isa AbstractDict
        return x
    elseif x isa Vector{<:Pair}
        return Dict(x)
    elseif isempty(x)
        return Dict()
    else
        # For non-pair vectors, we can't convert meaningfully
        error("Cannot convert $(typeof(x)) to Dict. Use pairs (e.g., [sys.x => 1.0]) or Dict.")
    end
end

# Generic 5-arg deprecated constructor for all combinations
function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0::Any, tspan::Tuple{<:Real, <:Real}, p::Any, events::EventTypes; kwargs...)
    @warn "`ODEProblem(sys, u0, tspan, p, events; kw...)` is deprecated. Use `ODEProblem(sys, merge(Dict(u0), Dict(p)), tspan, events)` instead."

    u0_dict = _to_dict(u0)
    p_dict = _to_dict(p)
    u0_p_map = merge(u0_dict, p_dict)

    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

# Also support the order where events come before p (for backward compatibility)
function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0::Any, tspan::Tuple{<:Real, <:Real}, events::EventTypes, p::Any; kwargs...)
    @warn "`ODEProblem(sys, u0, tspan, events, p; kw...)` is deprecated. Use `ODEProblem(sys, merge(Dict(u0), Dict(p)), tspan, events)` instead."

    u0_dict = _to_dict(u0)
    p_dict = _to_dict(p)
    u0_p_map = merge(u0_dict, p_dict)

    return optimized_ode_constructor(sys, u0_p_map, tspan, events; kwargs...)
end

#=
Special handlers for single events (automatically wrap in vector)
=#

# Single IEvent
function OrdinaryDiffEq.ODEProblem(sys::MTK.System, u0_p_map::MapTypes, tspan::Tuple{<:Real, <:Real}, event::IEvent; kwargs...)
    return OrdinaryDiffEq.ODEProblem(sys, u0_p_map, tspan, [event]; kwargs...)
end

# Note: Single SymbolicDiscreteCallback is already handled in the generic EventTypes union

# Note: All constructors use the shared event-plan path in constructor_core.jl.
