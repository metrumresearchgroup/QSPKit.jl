"""
Variable and parameter resolution functions for InjecKit.

This module provides unified functions for converting variable/parameter references
from various formats (Symbol, String, MTK.Num) to actual MTK
variables using symbolic comparison.
"""

# Missing function definitions that are used throughout the codebase
getParName(v) = MTK.getname(v)
complete(sys) = MTK.complete(sys)

"""
    missing_to_nothing(value)

Convert missing values to nothing. Pass through all other values unchanged.
"""
missing_to_nothing(value) = (value === missing) ? nothing : value

function _canonical_reference_symbol(var_ref::Union{Symbol, AbstractString})
    raw = String(var_ref)
    if occursin('.', raw)
        tail = last(split(raw, '.'))
        isempty(tail) || return Symbol(tail)
    end
    return Symbol(raw)
end

"""
    resolve_variable_to_num(var_ref, sys::MTK.AbstractSystem;
                           expected_type=:any, time=nothing, require_time_dependent=false,
                           require_input_metadata=false)

Unified function to convert variable/parameter references to actual MTK.Num objects.
Based on naming.jl pattern. Supports String, Symbol, MTK.Num inputs, and differential expressions.
For differential expressions like D(C), extracts the underlying variable C.
Returns the actual MTK variable for symbolic comparison with isequal.

Optional validation parameters:
- expected_type: :any, :variable, :parameter - validates that resolved entity is of expected type
- time: event time for error messages (if validation fails)
- require_time_dependent: if true, validates that parameters are time-dependent
- require_input_metadata: if true, validates that parameters have input=true metadata (for infusions)
"""
function resolve_variable_to_num(var_ref, sys::MTK.AbstractSystem;
                                expected_type=:any, time=nothing, require_time_dependent=false,
                                require_input_metadata=false)
    # Resolve the variable/parameter to its MTK representation
    resolved_var = if isa(var_ref, AbstractString)
        resolve_variable_to_num(_canonical_reference_symbol(var_ref), sys;
                                expected_type=expected_type,
                                time=time,
                                require_time_dependent=require_time_dependent,
                                require_input_metadata=require_input_metadata)
    elseif isa(var_ref, Symbol)
        var_ref = _canonical_reference_symbol(var_ref)
        var_to_name_map = MTK.get_var_to_name(sys)
        if haskey(var_to_name_map, var_ref)
            var_to_name_map[var_ref]
        else
            # If not in var_to_name_map, the variable doesn't exist
            error("$var_ref not found in system. Available quantities: $(keys(var_to_name_map))")
        end
    elseif isa(var_ref, Union{MTK.Num, Symbolics.BasicSymbolic})
        # Check if this is a differential expression like D(C)
        candidate = if MTK.isdifferential(Symbolics.unwrap(var_ref))
            # Extract the variable from the differential: D(C) -> C
            MTK.arguments(Symbolics.unwrap(var_ref))[1]
        else
            var_ref
        end

        # A caller may hold a symbolic object from the pre-extension system
        # while InjecKit has automatically replaced an ordinary parameter with
        # a time-dependent discrete parameter of the same name. Re-resolve by
        # name when the object itself is not in the active system.
        params_set = buildSet(MTK.parameters(sys))
        unknowns_set = buildSet(MTK.unknowns(sys))
        if !(candidate in params_set || candidate in unknowns_set)
            candidate_name = try MTK.getname(candidate) catch; nothing end
            var_to_name_map = MTK.get_var_to_name(sys)
            if candidate_name !== nothing && haskey(var_to_name_map, candidate_name)
                candidate = var_to_name_map[candidate_name]
            end
        end
        candidate
    else
        throw(ArgumentError("Unsupported variable type: $(typeof(var_ref))"))
    end

    # Perform optional validation
    if expected_type != :any || require_time_dependent || require_input_metadata
        perform_validation(resolved_var, var_ref, sys, expected_type, time, require_time_dependent, require_input_metadata)
    end

    return Num(resolved_var)
end

