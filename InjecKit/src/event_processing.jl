"""
Event analysis and processing functions for InjecKit.

This module handles event data analysis and event time extraction
for various event data formats (DataFrame, IEvent, SymbolicDiscreteCallback).
"""

# Standard reserved columns for DataFrame events
const RESERVED_COLUMNS = Set([:TIME, :EVID, :CMT, :AMT, :RATE, :DURATION, :II, :ADDL, :SS])

"""
    hash_events(events_data)

Compute a hash of event data for caching purposes.
Works with DataFrame, Vector{IEvent}, or Vector{SymbolicDiscreteCallback}.
"""
function hash_events(events_data::DataFrame)
    # Hash all columns that affect the callback structure
    h = hash(:DataFrame)
    for col in [:TIME, :EVID, :CMT, :AMT, :RATE, :DURATION, :II, :ADDL]
        if col in propertynames(events_data)
            h = hash(events_data[!, col], h)
        end
    end
    return h
end

function hash_events(events_data::Vector{IEvent})
    h = hash(:IEvent)
    for event in events_data
        h = hash(event.time, h)
        h = hash(event.evid, h)
        h = hash(event.cmt, h)
        h = hash(event.amt, h)
        h = hash(event.rate, h)
        h = hash(event.duration, h)
        h = hash(event.ii, h)
        h = hash(event.addl, h)
        for key in sort!(collect(keys(event.param_changes)); by=string)
            h = hash(key, h)
            h = hash(event.param_changes[key], h)
        end
    end
    return h
end

function hash_events(events_data::Vector{<:MTK.SymbolicDiscreteCallback})
    # For SymbolicDiscreteCallbacks, hash by objectid since they're complex symbolic objects
    h = hash(:SymbolicDiscreteCallback)
    for event in events_data
        h = hash(objectid(event), h)
    end
    return h
end

# Single IEvent convenience - wrap and hash
hash_events(event::IEvent) = hash_events([event])

"""
    dataframe_to_mrgevents(df::DataFrame)

Convert a DataFrame with dosing/event data to a Vector{IEvent}.
Validates DataFrame structure and column requirements.
This provides unified internal representation regardless of input format.
"""
function dataframe_to_mrgevents(df::DataFrame)
    # Validate required columns
    if !("TIME" in names(df))
        error("DataFrame must contain a TIME column")
    end

    if !("EVID" in names(df))
        error("DataFrame must contain an EVID column")
    end

    # Validate TIME column
    if !all(isa.(df.TIME, Number))
        error("TIME column must contain numeric values")
    end

    # Validate EVID column
    if !all(isa.(df.EVID, Integer))
        error("EVID column must contain integer values")
    end

    # Check for valid EVID values
    valid_evids = Set([1, 2, 3, 4, 8])  # Common EVID values
    invalid_evids = setdiff(Set(df.EVID), valid_evids)
    if !isempty(invalid_evids)
        error("Invalid EVID values found: $(collect(invalid_evids)). Valid values are 1 (dose), 2 (parameter change), 3 (reset), 4 (reset+dose), 8 (state replacement)")
    end

    # Validate dosing events have CMT
    dosing_rows = df[df.EVID .== 1, :]
    if nrow(dosing_rows) > 0 && !("CMT" in names(df))
        error("DataFrame with dosing events (EVID=1) must contain a CMT column")
    end

    events = IEvent[]

    for row in eachrow(df)
        # Extract standard columns
        time = row.TIME
        evid = row.EVID
        cmt = missing_to_nothing(get(row, :CMT, nothing))
        amt = missing_to_nothing(get(row, :AMT, nothing))
        rate = missing_to_nothing(get(row, :RATE, nothing))
        duration = missing_to_nothing(get(row, :DURATION, nothing))
        ii = missing_to_nothing(get(row, :II, nothing))
        addl = missing_to_nothing(get(row, :ADDL, nothing))
        ss = missing_to_nothing(get(row, :SS, nothing))

        # Additional row-level validation
        if evid == 1 && (cmt === nothing || cmt === missing)
            error("CMT is required for dosing events (EVID=1) at time $time")
        end
        if evid == 8
            cmt === nothing &&
                error("CMT is required for state replacement events (EVID=8) at time $time")
            amt === nothing &&
                error("AMT is required for state replacement events (EVID=8) at time $time")
        end

        # Extract parameter changes from non-reserved columns
        param_changes = Dict{Union{Symbol, MTK.Num}, Float64}()
        if evid == 2 || evid == 8
            for col_name in names(row)
                col_symbol = Symbol(col_name)
                if !(col_symbol in RESERVED_COLUMNS)
                    param_value = get(row, col_name, nothing)
                    if param_value !== nothing && param_value !== missing
                        evid == 8 && error(
                            "State replacement event (EVID=8) at time $time does not " *
                            "accept non-reserved column $(repr(col_symbol)). Use EVID=2 " *
                            "for parameter changes.")
                        param_changes[col_symbol] = Float64(param_value)
                    end
                end
            end
        end

        push!(events, IEvent(time, cmt, amt, rate, duration, evid, ii, addl, ss, param_changes))
    end

    return events
