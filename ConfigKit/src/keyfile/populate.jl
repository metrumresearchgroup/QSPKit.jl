# System Population from Keyfiles

struct RequiredRuntimeParameter
    name::Symbol
    observed_outputs::Vector{Symbol}
end

function _runtime_parameter_error_message(x::RequiredRuntimeParameter)
    outputs = isempty(x.observed_outputs) ? "" : " Observed outputs: " * join(x.observed_outputs, ", ") * "."
    return "ConfigKit: Missing required runtime parameter '$(x.name)'.$outputs " *
           "This parameter appears in observed equations but has no keyfile or model default. " *
           "Pass it when constructing the problem, e.g. " *
           "ODEProblem(sys, [sys.$(x.name) => value], tspan), or add a value for '$(x.name)' to the keyfile."
end

Base.show(io::IO, x::RequiredRuntimeParameter) = print(io, "ConfigKit.RequiredRuntimeParameter(:", x.name, ")")
Base.convert(::Type{T}, x::RequiredRuntimeParameter) where {T<:AbstractFloat} = error(_runtime_parameter_error_message(x))
Base.float(x::RequiredRuntimeParameter) = error(_runtime_parameter_error_message(x))

"""
    populate(system, keyfile; variant=nothing, overrides=Dict(), strict=true, solve_for=Pair[])

Populate an MTK System from a Keyfile.

# Arguments
- `system`: An MTK System to populate
- `keyfile`: A KeyfileAccessor loaded from a YAML keyfile
- `variant`: Optional variant name to select
- `overrides`: Dict of parameter/variable overrides
- `strict`: If true, validate units and structure
- `solve_for`: Vector of pairs specifying initialization system targets and adjustable params.
  Format: `[:target => [:param1, :param2]]` or `["target ~ expr" => [:param1]]`
  - If target is a Symbol, uses the keyfile expression for that parameter
  - If target is a String/Expr, parses it as a custom equation
  - Adjustable params must have numeric values in keyfile (used as guesses)
"""
function populate(
    system::MTK.AbstractSystem,
    keyfile::KeyfileAccessor;
    variant::Union{Symbol, String, Nothing} = nothing,
    overrides::Dict = Dict(),
    strict::Bool = true,
    solve_for::Vector = Pair[]
)
    if variant !== nothing
        @info "ConfigKit: populate() called with variant=$variant"
    end

    # 0. Validate Overrides
    valid_keys = Set{String}()
    for k in keys(keyfile.Parameters); push!(valid_keys, string(k)); end
    for k in keys(keyfile.Variables); push!(valid_keys, string(k)); end

    for (ov_key, _) in overrides
        if ov_key ∉ valid_keys
            error("ConfigKit: Override key '$ov_key' does not match any Parameter or Variable in the keyfile.")
        end
    end

    # =======================================================
    # PHASE 0: Global Unit Inference
    # =======================================================
    unit_map = Dict{Symbol, Any}()

    for p in MTK.parameters(system)
        u = Symbolics.getmetadata(p, MTK.VariableUnit, nothing)
        if u !== nothing; unit_map[Symbol(MTK.getname(p))] = u; end
    end
    for v in MTK.unknowns(system)
        u = Symbolics.getmetadata(v, MTK.VariableUnit, nothing)
        if u !== nothing; unit_map[Symbol(MTK.getname(v))] = u; end
    end

    # Merge all keyfile entries (Parameters, Variables, and Constants) for unit inference
    all_entries = merge(keyfile.Parameters.data, keyfile.Variables.data, keyfile.Constants.data)
    is_dimensionless(u) = (u isa DQ.AbstractQuantity && u.value == 1.0 && u.dimensions == DQ.Dimensions())

    for (k, entry) in all_entries
        if entry.unit !== Unitful.NoUnits
            if entry.value isa String && is_dimensionless(entry.unit); continue; end
            # Normalize unit to magnitude 1.0 (strip the numeric prefix like 1e-6 from nmol/L)
            u = entry.unit
            if u isa DQ.AbstractQuantity
                unit_map[k] = DQ.Quantity(1.0, DQ.dimension(u))
            else
                unit_map[k] = u
            end
        end
    end

    eval_module_inf = Module()
    Core.eval(eval_module_inf, :(const DQ = $DQ))
    Core.eval(eval_module_inf, :(const Unitful = $Unitful))

    for (sym, u) in unit_map
        if u isa DQ.AbstractQuantity
            norm_u = DQ.Quantity(1.0, DQ.dimension(u))
            Core.eval(eval_module_inf, :($sym = $norm_u))
        elseif u isa Number
            Core.eval(eval_module_inf, :($sym = $u))
        end
    end

    for _ in 1:3
        resolved_count = 0
        for (k, entry) in all_entries
            if !haskey(unit_map, k) && entry.value isa String
                try
                    val = Core.eval(eval_module_inf, Meta.parse(entry.value))
                    if val isa DQ.AbstractQuantity
                        norm_u = DQ.Quantity(1.0, DQ.dimension(val))
                        unit_map[k] = norm_u
                        Core.eval(eval_module_inf, :($k = $norm_u))
                        resolved_count += 1
                        @debug "ConfigKit: Inferred unit for $k: $norm_u"
                    end
                catch
                end
            end
        end
        if resolved_count == 0; break; end
    end

    iv = nothing
    try
        ivs = MTK.independent_variables(system)
        iv = isempty(ivs) ? MTK.independent_variable(system) : ivs[1]
    catch; end

    # Infer IV unit from unit_map: if any parameter/variable has a time dimension
    # in its unit (e.g., s⁻¹, L/s, 1/s), the independent variable must be in seconds.
    # This runs in Phase 0 so the IV gets its unit injected in Phase 1 along with everything else.
    if iv !== nothing
        iv_name = Symbol(MTK.getname(iv))
        if !haskey(unit_map, iv_name)
            for (sym, u) in unit_map
                u isa DQ.AbstractQuantity || continue
                d = DQ.dimension(u)
                d == DQ.Dimensions() && continue
                if d.time != 0
                    unit_map[iv_name] = DQ.Quantity(1.0, DQ.Dimensions(time=1))
                    @debug "ConfigKit: Inferred IV unit 's' from parameter '$sym' (unit: $u)"
                    break
                end
            end
        end
    end

    # =======================================================
    # PHASE 1: System Reconstruction (Metadata Injection)
    # =======================================================
    meta_subs = Dict{Any, Any}()

    # Collect all free symbols from equations (symbols that appear but aren't declared as params/unknowns)
    equation_symbols = Dict{String, Any}()
    for eq in MTK.equations(system)
        for var in Symbolics.get_variables(eq.rhs)
            try
                var_name = string(MTK.getname(var))
                if !haskey(equation_symbols, var_name)
                    equation_symbols[var_name] = var
                end
            catch
            end
        end
        for var in Symbolics.get_variables(eq.lhs)
            try
                var_name = string(MTK.getname(var))
                if !haskey(equation_symbols, var_name)
                    equation_symbols[var_name] = var
                end
            catch
            end
        end
    end
    for eq in MTK.observed(system)
        for var in Symbolics.get_variables(eq.rhs)
            try
                var_name = string(MTK.getname(var))
                if !haskey(equation_symbols, var_name)
                    equation_symbols[var_name] = var
                end
            catch
            end
        end
    end
    # Find a symbol in the system by name (checks equation symbols first, then system declarations)
    # We check equation_symbols FIRST because those are the actual symbols used in equations
    # that need to be substituted. parse_variable returns namespaced symbols which may not match.
    function find_sys_symbol(name::Symbol)
        name_str = string(name)

        # Check symbols found in equations FIRST (these are the actual symbols to substitute)
        if haskey(equation_symbols, name_str)
            return equation_symbols[name_str]
        end

        # Check independent variables
        try
            ivs = MTK.independent_variables(system)
            for iv_sym in ivs
                if string(MTK.getname(iv_sym)) == name_str
                    return iv_sym
                end
            end
        catch
        end

        # Also check the single independent_variable (for systems with just one)
        try
            iv_sym = MTK.independent_variable(system)
            if string(MTK.getname(iv_sym)) == name_str
                return iv_sym
            end
        catch
        end

        # Last resort: try MTK.parse_variable for namespaced resolution
        try
            return MTK.parse_variable(system, name_str)
        catch
        end

        return nothing
    end

    function add_sub!(old, new)
        meta_subs[old] = new
        meta_subs[Symbolics.wrap(old)] = Symbolics.wrap(new)
        if Symbolics.iscall(old) && Symbolics.iscall(new)
            op_old = Symbolics.operation(old)
            op_new = Symbolics.operation(new)
            meta_subs[op_old] = op_new
        end
    end

    # Helper: Copy ALL metadata using safe property access
    function transfer_all_metadata(new_sym, old_sym)
        unwrapped = Symbolics.unwrap(old_sym)

        if hasproperty(unwrapped, :metadata)
            old_meta = unwrapped.metadata
            if old_meta !== nothing
                for (k, v) in old_meta
                    new_sym = Symbolics.setmetadata(new_sym, k, v)
                end
            end
        end
        return new_sym
    end

    # Helper: Safely get metadata with default (works with Num types)
    function safe_getmetadata(sym, key, default)
        unwrapped = Symbolics.unwrap(sym)
        if hasproperty(unwrapped, :metadata) && unwrapped.metadata !== nothing
            return get(unwrapped.metadata, key, default)
        end
        return default
    end

    # 1. Process Independent Variable
    if iv !== nothing
        iv_name = Symbol(MTK.getname(iv))
        if haskey(unit_map, iv_name)
            new_iv = iv
            # Transfer model metadata first
            new_iv = transfer_all_metadata(new_iv, iv)
            # Only set keyfile unit if model doesn't already have one
            if safe_getmetadata(new_iv, MTK.VariableUnit, nothing) === nothing
                new_iv = Symbolics.setmetadata(new_iv, MTK.VariableUnit, unit_map[iv_name])
            end
            add_sub!(iv, new_iv)
            iv = new_iv
        end
    end

    # 2. Identify system parameters for ghost detection
    sys_param_names = Set{String}()
    for p in MTK.parameters(system)
        push!(sys_param_names, string(MTK.getname(p)))
    end

    # Identify system unknowns
    sys_unknown_names = Set{String}()
    for v in MTK.unknowns(system)
        push!(sys_unknown_names, string(MTK.getname(v)))
    end

    # MTK's shorthand System(eqs, iv; observed=...) infers parameters from the
    # differential/algebraic equations, not necessarily from observed equations.
    # Preserve declared @parameters that appear only in observed RHS expressions
    # so missing values fail at ODEProblem construction instead of at sol[:obs].
    observed_only_params = Dict{String, Any}()
    for (name_str, sym) in equation_symbols
        (name_str ∈ sys_param_names || name_str ∈ sys_unknown_names) && continue
        is_param = try
            MTK.isparameter(Symbolics.unwrap(sym))
        catch
            false
        end
        if is_param
            observed_only_params[name_str] = sym
            push!(sys_param_names, name_str)
        end
    end
    observed_only_param_outputs = Dict{String, Vector{Symbol}}()
    for eq in MTK.observed(system)
        lhs_name = try
            Symbol(MTK.getname(eq.lhs))
        catch
            :unknown
        end
        for var in Symbolics.get_variables(eq.rhs)
            name_str = try
                string(MTK.getname(var))
            catch
                continue
            end
            if haskey(observed_only_params, name_str)
                push!(get!(observed_only_param_outputs, name_str, Symbol[]), lhs_name)
            end
        end
    end

    # Identify differential vs algebraic variables by scanning ALL equations.
    # - Differential equations have D(var) ~ ... on LHS → var needs Initial()
    # - Algebraic equations have var ~ ... on LHS (no D()) → var needs guess, NOT Initial()
    # This works BEFORE mtkcompile (when algebraic eqs are still in equations array)
    # and AFTER mtkcompile (when they've been moved to observed).
    differential_var_names = Set{String}()
    algebraic_var_names_from_eqs = Set{String}()  # Found by scanning equations

    for eq in MTK.equations(system)
        if Symbolics.iscall(eq.lhs) && Symbolics.operation(eq.lhs) isa Differential
            # Differential equation: D(var) ~ ...
            var = Symbolics.arguments(eq.lhs)[1]
            var_name = string(MTK.getname(var))
            push!(differential_var_names, var_name)
        else
            # Algebraic equation: var(t) ~ ... (no D())
            # Extract the LHS variable name
            lhs = eq.lhs
            try
                # For var(t), the LHS is a function call where:
                # - operation(lhs) gives the variable symbol
                # - We use getname on the whole LHS to get the name
                var_name = string(MTK.getname(lhs))
                push!(algebraic_var_names_from_eqs, var_name)
                @debug "ConfigKit: Found algebraic variable '$var_name' from equation LHS"
            catch e
                # Can't extract name, skip
                @debug "ConfigKit: Could not extract variable name from equation LHS: $e"
            end
        end
    end

    # Also scan observed equations (for systems that already have explicit observed)
    for eq in MTK.observed(system)
        try
            var_name = string(MTK.getname(eq.lhs))
            push!(algebraic_var_names_from_eqs, var_name)
            @debug "ConfigKit: Found algebraic variable '$var_name' from observed equation"
        catch e
            @debug "ConfigKit: Could not extract variable name from observed equation: $e"
        end
    end

    @debug "ConfigKit: Identified differential variables: $differential_var_names"
    @debug "ConfigKit: Identified algebraic variables from equations: $algebraic_var_names_from_eqs"

    # Helper to check if a short name (from keyfile) matches any name in a set (from system)
    # Handles namespace prefixes like "subsystem₊Central" matching "Central"
    function name_in_set(short_name::String, name_set::Set{String})
        short_name ∈ name_set || any(n -> endswith(n, "₊" * short_name) || endswith(n, "." * short_name), name_set)
    end

    # 2a. Find which ghost parameters are actually NEEDED by system params/vars expressions
    # A ghost param is needed if:
    # 1. It's referenced by a system parameter's expression
    # 2. It's referenced by a system variable's initial value expression
    # 3. It's referenced by another needed ghost param's expression (transitively)

    function get_expression_symbols(expr_str::String)::Set{Symbol}
        # Parse expression and extract all symbols
        symbols = Set{Symbol}()
        try
            parsed = Meta.parse(expr_str)
            _extract_symbols!(symbols, parsed)
        catch
        end
        return symbols
    end

    function _extract_symbols!(symbols::Set{Symbol}, expr)
        if expr isa Symbol
            push!(symbols, expr)
        elseif expr isa Expr
            for arg in expr.args
                _extract_symbols!(symbols, arg)
            end
        end
    end

    needed_ghosts = Set{Symbol}()

    # First pass: find ghosts needed by system params/vars
    for (k, entry) in keyfile.Parameters
        k_str = string(k)
        if k_str ∈ sys_param_names && entry.value isa String
            for sym in get_expression_symbols(entry.value)
                sym_str = string(sym)
                if sym_str ∉ sys_param_names && sym_str ∉ sys_unknown_names
                    push!(needed_ghosts, sym)
                end
            end
        end
    end
    for (k, entry) in keyfile.Variables
        k_str = string(k)
        if k_str ∈ sys_unknown_names && entry.value isa String
            for sym in get_expression_symbols(entry.value)
                sym_str = string(sym)
                if sym_str ∉ sys_param_names && sym_str ∉ sys_unknown_names
                    push!(needed_ghosts, sym)
                end
            end
        end
    end

    # Also: mark as needed any keyfile constant/ghost referenced directly in the model's
    # equations or observed equations. The two passes above only scan keyfile string
    # expressions, so a constant used solely in the model (e.g. a conversion factor that
    # appears only in an observed readout like scaled_output) is otherwise never
    # materialized as a parameter and surfaces as "X is present in the system but not an
    # unknown" from mtkcompile. `equation_symbols` (Phase 1) already holds every symbol that
    # appears in the system's equations and observed equations.
    for (name_str, _) in equation_symbols
        (name_str ∈ sys_param_names || name_str ∈ sys_unknown_names) && continue
        name_sym = Symbol(name_str)
        if haskey(keyfile.Constants.data, name_sym) || haskey(keyfile.Parameters.data, name_sym)
            push!(needed_ghosts, name_sym)
        end
    end

    # Second pass: transitively find ghosts needed by other needed ghosts
    # (e.g., if ghost A is needed and has expr B * C, then B and C are also needed)
    # Also check Constants since they can be referenced in expressions
    changed = true
    while changed
        changed = false
        for ghost in copy(needed_ghosts)
            # Check in Parameters
            if haskey(keyfile.Parameters.data, ghost)
                entry = keyfile.Parameters.data[ghost]
                if entry.value isa String
                    for sym in get_expression_symbols(entry.value)
                        sym_str = string(sym)
                        if sym_str ∉ sys_param_names && sym_str ∉ sys_unknown_names && sym ∉ needed_ghosts
                            push!(needed_ghosts, sym)
                            changed = true
                        end
                    end
                end
            end
            # Check in Constants (constants don't have expressions, but are needed if referenced)
        end
    end

    @debug "ConfigKit: Needed ghost parameters: $needed_ghosts"

    # 2b. Create ghost parameters ONLY for those that are needed
    # Ghost parameters are keyfile parameters not in the system's parameter list
    ghost_params = Dict{Symbol, Any}()  # name => new symbol
    for (k, entry) in keyfile.Parameters
        k_str = string(k)
        if k_str ∉ sys_param_names && k ∈ needed_ghosts
            # Skip ghost params with no value (variant-only without selected variant)
            if entry.value === nothing
                @warn "ConfigKit: Ghost parameter '$k' has no value (variant-only) but is referenced by a system expression. Please specify a variant or add a default value."
                continue
            end

            # Create ghost parameter symbol with proper metadata.
            # MTK.toparam marks it as PARAMETER via MTKVariableTypeCtx. Without this,
            # isparameter(sym) returns false, so MTK's completion/initialization treats
            # the ghost as an unknown to solve for. When one ghost binding references
            # another ghost (e.g. k10 = kel_eff + Vmax/Km with Vmax also a ghost binding),
            # that misclassification causes populate() to hang in MTK.complete().
            sym = MTK.toparam(Symbolics.variable(k))
            sym = Symbolics.setmetadata(sym, MTK.VariableSource, (:parameters, k))
            sym = Symbolics.setmetadata(sym, MTK.SymScope, MTK.LocalScope())

            if haskey(unit_map, k)
                sym = Symbolics.setmetadata(sym, MTK.VariableUnit, unit_map[k])
            end
            if haskey(entry.metadata, :description)
                sym = Symbolics.setmetadata(sym, MTK.VariableDescription, entry.metadata[:description])
            end

            ghost_params[k] = sym

            # Try to find any existing symbol with this name (might be independent var or other)
            # and add substitution so equations get updated
            old_sym = find_sys_symbol(k)
            if old_sym !== nothing
                add_sub!(old_sym, sym)
            end
        end
    end

    # 2b. Process existing system parameters (update metadata)
    # Model metadata takes precedence over keyfile metadata
    for (k, entry) in keyfile.Parameters
        if string(k) ∈ sys_param_names
            old_sym = find_sys_symbol(k)
            if old_sym !== nothing
                if Symbolics.iscall(old_sym)
                    op = Symbolics.operation(old_sym)
                    new_op = op

                    # Transfer model metadata first (takes precedence)
                    new_op = transfer_all_metadata(new_op, op)

                    # Only set keyfile metadata if model doesn't already have it
                    if safe_getmetadata(new_op, MTK.VariableUnit, nothing) === nothing && haskey(unit_map, k)
                        new_op = Symbolics.setmetadata(new_op, MTK.VariableUnit, unit_map[k])
                    end
                    if safe_getmetadata(new_op, MTK.VariableDescription, nothing) === nothing && haskey(entry.metadata, :description)
                        new_op = Symbolics.setmetadata(new_op, MTK.VariableDescription, entry.metadata[:description])
                    end

                    args = Symbolics.arguments(old_sym)
                    new_args = [get(meta_subs, a, a) for a in args]

                    new_term = new_op(new_args...)

                    # Transfer model metadata first (takes precedence)
                    new_term = transfer_all_metadata(new_term, old_sym)
                    # Only set keyfile unit if model doesn't already have it
                    if safe_getmetadata(new_term, MTK.VariableUnit, nothing) === nothing && haskey(unit_map, k)
                        new_term = Symbolics.setmetadata(new_term, MTK.VariableUnit, unit_map[k])
                    end

                    add_sub!(old_sym, new_term)
                else
                    new_sym = old_sym

                    # Transfer model metadata first (takes precedence)
                    new_sym = transfer_all_metadata(new_sym, old_sym)

                    # Only set keyfile metadata if model doesn't already have it
                    if safe_getmetadata(new_sym, MTK.VariableUnit, nothing) === nothing && haskey(unit_map, k)
                        new_sym = Symbolics.setmetadata(new_sym, MTK.VariableUnit, unit_map[k])
                    end
                    if safe_getmetadata(new_sym, MTK.VariableDescription, nothing) === nothing && haskey(entry.metadata, :description)
                        new_sym = Symbolics.setmetadata(new_sym, MTK.VariableDescription, entry.metadata[:description])
                    end

                    add_sub!(old_sym, new_sym)
                end
            end
        end
    end

    # 2b-bis. Process constants that match existing system parameters (update metadata)
    # Same logic as 2b above, but for keyfile.Constants entries that correspond
    # to @parameters already declared in the model (e.g., N_Av from @common_constants
    # or plain @parameters). Without this, constants miss unit injection.
    for (k, entry) in keyfile.Constants
        if string(k) ∈ sys_param_names
            old_sym = find_sys_symbol(k)
            if old_sym !== nothing
                if Symbolics.iscall(old_sym)
                    op = Symbolics.operation(old_sym)
                    new_op = op
                    new_op = transfer_all_metadata(new_op, op)
                    if safe_getmetadata(new_op, MTK.VariableUnit, nothing) === nothing && haskey(unit_map, k)
                        new_op = Symbolics.setmetadata(new_op, MTK.VariableUnit, unit_map[k])
                    end
                    if safe_getmetadata(new_op, MTK.VariableDescription, nothing) === nothing && haskey(entry.metadata, :description)
                        new_op = Symbolics.setmetadata(new_op, MTK.VariableDescription, entry.metadata[:description])
                    end
                    args = Symbolics.arguments(old_sym)
                    new_args = [get(meta_subs, a, a) for a in args]
                    new_term = new_op(new_args...)
                    new_term = transfer_all_metadata(new_term, old_sym)
                    if safe_getmetadata(new_term, MTK.VariableUnit, nothing) === nothing && haskey(unit_map, k)
                        new_term = Symbolics.setmetadata(new_term, MTK.VariableUnit, unit_map[k])
                    end
                    add_sub!(old_sym, new_term)
                else
                    new_sym = old_sym
                    new_sym = transfer_all_metadata(new_sym, old_sym)
                    if safe_getmetadata(new_sym, MTK.VariableUnit, nothing) === nothing && haskey(unit_map, k)
                        new_sym = Symbolics.setmetadata(new_sym, MTK.VariableUnit, unit_map[k])
                    end
                    if safe_getmetadata(new_sym, MTK.VariableDescription, nothing) === nothing && haskey(entry.metadata, :description)
                        new_sym = Symbolics.setmetadata(new_sym, MTK.VariableDescription, entry.metadata[:description])
                    end
                    add_sub!(old_sym, new_sym)
                end
            end
        end
    end

    # 3. Process Variables
    # Model metadata takes precedence over keyfile metadata
    for (k, entry) in keyfile.Variables
        old_sym = find_sys_symbol(k)
        if old_sym !== nothing
            if Symbolics.iscall(old_sym)
                op = Symbolics.operation(old_sym)
                new_op = op

                # Transfer model metadata first (takes precedence)
                new_op = transfer_all_metadata(new_op, op)

                # Only set keyfile metadata if model doesn't already have it
                if safe_getmetadata(new_op, MTK.VariableUnit, nothing) === nothing && haskey(unit_map, k)
                    new_op = Symbolics.setmetadata(new_op, MTK.VariableUnit, unit_map[k])
                end
                if safe_getmetadata(new_op, MTK.VariableDescription, nothing) === nothing && haskey(entry.metadata, :description)
                    new_op = Symbolics.setmetadata(new_op, MTK.VariableDescription, entry.metadata[:description])
                end

                if iv !== nothing
                    new_term = new_op(iv)
                else
                    args = Symbolics.arguments(old_sym)
                    new_term = new_op(args...)
                end

                # Transfer model metadata first (takes precedence)
                new_term = transfer_all_metadata(new_term, old_sym)
                # Only set keyfile unit if model doesn't already have it
                if safe_getmetadata(new_term, MTK.VariableUnit, nothing) === nothing && haskey(unit_map, k)
                    new_term = Symbolics.setmetadata(new_term, MTK.VariableUnit, unit_map[k])
                end

                add_sub!(old_sym, new_term)
            else
                new_sym = old_sym

                # Transfer model metadata first (takes precedence)
                new_sym = transfer_all_metadata(new_sym, old_sym)

                # Only set keyfile metadata if model doesn't already have it
                if safe_getmetadata(new_sym, MTK.VariableUnit, nothing) === nothing && haskey(unit_map, k)
                    new_sym = Symbolics.setmetadata(new_sym, MTK.VariableUnit, unit_map[k])
                end
                if safe_getmetadata(new_sym, MTK.VariableDescription, nothing) === nothing && haskey(entry.metadata, :description)
                    new_sym = Symbolics.setmetadata(new_sym, MTK.VariableDescription, entry.metadata[:description])
                end

                add_sub!(old_sym, new_sym)
            end
        end
    end

    # 4. Rebuild System

    # Get independent variable unit for computing derivative units
    iv_unit = haskey(unit_map, Symbol(MTK.getname(iv))) ? unit_map[Symbol(MTK.getname(iv))] : nothing

    new_eqs = Equation[]
    for eq in MTK.equations(system)
        new_lhs = eq.lhs
        new_rhs = substitute(eq.rhs, meta_subs)

        if Symbolics.iscall(eq.lhs) && Symbolics.operation(eq.lhs) isa Differential
            D_op = Symbolics.operation(eq.lhs)
            var = Symbolics.arguments(eq.lhs)[1]
            new_var = get(meta_subs, var, var)
            new_D = Differential(iv)
            new_lhs = new_D(new_var)

            # Set unit on derivative term: unit(D(x)) = unit(x) / unit(t)
            var_name = Symbol(MTK.getname(new_var))
            if haskey(unit_map, var_name) && iv_unit !== nothing
                var_unit = unit_map[var_name]
                if var_unit isa DQ.AbstractQuantity && iv_unit isa DQ.AbstractQuantity
                    deriv_unit = var_unit / iv_unit
                    new_lhs = Symbolics.setmetadata(new_lhs, MTK.VariableUnit, deriv_unit)
                end
            elseif haskey(unit_map, var_name)
                # If no IV unit, at least set variable unit on the derivative
                new_lhs = Symbolics.setmetadata(new_lhs, MTK.VariableUnit, unit_map[var_name])
            end
        else
            new_lhs = substitute(eq.lhs, meta_subs)
        end

        push!(new_eqs, new_lhs ~ new_rhs)
    end

    # Restore algebraic unknowns and bound parameters that mtkcompile eliminates.
    # There are two distinct inputs to populate():
    #   1. Pre-mtkcompile system (iscomplete=false) with user-declared observed=[...]
    #      equations. In that rare case, observed() may mix algebraic eqs and bound
    #      params alongside real observables, and we restore them so that downstream
    #      mtkcompile handles them uniformly. (If the user didn't declare observed,
    #      this path is a no-op — observed() is empty.)
    #   2. Post-mtkcompile system (iscomplete=true). observed() now holds the
    #      algebraic equations mtkcompile moved there as part of simplification.
    #      Moving them BACK into eqs reintroduces `var ~ expr` with non-differentiated
    #      LHS, which MTK rejects when building ODEProblem ("LHS cannot contain
    #      nondifferentiated variables").
    #
    # We only run the restore logic for case 1. For case 2 we leave observed alone
    # and still skip any bound-param identity equations mtkcompile emitted there.
    raw_observed = MTK.observed(system)
    bound_param_names = Set(Symbol(MTK.getname(v)) for v in
        try MTK.bound_parameters(system) catch; [] end)

    sys_is_complete = try MTK.iscomplete(system) catch; false end

    algebraic_eqs = Equation[]
    algebraic_vars = Any[]
    kept_observed = Equation[]
    for eq in raw_observed
        lhs_u = Symbolics.unwrap(eq.lhs)
        lhs_name = Symbol(MTK.getname(eq.lhs))
        if !sys_is_complete && SymbolicUtils.iscall(lhs_u) && !MTK.isdifferential(lhs_u)
            push!(algebraic_eqs, eq)
            push!(algebraic_vars, eq.lhs)
        elseif lhs_name in bound_param_names
            continue  # handled via bindings
        else
            push!(kept_observed, eq)
        end
    end

    new_observed = [substitute(eq, meta_subs) for eq in kept_observed]

    new_unknowns = Any[]
    for u in MTK.unknowns(system)
        push!(new_unknowns, substitute(u, meta_subs))
    end
    for u in algebraic_vars
        push!(new_unknowns, substitute(u, meta_subs))
    end

    new_params = Any[]
    seen_params = Set{String}()

    for p in MTK.parameters(system)
        p_new = substitute(p, meta_subs)
        push!(new_params, p_new)
        push!(seen_params, string(MTK.getname(p_new)))
    end
    # Re-add bound parameters eliminated by mtkcompile
    for p in try MTK.bound_parameters(system) catch; [] end
        p_new = substitute(p, meta_subs)
        p_str = string(MTK.getname(p_new))
        if p_str ∉ seen_params
            push!(new_params, p_new)
            push!(seen_params, p_str)
        end
    end

    # Re-add declared parameters that were only referenced by observed equations
    # and therefore absent from MTK.parameters(system).
    for (p_str, p) in observed_only_params
        if p_str ∉ seen_params
            p_new = substitute(p, meta_subs)
            push!(new_params, p_new)
            push!(seen_params, p_str)
        end
    end

    # Add ghost parameters (using the symbols created earlier, which are already in meta_subs)
    for (k, sym) in ghost_params
        k_str = string(k)
        if k_str ∉ seen_params
            push!(new_params, sym)
            push!(seen_params, k_str)
        end
    end

    # 2c. Create constant parameters ONLY for those that are needed
    # Constants are handled exactly like ghost parameters - same metadata, same unit handling
    # A constant is needed if it's in the needed_ghosts set (referenced by a system expression)
    constant_params = Dict{Symbol, Any}()  # name => new symbol
    for (k, entry) in keyfile.Constants
        k_str = string(k)
        if k_str ∉ seen_params && k ∈ needed_ghosts
            # Create constant parameter symbol with proper metadata (same as ghost parameters).
            # MTK.toparam ensures isparameter(sym) returns true so MTK treats it as a parameter
            # rather than trying to solve for it as an unknown during complete().
            sym = MTK.toparam(Symbolics.variable(k))
            sym = Symbolics.setmetadata(sym, MTK.VariableSource, (:parameters, k))
            sym = Symbolics.setmetadata(sym, MTK.SymScope, MTK.LocalScope())

            # Use unit_map (populated in Phase 0) for consistent unit handling
            if haskey(unit_map, k)
                sym = Symbolics.setmetadata(sym, MTK.VariableUnit, unit_map[k])
            end
            if haskey(entry.metadata, :description)
                sym = Symbolics.setmetadata(sym, MTK.VariableDescription, entry.metadata[:description])
            end

            constant_params[k] = sym
            push!(new_params, sym)
            push!(seen_params, k_str)

            @debug "ConfigKit: Created constant parameter '$k' with value $(entry.value)"
        end
    end

    # Include algebraic equations (restored from observed) in the equation list
    new_algebraic_eqs = [substitute(eq, meta_subs) for eq in algebraic_eqs]
    all_eqs = vcat(new_eqs, new_algebraic_eqs)

    system = MTK.System(all_eqs, iv, new_unknowns, new_params;
        name=MTK.getname(system),
        observed=new_observed,
        bindings=try MTK.bindings(system) catch; Dict() end,
        guesses=try MTK.guesses(system) catch; Dict() end,
        checks=false
    )

    # =======================================================
    # PHASE 3: Value Population
    # =======================================================

    new_bindings = try Dict{Any,Any}(MTK.get_bindings(system)) catch; Dict{Any,Any}() end
    new_ics = try Dict{Any,Any}(MTK.get_initial_conditions(system)) catch; Dict{Any,Any}() end
    new_guesses = try Dict{Any,Any}(MTK.get_guesses(system)) catch; Dict{Any,Any}() end
    new_init_eqs = Equation[]  # For solve_for targets (initialization equations)

    # Build name_map and eval_module for expression parsing
    name_map = Dict{Symbol, Any}()
    eval_module = Module()

    # Add required modules and macros for expression parsing
    Core.eval(eval_module, :(const Unitful = $Unitful))
    Core.eval(eval_module, :(const MTK = $MTK))
    Core.eval(eval_module, :(const Symbolics = $Symbolics))
    Core.eval(eval_module, :(const var"@u_str" = $Unitful.var"@u_str"))

    # Add all parameters and unknowns to name_map
    for p in MTK.parameters(system)
        name_map[Symbol(MTK.getname(p))] = p
    end
    for v in MTK.unknowns(system)
        name_map[Symbol(MTK.getname(v))] = v
    end

    # For keyfile entries not yet in name_map, resolve via parse_variable
    for (k, _) in keyfile.Parameters
        if !haskey(name_map, k)
            parsed = try MTK.parse_variable(system, string(k)) catch; nothing end
            if parsed !== nothing
                name_map[k] = parsed
            end
        end
    end
    for (k, _) in keyfile.Variables
        if !haskey(name_map, k)
            parsed = try MTK.parse_variable(system, string(k)) catch; nothing end
            if parsed !== nothing
                name_map[k] = parsed
            end
        end
    end

    # Bind Num objects to their names in eval_module for parse_expr_to_symbolic
    for (name, sym) in name_map
        Core.eval(eval_module, :($name = $sym))
    end

    # Parse string expression to symbolic using the Num objects from name_map
    function parse_string_to_symbolic(str_val)
        expr = Meta.parse(str_val)
        return Symbolics.parse_expr_to_symbolic(expr, eval_module)
    end

    # Try to evaluate a string as a pure numeric expression (e.g., "0.105/7.0")
    # Returns the numeric result if successful, nothing if it contains symbols
    function try_eval_pure_numeric(str_val::String)
        try
            parsed = Meta.parse(str_val)
            # Evaluate in a completely fresh/empty module - only Base operations available
            result = Core.eval(Module(), parsed)
            if result isa Number
                return result
            end
        catch
            # UndefVarError means it contains symbols - not purely numeric
        end
        return nothing
    end

    # Helper: Try to evaluate expression numerically using current IC values
    # Returns numeric result if successful, nothing if evaluation requires symbolic bindings
    function try_evaluate_numeric(expr_str::String, ics::Dict)
        try
            # Build a module with all numeric values for evaluation
            num_module = Module()
            Core.eval(num_module, :(using Base))

            # Bind all IC values (keyed by symbol name)
            for (sym, val) in ics
                if val isa Number
                    sym_name = Symbol(MTK.getname(sym))
                    Core.eval(num_module, :($sym_name = $val))
                end
            end

            # Parse and evaluate the expression
            parsed_expr = Meta.parse(expr_str)
            result = Core.eval(num_module, parsed_expr)

            # Only return if result is actually numeric
            if result isa Number
                return result
            else
                return nothing
            end
        catch
            # If evaluation fails for any reason, return nothing to trigger binding fallback
            return nothing
        end
    end

    function process_entry!(target_obj, entry, name_str, is_system_param::Bool; is_algebraic::Bool = false)
        has_override = haskey(overrides, name_str)

        # Cannot override expression-valued parameters
        if has_override && haskey(entry.metadata, :expression)
            error("ConfigKit: Cannot override expression-valued parameter '$name_str'. " *
                  "Expression: '$(entry.metadata[:expression])'. " *
                  "Override the underlying parameters instead.")
        end

        effective_value = has_override ? overrides[name_str] : entry.value

        # Handle entries with no value (variant-only without selected variant)
        if effective_value === nothing
            if is_system_param
                # System parameters MUST have a value - error with helpful message
                error("ConfigKit: Parameter '$name_str' has no default value (only variants). " *
                      "Please either:\n" *
                      "  1. Specify a variant when calling populate(): populate(sys, keyfile; variant=:invitro)\n" *
                      "  2. Add a default 'value:' field in the keyfile for '$name_str'")
            else
                # Ghost parameters can be skipped if they have no value
                @debug "ConfigKit: Skipping ghost '$name_str' - no value (variant-only without selected variant)"
                return
            end
        end

        # Units are stored in symbol metadata (VariableUnit), not attached to values.
        # Strip units from values if they come in as Quantity types.
        if effective_value isa DQ.AbstractQuantity
            effective_value = DQ.ustrip(effective_value)
        end

        # Apply unit conversion if 'convert' field is specified
        # This converts the value from its declared 'unit' to the 'convert' target unit
        # e.g., value: 0.1, unit: hr, convert: s → effective_value = 0.1 * 3600 = 360
        if haskey(entry.metadata, :convert)
            target_unit_str = string(entry.metadata[:convert])

            if effective_value isa String
                # Expression-valued parameter - conversion doesn't apply
                @warn "ConfigKit: Parameter '$name_str' has 'convert: $target_unit_str' but value is an expression. " *
                      "Unit conversion is only applied to numeric values. The conversion will be ignored."
            elseif effective_value isa Number && !isempty(target_unit_str)
                # Check if source unit has dimensions (not dimensionless)
                source_has_dims = entry.unit !== nothing && !isempty(string(DQ.dimension(entry.unit)))

                if source_has_dims
                    try
                        target_unit = getMTKUnit(target_unit_str)
                        # entry.unit and target_unit are both DQ.Quantity with magnitude 1.0
                        # Dividing them gives the conversion factor (e.g., 1.0 hr / 1.0 s = 3600)
                        conversion_factor = DQ.ustrip(entry.unit / target_unit)
                        effective_value = effective_value * conversion_factor
                        @debug "ConfigKit: Converted '$name_str' from $(entry.unit) to $target_unit_str (factor: $conversion_factor)"
                    catch e
                        @warn "ConfigKit: Failed to convert '$name_str' from $(entry.unit) to $target_unit_str: $e"
                    end
                else
                    @warn "ConfigKit: Cannot convert '$name_str' to '$target_unit_str' - no source unit specified. " *
                          "Add 'unit:' field to enable conversion."
                end
            end
        end

        # Handle explicit guesses from keyfile
        if !has_override && haskey(entry.metadata, :guess) && !isnothing(entry.metadata[:guess])
            new_guesses[target_obj] = entry.metadata[:guess]
        end

        if get(entry.metadata, :is_implicit, false)
            # Implicit parameter - skip
        elseif effective_value isa String
            # First check if this is a pure numeric expression (e.g., "0.105/7.0")
            # These should be evaluated to numbers, not treated as symbolic bindings
            pure_numeric_result = try_eval_pure_numeric(effective_value)

            if pure_numeric_result !== nothing
                # Pure numeric expression → evaluate and use as initial condition
                if is_algebraic
                    # Algebraic variables: skip entirely (values come from equations)
                    delete!(new_ics, target_obj)
                    @debug "ConfigKit: Algebraic variable '$name_str' - skipping (value computed from equation)"
                else
                    new_ics[target_obj] = pure_numeric_result
                    @debug "ConfigKit: Parameter '$name_str' evaluated pure numeric expression '$effective_value' = $pure_numeric_result"
                end
            else
                # Expression with symbols
                if is_algebraic
                    # Algebraic variables: skip entirely (values come from equations)
                    delete!(new_ics, target_obj)
                    @debug "ConfigKit: Algebraic variable '$name_str' - skipping (value computed from equation)"
                else
                    # Non-algebraic: symbolic binding (computed on the fly by MTK)
                    # This preserves the dependency relationship so update() propagates changes
                    sym_expr = parse_string_to_symbolic(effective_value)
                    new_bindings[target_obj] = sym_expr

                    # Also add a numeric guess to help MTK's initialization system
                    # Without a guess, initialization may try to solve for this parameter and fail
                    numeric_guess = try_evaluate_numeric(effective_value, new_ics)
                    if numeric_guess !== nothing
                        new_guesses[target_obj] = numeric_guess
                        @debug "ConfigKit: Parameter '$name_str' bound to expression with guess: $numeric_guess"
                    else
                        @debug "ConfigKit: Parameter '$name_str' bound to expression: $sym_expr (no numeric guess available)"
                    end
                end
            end
        else
            # Numeric value → initial condition
            if is_algebraic
                # Algebraic variables: skip entirely (values come from equations)
                delete!(new_ics, target_obj)
                @debug "ConfigKit: Algebraic variable '$name_str' - skipping (value computed from equation)"
            else
                new_ics[target_obj] = effective_value
            end
        end
    end

    # PHASE 3a: Process all parameters
    for (name_sym, entry) in keyfile.Parameters
        target_obj = get(name_map, name_sym, nothing)
        if target_obj !== nothing
            # Check if this is an original system parameter (not a ghost)
            # Use namespace-aware matching (handles subsystem₊param matching param)
            is_sys_param = name_in_set(string(name_sym), sys_param_names)
            process_entry!(target_obj, entry, string(name_sym), is_sys_param)
        end
    end

    # PHASE 3b: Process variables
    # - Differential variables (with D(var) ~ ... equations) get Initial() conditions
    # - Algebraic variables (have var ~ ... equation without D()) get guesses, NOT Initial()
    # - Observed variables (not in unknowns) get guesses to help initialization solver
    #
    # CRITICAL: We use algebraic_var_names_from_eqs (built by scanning equations) as the
    # primary source. This works whether populate() is called BEFORE or AFTER mtkcompile().
    algebraic_var_names = Set{String}()  # Track algebraic variables for IC cleanup

    # Start with all algebraic variables found by scanning equations
    union!(algebraic_var_names, algebraic_var_names_from_eqs)

    for (name_sym, entry) in keyfile.Variables
        target_obj = get(name_map, name_sym, nothing)
        if target_obj !== nothing
            name_str = string(name_sym)
            # Use name_in_set for namespace-aware matching (handles subsystem₊var matching var)
            is_in_unknowns = name_in_set(name_str, sys_unknown_names)
            is_differential = name_in_set(name_str, differential_var_names)
            # Check if found in algebraic equations (primary method - works before/after mtkcompile)
            is_in_algebraic_eqs = name_in_set(name_str, algebraic_var_names_from_eqs)

            # Determine if this variable should get Initial() or guess:
            # - If found in algebraic equations → algebraic (needs guess)
            # - If NOT differential AND NOT in unknowns → algebraic (needs guess)
            # - Only differential state variables get Initial()
            is_algebraic = is_in_algebraic_eqs || !is_differential || !is_in_unknowns

            if is_algebraic
                push!(algebraic_var_names, name_str)
            end

            if is_in_algebraic_eqs
                @debug "ConfigKit: Variable '$name_str' found in algebraic equation - using guess instead of Initial()"
            elseif !is_in_unknowns
                @debug "ConfigKit: Variable '$name_str' is observed (not in unknowns) - using guess instead of Initial()"
            elseif !is_differential
                @debug "ConfigKit: Variable '$name_str' is in unknowns but no D($name_str) equation - using guess instead of Initial()"
            end

            process_entry!(target_obj, entry, name_str, is_in_unknowns; is_algebraic=is_algebraic)
        else
            # Variable not found in name_map - still track for IC cleanup if algebraic
            name_str = string(name_sym)
            is_in_algebraic_eqs = name_in_set(name_str, algebraic_var_names_from_eqs)
            if is_in_algebraic_eqs || !name_in_set(name_str, sys_unknown_names)
                push!(algebraic_var_names, name_str)
                @debug "ConfigKit: Variable '$name_str' not in name_map but is algebraic - tracking for IC cleanup"
            end
        end
    end

    # Clean up any remaining ICs and bindings for algebraic variables
    # This handles cases where delete! failed due to symbolic object identity mismatch
    if !isempty(algebraic_var_names)
        # Clean up ICs
        keys_to_delete = Any[]
        for k in keys(new_ics)
            k_name = string(MTK.getname(k))
            # Check both exact match and suffix match (for namespaced variables like subsystem₊rate_constant)
            if k_name ∈ algebraic_var_names || any(av -> endswith(k_name, "₊" * av) || endswith(k_name, "." * av), algebraic_var_names)
                push!(keys_to_delete, k)
                @debug "ConfigKit: Removing IC for algebraic variable '$k_name' (cleanup pass)"
            end
        end
        for k in keys_to_delete
            delete!(new_ics, k)
        end

        # Clean up bindings - algebraic/observed variables should not have bindings
        # as they already have their equation in the observed section
        keys_to_delete = Any[]
        for k in keys(new_bindings)
            k_name = string(MTK.getname(k))
            if k_name ∈ algebraic_var_names || any(av -> endswith(k_name, "₊" * av) || endswith(k_name, "." * av), algebraic_var_names)
                push!(keys_to_delete, k)
                @debug "ConfigKit: Removing binding for algebraic variable '$k_name' (cleanup pass)"
            end
        end
        for k in keys_to_delete
            delete!(new_bindings, k)
        end
    end

    # PHASE 3c: Process constants (set their fixed values)
    # Handle both ghost constants (in constant_params) and constants that match
    # existing system parameters (declared as @parameters in the model).
    for (name_sym, entry) in keyfile.Constants
        const_value = entry.value
        if const_value isa DQ.AbstractQuantity
            const_value = DQ.ustrip(const_value)
        end

        # Check if it's a ghost constant (created in 2c)
        if haskey(constant_params, name_sym)
            sym = constant_params[name_sym]
            new_ics[sym] = const_value
            @debug "ConfigKit: Set ghost constant '$name_sym' = $const_value"
        else
            # Check if it matches an existing system parameter
            target_obj = get(name_map, name_sym, nothing)
            if target_obj !== nothing && name_in_set(string(name_sym), sys_param_names)
                new_bindings[target_obj] = const_value
                @debug "ConfigKit: Set system constant '$name_sym' = $const_value"
            end
        end
    end

    function has_model_default(sym)
        default = try
            Symbolics.getdefaultval(sym)
        catch
            nothing
        end
        return default !== nothing
    end

    for name_str in keys(observed_only_params)
        name_sym = Symbol(name_str)
        target_obj = get(name_map, name_sym, nothing)
        target_obj === nothing && continue
        if !haskey(new_ics, target_obj) && !haskey(new_bindings, target_obj) && !has_model_default(target_obj)
            outputs = unique(get(observed_only_param_outputs, name_str, Symbol[]))
            new_ics[target_obj] = RequiredRuntimeParameter(name_sym, outputs)
        end
    end

    # =======================================================
    # PHASE 4: Process solve_for pairs (initialization system)
    # =======================================================
    for pair in solve_for
        target, adjustable_params = pair

        # 1. Get the equation (validate target)
        local target_sym, eq_expr

        if target isa Symbol
            # Look up expression from keyfile
            if !haskey(keyfile.Parameters.data, target)
                error("ConfigKit: solve_for target '$target' not found in keyfile Parameters.")
            end
            entry = keyfile.Parameters.data[target]
            if !(entry.value isa String)
                error("ConfigKit: solve_for target '$target' has no expression to solve (value is numeric: $(entry.value)). " *
                      "Only expression-valued parameters can be targets. " *
                      "Either provide a custom equation as a String, or use a parameter with an expression value.")
            end
            eq_expr = parse_string_to_symbolic(entry.value)
            target_sym = get(name_map, target, nothing)
            if target_sym === nothing
                error("ConfigKit: solve_for target '$target' not found in system.")
            end
        else
            # Parse custom equation (String or Expr)
            eq_str = target isa String ? target : string(target)
            parsed = Meta.parse(eq_str)

            # Extract target symbol and expression from equation (e.g., :(k_el ~ CL / V))
            if !(parsed isa Expr) || parsed.head != :call || parsed.args[1] != :(~) || length(parsed.args) != 3
                error("ConfigKit: solve_for custom equation must be in format 'target ~ expression', got: '$eq_str'")
            end

            target_name = parsed.args[2]
            if !(target_name isa Symbol)
                error("ConfigKit: solve_for target in equation must be a symbol, got: $(target_name)")
            end

            target_sym = get(name_map, target_name, nothing)
            if target_sym === nothing
                error("ConfigKit: solve_for target '$target_name' from equation not found in system.")
            end

            eq_expr = Symbolics.parse_expr_to_symbolic(parsed.args[3], eval_module)
        end

        # 2. Validate adjustable params have NUMERIC values (not expressions)
        for p in adjustable_params
            if haskey(keyfile.Parameters.data, p)
                entry = keyfile.Parameters.data[p]
                if entry.value isa String
                    error("ConfigKit: Cannot adjust '$p' in solve_for - it has expression value '$(entry.value)'. " *
                          "Adjustable parameters must have numeric values (used as guesses for the solver). " *
                          "Either include its numeric dependencies in the adjustable list, " *
                          "or add '$p' as another solve_for target.")
                end
            end
        end

        # 3. Add target to init system
        push!(new_init_eqs, target_sym ~ eq_expr)
        new_bindings[target_sym] = missing  # Will be solved during initialization
        delete!(new_ics, target_sym)  # Remove from ICs if it was there

        # 4. Compute an initial guess for the target by substituting adjustable param values
        # This prevents "cyclic guesses" errors in MTK's initialization solver
        guess_subs = Dict{Any,Any}()
        for p in adjustable_params
            p_sym = get(name_map, p, nothing)
            if p_sym !== nothing && haskey(keyfile.Parameters.data, p)
                entry = keyfile.Parameters.data[p]
                guess_val = entry.value
                if guess_val isa DQ.AbstractQuantity
                    guess_val = DQ.ustrip(guess_val)
                end
                if !(guess_val isa String)  # Only use numeric values
                    guess_subs[p_sym] = guess_val
                end
            end
        end

        if !isempty(guess_subs)
            try
                target_guess = Symbolics.substitute(eq_expr, guess_subs)
                target_guess_val = Symbolics.value(target_guess)
                if target_guess_val isa Number
                    new_guesses[target_sym] = target_guess_val
                    @debug "ConfigKit: Computed guess for $target_sym = $target_guess_val"
                end
            catch e
                @debug "ConfigKit: Could not compute guess for $target_sym: $e"
            end
        end

        # 5. Process adjustable params: bind to missing, use keyfile values as guesses
        for p in adjustable_params
            p_sym = get(name_map, p, nothing)
            if p_sym === nothing
                error("ConfigKit: solve_for adjustable parameter '$p' not found in system.")
            end

            # Get numeric value from keyfile for guess
            if haskey(keyfile.Parameters.data, p)
                entry = keyfile.Parameters.data[p]
                guess_val = entry.value
                if guess_val isa DQ.AbstractQuantity
                    guess_val = DQ.ustrip(guess_val)
                end
                new_guesses[p_sym] = guess_val
            elseif haskey(new_ics, p_sym)
                new_guesses[p_sym] = new_ics[p_sym]
            end

            # Bind to missing (solver will determine final value)
            new_bindings[p_sym] = missing
            delete!(new_ics, p_sym)
        end

        @debug "ConfigKit: solve_for added initialization equation: $target_sym ~ $eq_expr, adjustable: $adjustable_params"
    end

    # Reconstruct system with all populated values
    # We need to do this because @set! doesn't work reliably with MTK's System struct
    system = MTK.System(
        MTK.equations(system),
        iv,
        MTK.unknowns(system),
        MTK.parameters(system);
        name=MTK.getname(system),
        observed=MTK.observed(system),
        bindings=new_bindings,
        initial_conditions=new_ics,
        guesses=new_guesses,
        initialization_eqs=new_init_eqs,
        checks=false
    )

    sys_completed = MTK.complete(system)

    # =======================================================
    # PHASE 4: Validation
    # =======================================================
    if strict
        @info "ConfigKit: Validating system units and structure..."

        validate_dict_units(new_ics, "Initial Condition")
        validate_dict_units(new_bindings, "Parameter Binding")

        eqs = MTK.equations(sys_completed)
        is_valid = MTK.validate(eqs)

        if is_valid !== false
            init_eqs = MTK.get_initialization_eqs(sys_completed)
            if !isempty(init_eqs)
                is_valid_init = MTK.validate(init_eqs; info=" (initialization)")
                if is_valid_init === false; is_valid = false; end
            end
        end

        if is_valid === false
            error("ConfigKit: System validation failed. See warnings above.")
        elseif is_valid === nothing
            @warn "ConfigKit: System validation skipped (MTK.validate returned nothing)."
        end
    end

    # Cache for downstream consumers that need the pre-compiled system.
    cache_populated_system!(sys_completed)

    return sys_completed
