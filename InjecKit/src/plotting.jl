"""
Plotting utilities for InjecKit.

This module provides functions for visualizing infusion rates and other
event-related data from simulation results.
"""

function plot_infusion_history(sol, state_var::Union{Symbol, String})
    """Plot the infusion rate history for a given state variable"""
    # Find corresponding infusion parameter
    sys = sol.prob.f.sys
    infusion_params = get_infusion_parameters(sys)
    
    # Look for parameter matching the state variable name pattern
    target_pattern = string("infusion_rate_", state_var)
    matching_params = filter(p -> contains(string(p), target_pattern), infusion_params)
    
    if isempty(matching_params)
        @warn "No infusion parameter found for state variable $state_var"
        return nothing
    end
    
    if !isdefined(@__MODULE__, :plot)
        @warn "Plots.jl is not loaded; returning nothing"
        return nothing
    end

    # Plot the infusion rate over time
    param = first(matching_params)
    return getfield(@__MODULE__, :plot)(sol, idxs = param, label = "Infusion rate for $state_var")
end