end

"""
    resolve_mrgevents(events::Vector{IEvent}, sys::MTK.AbstractSystem)

Take a vector of IEvent with unresolved CMT/parameters and return new IEvent
with resolved MTK variables/parameters. This is where all validation happens.
"""
function resolve_mrgevents(events::Vector{IEvent}, sys::MTK.AbstractSystem)
    resolved_events = IEvent[]

    for event in events
        event.evid in (1, 2, 8) || throw(ArgumentError(
            "Unsupported EVID=$(event.evid) at time $(event.time). InjecKit scheduled " *
            "events support EVID=1 (dose), EVID=2 (parameter change), and EVID=8 " *
            "(single-state replacement). EVID=3 and EVID=4 are reserved for " *
            "whole-system reset semantics and are not implemented."))

        # Resolve CMT if it's a dosing event
        resolved_cmt = if event.evid == 8
            _validate_state_set_event_shape(event)
            _resolve_state_set_target(event.cmt, sys, event.time)
        elseif event.evid == 1 && event.cmt !== nothing
            # Determine validation requirements based on event type
            rate = missing_to_nothing(event.rate)
            duration = missing_to_nothing(event.duration)

            if is_infusion(rate, duration)
                # For infusions, validate CMT appropriately
                if is_parameter(event.cmt, sys)
                    # Manual infusion parameter - validate with infusion requirements
                    resolve_variable_to_num(event.cmt, sys;
                                          expected_type=:parameter,
                                          time=event.time,
                                          require_time_dependent=true,
                                          require_input_metadata=true)
                else
                    # State variable for infusion
                    resolve_variable_to_num(event.cmt, sys;
                                          expected_type=:variable,
                                          time=event.time)
                end
            else
                # For bolus doses, CMT must be a state variable
                resolve_variable_to_num(event.cmt, sys;
                                      expected_type=:variable,
                                      time=event.time)
            end
        else
            event.cmt  # Keep as-is for non-dosing events
        end

        # Resolve parameter changes if it's a parameter change event
        resolved_param_changes = if event.evid == 2 && !isempty(event.param_changes)
            resolved_params = Dict{Union{Symbol, MTK.Num}, Float64}()
            for (param_name, param_value) in event.param_changes
                # Only resolve if it's still a Symbol (not already resolved)
                if param_name isa Union{Symbol, AbstractString, MTK.Num, Symbolics.BasicSymbolic}
                    resolved_param = resolve_variable_to_num(param_name, sys;
                                                           expected_type=:parameter,
                                                           time=event.time,
                                                           require_time_dependent=true)
                    resolved_params[resolved_param] = param_value
                end
            end
            resolved_params
        else
            event.param_changes  # Keep as-is for non-parameter-change events
        end

        # Create new IEvent with resolved entities
        resolved_event = IEvent(
            event.time,
            resolved_cmt,
            event.amt,
            event.rate,
            event.duration,
            event.evid,
            event.ii,
            event.addl,
            event.ss,
            resolved_param_changes
        )

        push!(resolved_events, resolved_event)
    end

    return resolved_events
end