end

function validate_dict_units(dict, context_name)
    for (var, val) in dict
        # Only validate if value has units attached (e.g., from an override)
        # Plain numbers are assumed to be in the correct units per metadata
        if val isa DQ.AbstractQuantity
            var_sym = Symbolics.unwrap(var)
            var_unit = Symbolics.getmetadata(var_sym, MTK.VariableUnit, nothing)

            if var_unit !== nothing && var_unit isa DQ.AbstractQuantity
                val_dim = DQ.dimension(val)
                var_dim = DQ.dimension(var_unit)

                if val_dim != var_dim
                    error("ConfigKit: Unit mismatch in $context_name for '$(MTK.getname(var))'. Variable requires dimensions $(var_dim) (unit: $var_unit), but assigned value has dimensions $(val_dim) (value: $val).")
                end
            end
        end
    end
end

# ------------------------------------------------------------------
# CONVENIENCE METHODS
# ------------------------------------------------------------------
function populate(
    system::MTK.AbstractSystem,
    keyfile_path::String;
    variant::Union{Symbol, String, Nothing} = nothing,
    overrides::Dict = Dict(),
    strict::Bool = true,
    solve_for::Vector = Pair[],
)
    keyfile = load_keyfile(keyfile_path; variant, strict)
    return populate(system, keyfile; variant, overrides, strict, solve_for)
end

function populate!(prob::SciMLBase.ODEProblem, keyfile::KeyfileAccessor; strict::Bool = true)
    updates = Dict{Any, Any}()
    merge!(updates, keyfile.parameter_defaults)
    merge!(updates, keyfile.variable_initials)
    return update(prob, updates; strict)
end
