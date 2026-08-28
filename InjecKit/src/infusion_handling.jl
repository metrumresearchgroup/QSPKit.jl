"""
Infusion parameter calculation and validation for InjecKit.

This module handles infusion event calculations. State-targeted infusions are
applied as zero-order forcing over their active interval; input parameters here
refer only to user-authored model parameters, not generated system extensions.
"""

"""
    is_infusion(rate, duration)

Check if event parameters indicate an infusion (non-zero rate or duration).
"""
function is_infusion(rate, duration)
    return (rate !== nothing && rate > 0) || (duration !== nothing && duration > 0)
end

"""
    is_bolus_dose(rate, duration)

Check if event parameters indicate a bolus dose (zero or missing rate and duration).
"""
function is_bolus_dose(rate, duration)
    return (rate === nothing || rate == 0) && (duration === nothing || duration == 0)
end

"""
    calculate_infusion_parameters(amt, rate, duration)

Calculate missing infusion parameters from the available ones.
Returns (calculated_amt, calculated_rate, calculated_duration).
"""
function calculate_infusion_parameters(amt, rate, duration)
    # Convert missing to nothing
    amt = missing_to_nothing(amt)
    rate = missing_to_nothing(rate)
    duration = missing_to_nothing(duration)

    if rate !== nothing && duration !== nothing
        # Both specified - validate consistency if amt is also provided
        if amt !== nothing && abs(amt - rate * duration) > 1e-10
            error("Inconsistent infusion parameters: amt ≠ rate × duration")
        end
        # Use rate and duration, calculate amt if missing
        if amt === nothing
            amt = rate * duration
        end
        return (amt, rate, duration)
    elseif rate !== nothing
        if amt === nothing
            error("Cannot determine infusion: amt is missing when only rate is provided")
        end
        duration = amt / rate
        return (amt, rate, duration)
    elseif duration !== nothing
        if amt === nothing
            error("Cannot determine infusion: amt is missing when only duration is provided")
        end
        rate = amt / duration
        return (amt, rate, duration)
    else
        error("Must specify either rate or duration for continuous infusion")
    end
end

"""
    calculate_infusion_stop_time(start_time, amt, rate, duration)

Calculate the stop time for an infusion given start time and parameters.
Uses the unified infusion parameter calculation function.
"""
function calculate_infusion_stop_time(start_time, amt, rate, duration)
    # Use the unified calculation function to get all parameters
    calculated_amt, calculated_rate, calculated_duration = calculate_infusion_parameters(amt, rate, duration)
    return start_time + calculated_duration
end

"""
    get_infusion_parameters(sys::MTK.AbstractSystem)

Return all user-authored input parameters in the system.
"""
function get_infusion_parameters(sys::MTK.AbstractSystem)
    infusion_params = MTK.Num[]
    for p in MTK.parameters(sys)
        if MTK.hasmetadata(p, MTK.VariableInput) && MTK.getmetadata(p, MTK.VariableInput)
            push!(infusion_params, p)
        end
    end
    return infusion_params
end