function _validate_state_set_event_shape(event::IEvent)
    isfinite(event.time) || throw(ArgumentError(
        "State replacement event (EVID=8) requires a finite event time, got $(repr(event.time))."))
    event.cmt === nothing && throw(ArgumentError(
        "State replacement event (EVID=8) at time $(event.time) requires a CMT target."))
    event.amt === nothing && throw(ArgumentError(
        "State replacement event (EVID=8) at time $(event.time) requires an AMT value."))
    event.rate === nothing || throw(ArgumentError(
        "State replacement event (EVID=8) at time $(event.time) does not accept RATE."))
    event.duration === nothing || throw(ArgumentError(
        "State replacement event (EVID=8) at time $(event.time) does not accept DURATION."))
    event.ii === nothing || throw(ArgumentError(
        "State replacement event (EVID=8) at time $(event.time) does not accept II."))
    event.addl === nothing || throw(ArgumentError(
        "State replacement event (EVID=8) at time $(event.time) does not accept ADDL."))
    event.ss === nothing || throw(ArgumentError(
        "State replacement event (EVID=8) at time $(event.time) does not accept SS."))
    isempty(event.param_changes) || throw(ArgumentError(
        "State replacement event (EVID=8) at time $(event.time) does not accept parameter-change columns."))
    event.amt isa Real && isfinite(event.amt) || throw(ArgumentError(
        "State replacement event (EVID=8) at time $(event.time) requires a finite real AMT value."))
    return nothing
end

function _resolve_state_set_target(target, sys::MTK.AbstractSystem, time)
    resolved = resolve_variable_to_num(target, sys; time=time)
    if resolved in buildSet(MTK.parameters(sys))
        throw(ArgumentError(
            "State replacement event target $(repr(target)) at time $time is a parameter, not a state. Use EVID=2 for parameter changes."))
    end
    resolved in buildSet(MTK.unknowns(sys)) || throw(ArgumentError(
        "State replacement event target $(repr(target)) at time $time is not an assignable MTK state."))
    return resolved
end


function _event_parameter_name(param_ref)
    if param_ref isa Symbol
        return _canonical_reference_symbol(param_ref)
    elseif param_ref isa AbstractString
        return _canonical_reference_symbol(param_ref)
    else
        return try Symbol(MTK.getname(param_ref)) catch; nothing end
    end
end

function analyze_events_for_parameter_changes(events_data::Vector{IEvent})
    targets = Set{Symbol}()
    for event in events_data
        event.evid == 2 || continue
        for param_ref in keys(event.param_changes)
            name = _event_parameter_name(param_ref)
            name === nothing || push!(targets, name)
        end
    end
    return targets
end

"""
    simple_t0_update!(modified_u0_p, u0_p_map, resolved_target, value, is_additive::Bool, sys)

Simple helper function to update a variable/parameter value using already-resolved entities.
Takes a resolved MTK.Num object directly. The system is used to normalize keys from u0_p_map
to their canonical form for proper comparison.
"""
function simple_t0_update!(modified_u0_p, u0_p_map, resolved_target, value, is_additive::Bool, sys)
    # Get the canonical name of the resolved target for comparison
    target_name = MTK.getname(resolved_target)

    # Find the matching variable in u0_p_map by resolving keys to canonical form
    for (var, val) in u0_p_map
        # Get the name of this key, handling different types
        var_name = try
            if var isa Symbol
                var  # Symbol is already the name
            elseif var isa String
                Symbol(var)
            else
                # Num or BasicSymbolic - extract name
                MTK.getname(var)
            end
        catch
            continue  # Skip if we can't get the name
        end

        # Compare by name for robust matching
        if var_name == target_name
            if is_additive
                # Read current value from modified_u0_p (not u0_p_map) so that
                # multiple t=0 events to the same compartment accumulate correctly.
                # e.g., two 50mg boluses at t=0 should yield 100mg, not 50mg.
                current_val = get(modified_u0_p, var, val)
                modified_u0_p[var] = current_val + value
            else
                modified_u0_p[var] = value
            end
            return true
        end
    end
    return false  # Not found in u0_p_map
end