"""
    perform_validation(resolved_var, original_ref, sys, expected_type, time, require_time_dependent, require_input_metadata)

Perform validation on a resolved variable/parameter based on the specified requirements.
"""
function perform_validation(resolved_var, original_ref, sys, expected_type, time, require_time_dependent, require_input_metadata)
    time_str = time !== nothing ? " at time $time" : ""
    ref_str = string(original_ref)

    # Build sets once for efficiency
    params_set = buildSet(MTK.parameters(sys))
    unknowns_set = buildSet(MTK.unknowns(sys))

    # Check if parameter is in bindings (computed/dependent - cannot be modified directly)
    # Note: State variables in bindings (initial condition bindings) are OK for dosing,
    # only parameter bindings (computed parameters like derived_rate => expr) should be rejected
    if resolved_var in params_set
        bindings_dict = try MTK.bindings(sys) catch; Dict() end
        if !isempty(bindings_dict)
            resolved_name = MTK.getname(resolved_var)
            for (binding_var, _) in bindings_dict
                if MTK.getname(binding_var) == resolved_name
                    error("Cannot modify '$ref_str'$time_str - it is a computed/dependent parameter defined in bindings. " *
                          "To change this value, modify its source parameters instead.")
                end
            end
        end
    end

    # Type validation - check if resolved entity is of expected type
    if expected_type == :variable
        # Check if it's actually a parameter (wrong type)
        if resolved_var in params_set
            error("Got EVID=1 at $time_str for $ref_str with only AMT. Cannot add a bolus dose into parameter `$ref_str`. For parameter changes, use EVID=2 with a parameter column.")
        end
    elseif expected_type == :parameter
        # Check if it's actually a state variable (wrong type)
        if resolved_var in unknowns_set
            error("Expected '$ref_str'$time_str to be a parameter, but it's a state variable. State variables should be dosed using EVID=1 with CMT column.")
        end
    end

    # Time dependency validation (only for parameters)
    # MTK v11+: Check if parameter is a discrete by looking at VariableSource metadata
    if require_time_dependent && resolved_var in params_set
        iv = MTK.get_iv(sys)
        p_unwrapped = Symbolics.unwrap(resolved_var)
        # Check if VariableSource metadata indicates this is a discrete
        source = Symbolics.getmetadata(p_unwrapped, MTK.VariableSource, nothing)
        istv = source !== nothing && source[1] === :discretes
        if !istv
            error("Parameter '$ref_str'$time_str is not time-dependent. Please declare as @discretes $ref_str($iv) to allow time-varying changes.")
        end
    end

    # Input metadata validation (only for time-dependent parameters)
    if require_input_metadata && resolved_var in params_set
        if !MTK.hasmetadata(resolved_var, MTK.VariableInput) ||
           !MTK.getmetadata(resolved_var, MTK.VariableInput)
            iv = MTK.get_iv(sys)
            error("Parameter '$ref_str'$time_str used for infusion must have input=true metadata. Declare as @discretes $ref_str($iv) = value [input=true]")
        end
    end
end

function buildSet(vps)
    # Use Any type for compatibility with SymbolicUtils v4+ where Symbolics.Symbolic is no longer defined
    ps = Set{Any}()
    for x in vps
        push!(ps, x)
        if symbolic_type(x) == ArraySymbolic() && Symbolics.shape(x) != Symbolics.Unknown()
            xx = Symbolics.scalarize(x)
            union!(ps, xx)
        end
    end
    return ps
end

"""
    is_variable_in_system(var_ref, sys, collection_getter)

Check if a variable/parameter exists in a system using symbolic comparison.
collection_getter should be MTK.unknowns or MTK.parameters.
Returns false if variable cannot be resolved or found.
Works with unresolved references (Symbol, String) - used during initial resolution.
"""
function is_variable_in_system(var_ref, sys, collection_getter)
    try
        resolved_var = resolve_variable_to_num(var_ref, sys)
        collection = collection_getter(sys)
        collection_set = buildSet(collection)
        return resolved_var in collection_set
    catch
        return false
    end
end

"""
    find_variable_in_system(var_ref, sys, collection_getter)

Find a variable/parameter in a system using symbolic comparison.
Returns the variable or nothing if not found.
collection_getter should be MTK.unknowns or MTK.parameters.
Works with unresolved references (Symbol, String) - used during initial resolution.
"""
function find_variable_in_system(var_ref, sys, collection_getter)
    try
        resolved_var = resolve_variable_to_num(var_ref, sys)
        collection = collection_getter(sys)
        collection_set = buildSet(collection)
        if resolved_var in collection_set
            # Find the exact match in the original collection
            matches = isequal.(resolved_var, collection)
            idx = findfirst(matches)
            return idx !== nothing ? collection[idx] : nothing
        end
        return nothing
    catch
        return nothing
    end
end


"""
    is_state_variable(cmt, sys)

Check if CMT refers to a state variable (unknown) in the system using symbolic comparison.
"""
is_state_variable(cmt, sys) = is_variable_in_system(cmt, sys, MTK.unknowns)

"""
    is_parameter(cmt, sys)

Check if CMT refers to a parameter in the system using symbolic comparison.
"""
is_parameter(cmt, sys) = is_variable_in_system(cmt, sys, MTK.parameters)