"""
    _extract_event_info(event::MTK.SymbolicDiscreteCallback)

Extract time, target variable, effect amount, and operation type from a SymbolicDiscreteCallback.
Returns (time, target_var, effect_amount, is_additive).
- is_additive=true for state variable updates: var ~ Pre(var) + amount
- is_additive=false for parameter assignments: param ~ new_value
"""
function _extract_event_info(event::MTK.SymbolicDiscreteCallback)
    # Extract time from conditions (assuming format: [time_value])
    event_time = nothing
    if hasfield(typeof(event), :conditions) && !isempty(event.conditions)
        condition = first(event.conditions)  # Take first condition
        if condition isa Number
            event_time = Float64(condition)
        end
    end

    # If time extraction failed, return failure
    if event_time === nothing
        return (nothing, nothing, 0.0, true)
    end

    # Extract target variable and effect from affect (SymbolicAffect with equations)
    target_var = nothing
    effect_amount = 0.0
    is_additive = true  # Default to additive (state variable update)

    if hasfield(typeof(event), :affect) && hasfield(typeof(event.affect), :affect) && !isempty(event.affect.affect)
        affect_eq = first(event.affect.affect)  # Take first equation from SymbolicAffect
        if affect_eq isa Equation
            target_var = affect_eq.lhs
            # Parse RHS to extract the amount and determine operation type
            rhs = affect_eq.rhs

            # Helper to extract numeric value from Number or symbolic literal
            function try_extract_number(x)
                if x isa Number
                    return Float64(x)
                else
                    # Try to extract value from symbolic literal (e.g., BasicSymbolic representing 100.0)
                    try
                        val = Symbolics.value(x)
                        if val isa Number
                            return Float64(val)
                        end
                    catch
                    end
                end
                return nothing
            end

            maybe_val = try_extract_number(rhs)
            if maybe_val !== nothing
                # Format: var ~ amount (direct assignment)
                is_additive = false  # This is a direct assignment
                effect_amount = maybe_val
            elseif MTK.SymbolicUtils.iscall(rhs) && MTK.SymbolicUtils.operation(rhs) == (+)
                # Format: var ~ amount + Pre(var) or var ~ Pre(var) + amount
                is_additive = true  # This is an additive update
                args = MTK.SymbolicUtils.arguments(rhs)
                for arg in args
                    maybe_val = try_extract_number(arg)
                    if maybe_val !== nothing
                        effect_amount = maybe_val
                        break
                    end
                end
            end
        end
    end

    return (event_time, target_var, effect_amount, is_additive)
end

"""
    _extract_all_event_times(events_data::Vector{IEvent})

Extract all event times including infusion stop times from IEvent data.
"""
function _extract_all_event_times(events_data::Vector{IEvent})
    times = Float64[]

    for event in events_data
        push!(times, event.time)

        # Add infusion stop times
        if event.evid == 1  # Dosing event
            rate = missing_to_nothing(event.rate)
            duration = missing_to_nothing(event.duration)
            amt = missing_to_nothing(event.amt)

            if is_infusion(rate, duration)
                # Calculate infusion stop time using unified function
                # This will throw an error if parameters are invalid, which is correct behavior
                stop_time = calculate_infusion_stop_time(event.time, amt, rate, duration)
                push!(times, stop_time)
            end
        end
    end

    return unique(times)
end

"""
    _add_event_times_to_tstops(kwargs, event_times)

Add event times to tstops kwargs, merging with existing tstops if present.
"""
function _add_event_times_to_tstops(kwargs, event_times)
    if isempty(event_times)
        return kwargs
    end

    # Convert to mutable NamedTuple
    kwargs_dict = Dict{Symbol, Any}(kwargs...)

    if haskey(kwargs_dict, :tstops)
        # Merge with existing tstops
        existing_tstops = kwargs_dict[:tstops]
        if existing_tstops isa AbstractVector
            merged_tstops = unique(vcat(existing_tstops, event_times))
        else
            merged_tstops = unique(vcat([existing_tstops], event_times))
        end
        kwargs_dict[:tstops] = sort(merged_tstops)
    else
        # Add new tstops
        kwargs_dict[:tstops] = sort(unique(event_times))
    end

    return (; kwargs_dict...)
end

"""
    expand_repeated_events(events::Vector{IEvent})

Expand events with ii (interdose interval) and addl (additional doses) into individual events.
This follows NONMEM/mrgsolve convention where an event with ii and addl creates multiple doses.

For example, an event at time=0 with ii=24 and addl=2 creates doses at times 0, 24, and 48.
"""
function expand_repeated_events(events::Vector{IEvent})
    expanded_events = IEvent[]

    for event in events
        # Always add the original event
        push!(expanded_events, event)

        # If ii and addl are specified, create additional events
        if event.ii !== nothing && event.addl !== nothing && event.addl > 0
            for i in 1:event.addl
                new_time = event.time + i * event.ii

                # Create a new event with the same properties but at the new time
                # and without ii/addl (to avoid infinite recursion)
                new_event = IEvent(
                    new_time,
                    event.cmt,
                    event.amt,
                    event.rate,
                    event.duration,
                    event.evid,
                    nothing,  # no ii for the expanded events
                    nothing,  # no addl for the expanded events
                    event.ss,
                    event.param_changes
                )
                push!(expanded_events, new_event)
            end
        end
    end

    # Sort by time to maintain chronological order
    sort!(expanded_events, by = e -> e.time)

    return expanded_events
end
