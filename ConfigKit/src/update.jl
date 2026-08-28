# Update Utilities for MTK v11+
# Lightweight wrappers around standard SciMLBase/MTK functions.

using LRUCache: LRU
using SciMLStructures: Tunable, canonicalize, replace

# --- Setter Cache ---

const _SETTER_CACHE = LRU{UInt64, Tuple{UInt64, Any, Vector{Any}, Any}}(maxsize=128)
const _SETTER_CACHE_LOCK = ReentrantLock()

struct _UpdatePlan
    token::UInt64
    sys::Any
    raw_keys::Tuple
    strict::Bool
    valid_indices::Vector{Int}
    valid_keys::Vector{Any}
    valid_param_indices::Vector{Int}
    valid_param_keys::Vector{Any}
    valid_state_indices::Vector{Int}
    valid_state_keys::Vector{Any}
    valid_state_initial_keys::Vector{Any}
    plain_tunable::Bool
    setter::Any
    state_setter::Any
    initial_sync_entries::Vector{Tuple{Any, Any}}
end

mutable struct UpdateCache
    prob::SciMLBase.ODEProblem
    plan::_UpdatePlan
    base_tunable::Any
    tunable_buffer::Any
    base_u0::Any
    u0_buffer::Any
    valid_values::Vector{Any}
    sync_keys::Vector{Any}
    sync_values::Vector{Any}
    borrow_lock::ReentrantLock
end

const _UPDATE_PLAN_CACHE = LRU{UInt64, _UpdatePlan}(maxsize=256)
const _UPDATE_PLAN_CACHE_LOCK = ReentrantLock()

const _INITIAL_DEPENDENCY_CACHE = LRU{UInt64, Tuple{UInt64, Any, Tuple{Vararg{Symbol}}, Bool}}(maxsize=256)
const _INITIAL_DEPENDENCY_CACHE_LOCK = ReentrantLock()

const _THREAD_UPDATE_CACHE = LRU{UInt64, UpdateCache}(maxsize=1024)
const _THREAD_UPDATE_CACHE_LOCK = ReentrantLock()

"""
    PreparedUpdateSource

Process-local metadata describing an `ODEProblem` created by ConfigKit's
tracked update path. Retrieve it with [`prepared_update_source`](@ref); callers
should treat its fields as read-only optimization metadata.
"""
struct PreparedUpdateSource
    base_prob::Any
    updated_prob::Any
    raw_keys::Tuple
    raw_values::Tuple
    strict::Bool
    tspan::Tuple{Float64, Float64}
end

const _PREPARED_UPDATE_SOURCE_CACHE = LRU{UInt64, PreparedUpdateSource}(maxsize=4096)
const _PREPARED_UPDATE_SOURCE_CACHE_LOCK = ReentrantLock()

function _prepared_update_source_key(prob::SciMLBase.ODEProblem)
    return hash((:prepared_update_source, objectid(prob)))
end

function _register_prepared_update_source(updated_prob::SciMLBase.ODEProblem,
                                          base_prob::SciMLBase.ODEProblem,
                                          raw_keys, raw_values;
                                          strict::Bool,
                                          kwargs...)
    haskey(kwargs, :u0) && return updated_prob
    entry = PreparedUpdateSource(
        base_prob,
        updated_prob,
        Tuple(raw_keys),
        Tuple(raw_values),
        strict,
        (Float64(updated_prob.tspan[1]), Float64(updated_prob.tspan[2])),
    )
    key = _prepared_update_source_key(updated_prob)
    lock(_PREPARED_UPDATE_SOURCE_CACHE_LOCK) do
        _PREPARED_UPDATE_SOURCE_CACHE[key] = entry
    end
    return updated_prob
end

"""
    prepared_update_source(prob)

Return update-origin metadata for an `ODEProblem` produced by ConfigKit's update
path, or `nothing` if the problem did not come from a tracked update. This lets
other QSPKit packages recover the original update keys and values for prepared
update/event execution while keeping `update`'s public return type unchanged.
"""
function prepared_update_source(prob::SciMLBase.ODEProblem)
    key = _prepared_update_source_key(prob)
    return lock(_PREPARED_UPDATE_SOURCE_CACHE_LOCK) do
        entry = get(_PREPARED_UPDATE_SOURCE_CACHE, key, nothing)
        entry isa PreparedUpdateSource && entry.updated_prob === prob ? entry : nothing
    end
end

function _mtk_system(prob)
    sys = hasproperty(prob.f, :sys) ? prob.f.sys : nothing
    sys === nothing &&
        error("ConfigKit.update requires an MTK-backed ODEProblem; plain SciML ODEProblem inputs are unsupported.")
    return sys
end

"""
    _problem_cache_token(prob)

Return a compact token for the symbolic indexing layout used by `prob`.
The cached setter is only valid for the problem/system shape it was built
against; the same symbolic key names can refer to different buffer slots in
another compiled MTK problem.
"""
function _problem_cache_token(prob)
    h = hash(typeof(prob.f), UInt64(0x9e3779b97f4a7c15))

    sys = _mtk_system(prob)
    h = hash(objectid(sys), h)

    ps = parameter_values(prob)
    tunable, = canonicalize(Tunable(), ps)
    h = hash((typeof(ps), length(tunable)), h)

    return h
end

"""
    _cache_key(prob, keys)

Compute a cache key from the problem layout token and resolved symbolic keys.
Keys passed here are already resolved to their canonical form by `_resolve_and_filter`.
"""
function _cache_key(prob, keys)
    h = _problem_cache_token(prob)
    for k in keys
        h = hash(k, h)
    end
    return h
end

"""
    _cached_setp(prob, keys)

Return a cached `setp` setter for the given keys, creating one if not found.
Verifies stored keys match on cache hit to guard against hash collisions.
"""
function _cached_setp(prob, keys)
    sys = _mtk_system(prob)
    token = _problem_cache_token(prob)
    ck = _cache_key(prob, keys)

    lock(_SETTER_CACHE_LOCK) do
        entry = get(_SETTER_CACHE, ck, nothing)
        if entry !== nothing
            cached_token, cached_sys, cached_keys, setter = entry
            if cached_token == token &&
               cached_sys === sys &&
               length(cached_keys) == length(keys) &&
               all(isequal(a, b) for (a, b) in zip(cached_keys, keys))
                return setter
            end
        end
    end

    setter = setp(prob, keys)
    return lock(_SETTER_CACHE_LOCK) do
        entry = get(_SETTER_CACHE, ck, nothing)
        if entry !== nothing
            cached_token, cached_sys, cached_keys, cached_setter = entry
            if cached_token == token &&
               cached_sys === sys &&
               length(cached_keys) == length(keys) &&
               all(isequal(a, b) for (a, b) in zip(cached_keys, keys))
                return cached_setter
            end
        end
        _SETTER_CACHE[ck] = (token, sys, collect(Any, keys), setter)
        return setter
    end
end

function _plan_cache_key(token::UInt64, raw_keys, strict::Bool)
    h = hash(strict, token)
    for k in raw_keys
        h = hash(k, h)
    end
    return h
end

function _same_raw_keys(a::Tuple, b)
    length(a) == length(b) || return false
    for (x, y) in zip(a, b)
        isequal(x, y) || return false
    end
    return true
end

function _initial_sync_entries(prob)
    sys = _mtk_system(prob)
    entries = Tuple{Any, Any}[]
    for var in MTK.unknowns(sys)
        initial_key = try MTK.Initial(var) catch; nothing end
        initial_key === nothing && continue
        parameter_index(prob, initial_key) === nothing && continue
        push!(entries, (var, initial_key))
    end
    return entries
end

function _resolve_update_entry(prob, k; strict::Bool=true)
    sys = _mtk_system(prob)
    real_key = k
    resolved = _resolve_to_num(sys, k)
    if resolved !== nothing
        real_key = resolved
    end

    if variable_index(prob, real_key) !== nothing
        initial_key = try MTK.Initial(real_key) catch; nothing end
        if initial_key !== nothing && parameter_index(prob, initial_key) !== nothing
            return (:state, real_key, initial_key, true)
        end
        @debug "Skipping state '$k' because no Initial(...) parameter is available"
        return (:invalid, nothing, nothing, false)
    end

    if parameter_index(prob, real_key) !== nothing
        return (:param, real_key, real_key, true)
    end

    initial_key = try MTK.Initial(real_key) catch; nothing end
    if initial_key !== nothing && parameter_index(prob, initial_key) !== nothing
        return (:param, initial_key, initial_key, true)
    end

    (is_bound, expr) = _is_binding(sys, real_key)
    if is_bound
        strict && throw(BindingUpdateError(k, expr))
        @debug "Skipping binding '$k'"
    else
        @debug "Skipping ghost parameter '$k'"
    end
    return (:invalid, nothing, nothing, false)
end

function _build_update_plan(prob, raw_keys::Tuple, strict::Bool, token::UInt64, sys)
    valid_indices = Int[]
    valid_keys = Any[]
    valid_param_indices = Int[]
    valid_param_keys = Any[]
    valid_state_indices = Int[]
    valid_state_keys = Any[]
    valid_state_initial_keys = Any[]

    for i in eachindex(raw_keys)
        kind, resolved_key, initial_key, is_valid = _resolve_update_entry(prob, raw_keys[i]; strict)
        is_valid || continue
        push!(valid_indices, i)
        if kind === :state
            push!(valid_state_indices, i)
            push!(valid_state_keys, resolved_key)
            push!(valid_state_initial_keys, initial_key)
            if initial_key !== nothing && parameter_index(prob, initial_key) !== nothing
                push!(valid_keys, initial_key)
            end
        else
            push!(valid_param_indices, i)
            push!(valid_param_keys, resolved_key)
            push!(valid_keys, resolved_key)
        end
    end

    plain_tunable = isempty(valid_keys) || _keys_are_plain_tunable_parameters(prob, valid_keys)
    setter = isempty(valid_keys) ? nothing : setp(prob, valid_keys)
    state_setter = isempty(valid_state_keys) ? nothing : setu(prob, valid_state_keys)
    return _UpdatePlan(token, sys, raw_keys, strict, valid_indices, valid_keys,
        valid_param_indices, valid_param_keys, valid_state_indices,
        valid_state_keys, valid_state_initial_keys, plain_tunable, setter,
        state_setter, _initial_sync_entries(prob))
end

function _get_update_plan(prob, raw_keys; strict::Bool)
    raw_tuple = Tuple(raw_keys)
    sys = _mtk_system(prob)
    token = _problem_cache_token(prob)
    ck = _plan_cache_key(token, raw_tuple, strict)

    lock(_UPDATE_PLAN_CACHE_LOCK) do
        entry = get(_UPDATE_PLAN_CACHE, ck, nothing)
        if entry !== nothing && entry.token == token && entry.sys === sys &&
           entry.strict == strict &&
           _same_raw_keys(entry.raw_keys, raw_tuple)
            return entry
        end
    end

    plan = _build_update_plan(prob, raw_tuple, strict, token, sys)
    return lock(_UPDATE_PLAN_CACHE_LOCK) do
        entry = get(_UPDATE_PLAN_CACHE, ck, nothing)
        if entry !== nothing && entry.token == token && entry.sys === sys &&
           entry.strict == strict &&
           _same_raw_keys(entry.raw_keys, raw_tuple)
            return entry
        end
        _UPDATE_PLAN_CACHE[ck] = plan
        return plan
    end
end

function _dependency_symbol_name(key)
    try
        return Symbol(MTK.getname(key))
    catch
    end
    key isa Symbol && return key
    key isa AbstractString && return Symbol(key)
    return Symbol(string(key))
end

function _binding_name_map(sys)
    bindings = try
        MTK.get_bindings(sys)
    catch
        Dict{Any, Any}()
    end
    out = Dict{Symbol, Any}()
    for (key, value) in bindings
        out[_dependency_symbol_name(key)] = value
    end
    return out
end

function _expr_depends_on_names(expr, names::Set{Symbol}, bindings::Dict{Symbol, Any},
                                seen::Set{Symbol}=Set{Symbol}())
    expr isa Number && return false
    name = _dependency_symbol_name(expr)
    name in names && return true
    if haskey(bindings, name) && !(name in seen)
        push!(seen, name)
        _expr_depends_on_names(bindings[name], names, bindings, seen) && return true
    end

    vars = try
        Symbolics.get_variables(expr)
    catch
        Any[]
    end
    for var in vars
        var_name = _dependency_symbol_name(var)
        var_name in names && return true
        if haskey(bindings, var_name) && !(var_name in seen)
            push!(seen, var_name)
            _expr_depends_on_names(bindings[var_name], names, bindings, seen) && return true
        end
    end
    return false
end

function _initials_depend_on_names(prob, names_tuple::Tuple{Vararg{Symbol}})
    isempty(names_tuple) && return false
    names = Set(names_tuple)
    sys = _mtk_system(prob)
    bindings = _binding_name_map(sys)
    initial_conditions = try
        MTK.get_initial_conditions(sys)
    catch
        Dict{Any, Any}()
    end
    for value in values(initial_conditions)
        _expr_depends_on_names(value, names, bindings) && return true
    end
    for var in MTK.unknowns(sys)
        var_name = _dependency_symbol_name(var)
        if haskey(bindings, var_name)
            _expr_depends_on_names(bindings[var_name], names, bindings) && return true
        end
    end
    return false
end

function _initial_dependency_cache_key(prob, names_tuple::Tuple{Vararg{Symbol}})
    h = hash(:initial_dependency, _problem_cache_token(prob))
    for name in names_tuple
        h = hash(name, h)
    end
    return h
end

function update_keys_affect_initials(prob::SciMLBase.ODEProblem, raw_keys; strict::Bool=true)
    plan = _get_update_plan(prob, raw_keys; strict)
    isempty(plan.valid_param_keys) && return false
    names_tuple = Tuple(sort!([_dependency_symbol_name(key) for key in plan.valid_param_keys]))
    token = _problem_cache_token(prob)
    sys = _mtk_system(prob)
    ck = _initial_dependency_cache_key(prob, names_tuple)

    cached = lock(_INITIAL_DEPENDENCY_CACHE_LOCK) do
        entry = get(_INITIAL_DEPENDENCY_CACHE, ck, nothing)
        entry !== nothing && entry[1] == token && entry[2] === sys && entry[3] == names_tuple ?
            entry[4] : nothing
    end
    cached === nothing || return cached

    result = _initials_depend_on_names(prob, names_tuple)
    return lock(_INITIAL_DEPENDENCY_CACHE_LOCK) do
        entry = get(_INITIAL_DEPENDENCY_CACHE, ck, nothing)
        if entry !== nothing && entry[1] == token && entry[2] === sys && entry[3] == names_tuple
            return entry[4]
        end
        _INITIAL_DEPENDENCY_CACHE[ck] = (token, sys, names_tuple, result)
        return result
    end
end

# --- Errors ---

"""
    BindingUpdateError <: Exception

Exception thrown when attempting to update a bound parameter.
Bindings are computed from other parameters and cannot be directly modified.
"""
struct BindingUpdateError <: Exception
    key::Any
    binding_expr::Any
end

function Base.showerror(io::IO, e::BindingUpdateError)
    print(io, "BindingUpdateError: Cannot update '$(e.key)' — it is a bound parameter")
    if e.binding_expr !== nothing
        print(io, " defined as: $(e.binding_expr)")
    end
    print(io, ". Update the underlying parameters instead.")
end

# --- Unit Handling Helpers ---

_has_units(value) = isa(value, Unitful.AbstractQuantity)

function _get_model_unit(param)
    try
        sym = param isa Symbolics.Num ? Symbolics.unwrap(param) : param
        unit_val = Symbolics.getmetadata(sym, MTK.VariableUnit, nothing)
        if unit_val !== nothing
            return unit_val isa Unitful.AbstractQuantity ? Unitful.unit(unit_val) : unit_val
        end
    catch
    end
    return nothing
end

function _process_units(pairs, prob; validate_units::Bool=true, convert_units::Bool=true)
    if !validate_units && convert_units
        throw(ArgumentError("The combination `validate_units=false` with `convert_units=true` is not allowed for safety reasons."))
    end

    sys = _mtk_system(prob)
    has_any_units = any(_has_units(last(p)) for p in pairs)
    if !has_any_units && !validate_units
        return pairs
    end

    processed_pairs = Vector{Pair{Any, Any}}(undef, length(pairs))

    for (i, (key, value)) in enumerate(pairs)
        resolved_key = key
        if sys !== nothing
            resolved = _resolve_to_num(sys, key)
            if resolved !== nothing
                resolved_key = resolved
            end
        end

        model_unit = _get_model_unit(resolved_key)
        model_has_unit_metadata = model_unit !== nothing && Unitful.dimension(model_unit) != Unitful.NoDims

        if _has_units(value)
            value_unit = Unitful.unit(value)
            value_is_dimensionless = Unitful.dimension(value_unit) == Unitful.NoDims

            if model_has_unit_metadata
                if validate_units && !value_is_dimensionless
                    if Unitful.dimension(model_unit) != Unitful.dimension(value_unit)
                        throw(ArgumentError("Unit dimension mismatch for parameter `$key`. Model has `$model_unit`, but received `$value_unit`."))
                    end
                    if !convert_units && model_unit != value_unit
                        throw(ArgumentError("Unit mismatch for parameter `$key`. Model has `$model_unit`, but received `$value_unit`. Set `convert_units=true` to enable automatic conversion."))
                    end
                end

                if convert_units && !value_is_dimensionless
                    new_value = Unitful.ustrip(Unitful.uconvert(model_unit, value))
                    processed_pairs[i] = key => new_value
                else
                    processed_pairs[i] = key => Unitful.ustrip(value)
                end
            else
                processed_pairs[i] = key => Unitful.ustrip(value)
            end
        else
            if validate_units && model_has_unit_metadata
                throw(ArgumentError("Parameter `$key` has units `$(model_unit)` in the model, but received a unitless value."))
            end
            processed_pairs[i] = key => value
        end
    end

    return processed_pairs
end

# --- Resolution Helpers ---

function _resolve_symbolic_to_system(sys, key)
    key_name = try
        string(MTK.getname(key))
    catch
        return key
    end

    try
        MTK.parse_variable(sys, key_name)
    catch e
        e isa ArgumentError && return key
        rethrow()
    end
end

_resolve_to_num(sys, key::Num) = _resolve_symbolic_to_system(sys, key)
_resolve_to_num(sys, key::SymbolicUtils.BasicSymbolic) = _resolve_symbolic_to_system(sys, key)
function _resolve_to_num(sys, key::Union{String, Symbol})
    str = key isa Symbol ? string(key) : key
    try
        MTK.parse_variable(sys, str)
    catch e
        # MTK throws ArgumentError for variables that exist in the system but
        # aren't unknowns (e.g., observed/binding variables like
        # scaled_output = gain * reference_level).
        # Return nothing so _resolve_key falls through to the binding check.
        e isa ArgumentError && return nothing
        rethrow()
    end
end

function _is_binding(sys, key)
    sys === nothing && error("ConfigKit requires an MTK system to check bindings.")
    isdefined(MTK, :get_bindings) || return (false, nothing)
    bindings = MTK.get_bindings(sys)
    isempty(bindings) && return (false, nothing)

    if haskey(bindings, key)
        return (true, bindings[key])
    end

    key_name = key isa Symbol ? key : (key isa String ? Symbol(key) : nothing)
    if key_name !== nothing
        for (k, v) in bindings
            if MTK.getname(k) == key_name
                return (true, v)
            end
        end
    end
    return (false, nothing)
end

"""
    _resolve_key(prob, k; strict=true)

Resolve a key to its symbolic form, handling Initial() wrapping for state variables.
Returns (resolved_key, is_valid) tuple.
"""
function _resolve_key(prob, k; strict::Bool=true)
    sys = _mtk_system(prob)
    real_key = k
    resolved = _resolve_to_num(sys, k)
    if resolved !== nothing
        real_key = resolved
    end

    # Try as standard parameter
    if parameter_index(prob, real_key) !== nothing
        return (real_key, true)
    end

    # Try as Initial(x) for state variables
    initial_key = try MTK.Initial(real_key) catch; nothing end
    if initial_key !== nothing && parameter_index(prob, initial_key) !== nothing
        return (initial_key, true)
    end

    # Check if it's a binding (error) or ghost parameter (skip)
    (is_bound, expr) = _is_binding(sys, real_key)
    if is_bound
        strict && throw(BindingUpdateError(k, expr))
        @debug "Skipping binding '$k'"
    else
        @debug "Skipping ghost parameter '$k'"
    end
    return (nothing, false)
end

# --- Resolution + Filtering (single-pass) ---

"""
    _resolve_and_filter(prob, pairs; strict=true)

Single-pass key resolution: resolves keys and collects only valid (key, value) pairs.
Returns `(valid_keys::Vector, valid_values::Vector)`.
"""
function _resolve_and_filter(prob, pairs; strict::Bool=true)
    valid_keys = Vector{Any}()
    valid_values = Vector{Any}()
    for (k, v) in pairs
        (resolved, is_valid) = _resolve_key(prob, k; strict)
        if is_valid
            push!(valid_keys, resolved)
            push!(valid_values, v)
        end
    end
    return valid_keys, valid_values
end

"""
    _value_eltype(values)

Compute the promoted numeric element type of a vector of values,
handling heterogeneous `Vector{Any}`.
"""
function _value_eltype(values)
    isempty(values) && return Float64
    T = typeof(first(values))
    for i in 2:length(values)
        T = promote_type(T, typeof(values[i]))
    end
    return T
end

# --- The Main Update Functions ---

function _updated_u0_from_plan(prob::SciMLBase.ODEProblem, plan::_UpdatePlan, raw_values)
    isempty(plan.valid_state_keys) && return nothing

    state_update_values = Any[raw_values[i] for i in plan.valid_state_indices]
    u0 = state_values(prob)
    V = _value_eltype(state_update_values)
    u0_new = _needs_state_buffer_promotion(u0, V) ? V.(u0) : copy(u0)
    plan.state_setter(u0_new, state_update_values)
    return u0_new
end

function _finish_update_remake(prob::SciMLBase.ODEProblem, ps_new, plan::_UpdatePlan,
                               raw_values, has_explicit_u0::Bool, kwargs)
    u0_new = has_explicit_u0 ? nothing : _updated_u0_from_plan(prob, plan, raw_values)

    if u0_new !== nothing
        build_initializeprob, remake_kwargs = _split_build_initializeprob(kwargs, false)
        return _remake_with_synced_initials(prob;
            p=ps_new, u0=u0_new, build_initializeprob,
            sync_initials=false, initial_sync_entries=plan.initial_sync_entries,
            remake_kwargs...)
    end

    build_initializeprob, remake_kwargs = _split_build_initializeprob(kwargs, !has_explicit_u0)
    return _remake_with_synced_initials(prob;
        p=ps_new, build_initializeprob, sync_initials=build_initializeprob,
        initial_sync_entries=plan.initial_sync_entries, remake_kwargs...)
end

"""
    update(prob, pairs; strict=true, validate_units=true, convert_units=true)

Update parameters or initial conditions of an `ODEProblem`.

Returns a new problem with updated parameters. The original problem is unchanged (thread-safe).

Supports automatic differentiation: when values are dual numbers (e.g., from ForwardDiff
or Turing.jl), the parameter buffer is promoted to the appropriate element type.

# Behavior
- Resolves string/symbol keys to symbolic form
- Automatically maps state variables to `Initial(var)` parameters
- Throws `BindingUpdateError` if attempting to update a bound parameter
- Validates and converts Unitful values to model units

# Keywords
- `strict=true`: Throw on binding updates (set to `false` to skip silently)
- `validate_units=true`: Validate unit dimensions match model
- `convert_units=true`: Convert values to model's unit system

# Example
```julia
prob2 = update(prob, [:CL => 2.0, :V1 => 50.0])
prob2 = update(prob, [model.Thalf => 200u"hr"])  # Units converted automatically
```
"""
function update(prob::SciMLBase.ODEProblem, pairs; strict::Bool=true, validate_units::Bool=true, convert_units::Bool=true, kwargs...)
    processed_pairs = _process_units(pairs, prob; validate_units, convert_units)
    raw_keys = Any[first(p) for p in processed_pairs]
    raw_values = Any[last(p) for p in processed_pairs]
    plan = _get_update_plan(prob, raw_keys; strict)

    isempty(plan.valid_indices) && return SciMLBase.remake(prob; kwargs...)

    valid_values = Any[raw_values[i] for i in plan.valid_indices]
    ps = parameter_values(prob)
    V = _value_eltype(valid_values)
    has_explicit_u0 = haskey(kwargs, :u0)

    # Dual-aware and non-tunable path: promote every MTKParameters partition.
    if _needs_buffer_promotion(ps, V) || !plan.plain_tunable
        ps_new = SymbolicIndexingInterface.remake_buffer(prob, ps, plan.valid_keys, valid_values)
        updated = _finish_update_remake(prob, ps_new, plan, raw_values, has_explicit_u0, kwargs)
        return _register_prepared_update_source(updated, prob, raw_keys, raw_values; strict, kwargs...)
    end

    # Fast path: ordinary tunable model parameters only. Mutable buffers are
    # per-call; the cached plan only stores symbolic layout and the setter.
    tunable, = canonicalize(Tunable(), ps)
    buffer = copy(tunable)
    # copy(ps): replace(Tunable(),…) shares non-tunable partitions (notably .initials)
    # with the base problem's params; the solve mutates .initials in place, leaking state
    # across repeated update() calls on the same problem (non-determinism). Keep private.
    ps_new = replace(Tunable(), copy(ps), buffer)
    plan.setter(ps_new, valid_values)
    updated = _finish_update_remake(prob, ps_new, plan, raw_values, has_explicit_u0, kwargs)
    return _register_prepared_update_source(updated, prob, raw_keys, raw_values; strict, kwargs...)
end

# Decide whether the values require promoting the full parameter buffer.
# Returns true when any value's element type can't be stored in the
# current tunable buffer's element type.
function _needs_buffer_promotion(ps, V)
    try
        tunable, = canonicalize(Tunable(), ps)
        buf_T = Base.nonmissingtype(eltype(tunable))
        return promote_type(buf_T, V) !== buf_T
    catch
        # If canonicalize fails, be safe and use remake_buffer
        return true
    end
end

function _keys_are_plain_tunable_parameters(prob, keys)
    for key in keys
        idx = parameter_index(prob, key)
        idx isa MTK.ParameterIndex{Tunable} ||
            return false
    end
    return true
end

function _sync_initial_parameters_from_u0(prob::SciMLBase.ODEProblem,
                                           entries::Vector{Tuple{Any, Any}} = _initial_sync_entries(prob))
    keys = Any[]
    vals = Any[]
    for (var, initial_key) in entries
        val = try
            prob[var]
        catch
            continue
        end
        push!(keys, initial_key)
        push!(vals, val)
    end
    isempty(keys) && return prob
    ps_new = SymbolicIndexingInterface.remake_buffer(prob, parameter_values(prob), keys, vals)
    return SciMLBase.remake(prob; p=ps_new, build_initializeprob=false)
end

function _remake_with_synced_initials(prob::SciMLBase.ODEProblem;
                                      sync_initials::Bool=false,
                                      initial_sync_entries = nothing,
                                      kwargs...)
    new_prob = SciMLBase.remake(prob; kwargs...)
    if !sync_initials
        return new_prob
    end
    entries = initial_sync_entries === nothing ? _initial_sync_entries(prob) : initial_sync_entries
    return _sync_initial_parameters_from_u0(new_prob, entries)
end

function _split_build_initializeprob(kwargs, default::Bool)
    nt = (; kwargs...)
    build_initializeprob = get(nt, :build_initializeprob, default)
    names = Tuple(k for k in keys(nt) if k !== :build_initializeprob)
    stripped = NamedTuple{names}(Tuple(getfield(nt, k) for k in names))
    return build_initializeprob, stripped
end


_state_only(plan::_UpdatePlan) = !isempty(plan.valid_state_keys) && isempty(plan.valid_param_keys)

function _needs_state_buffer_promotion(u0, V)
    buf_T = Base.nonmissingtype(eltype(u0))
    return promote_type(buf_T, V) !== buf_T
end

function _check_update_cache_keys(cache::UpdateCache, raw_keys)
    _same_raw_keys(cache.plan.raw_keys, Tuple(raw_keys)) && return nothing
    throw(ArgumentError("UpdateCache keys do not match this update call. Construct a separate UpdateCache for each key set."))
end

function _fill_valid_values!(cache::UpdateCache, raw_values)
    for (j, i) in enumerate(cache.plan.valid_indices)
        cache.valid_values[j] = raw_values[i]
    end
    return cache.valid_values
end

function _sync_initial_parameters_from_u0!(cache::UpdateCache, prob::SciMLBase.ODEProblem)
    entries = cache.plan.initial_sync_entries
    isempty(entries) && return prob
    for i in eachindex(entries)
        cache.sync_values[i] = prob[entries[i][1]]
    end
    ps_new = SymbolicIndexingInterface.remake_buffer(
        prob, parameter_values(prob), cache.sync_keys, cache.sync_values)
    return SciMLBase.remake(prob; p=ps_new, build_initializeprob=false)
end

function _remake_with_cached_synced_initials!(cache::UpdateCache; sync_initials::Bool=false, kwargs...)
    new_prob = SciMLBase.remake(cache.prob; kwargs...)
    return sync_initials ? _sync_initial_parameters_from_u0!(cache, new_prob) : new_prob
end

"""
    UpdateCache(prob, keys; strict=true)

Caller-owned workspace for repeated `ConfigKit.update!` calls with one fixed key set.

`UpdateCache` is intentionally not a global cache. It owns mutable buffers used by
`update!`, so callers that evaluate in parallel should create one cache per task,
thread, subject, or solver workspace. The `ODEProblem` returned by `update!` may
borrow those buffers and is only valid until the next `update!` call on the same
cache. Use ordinary `update` when the returned problem must be persistent, or
`with_update_cache` when a shared cache must be guarded while the returned problem
is consumed.
"""
function UpdateCache(prob::SciMLBase.ODEProblem, raw_keys; strict::Bool=true)
    raw_tuple = Tuple(raw_keys)
    plan = _get_update_plan(prob, raw_tuple; strict)
    ps = parameter_values(prob)

    base_tunable = nothing
    tunable_buffer = nothing
    if plan.plain_tunable && !isempty(plan.valid_keys)
        tunable, = canonicalize(Tunable(), ps)
        base_tunable = copy(tunable)
        tunable_buffer = copy(tunable)
    end

    base_u0 = nothing
    u0_buffer = nothing
    if _state_only(plan)
        base_u0 = copy(state_values(prob))
        u0_buffer = copy(base_u0)
    end

    sync_keys = Any[last(entry) for entry in plan.initial_sync_entries]
    sync_values = Vector{Any}(undef, length(sync_keys))
    valid_values = Vector{Any}(undef, length(plan.valid_indices))

    return UpdateCache(prob, plan, base_tunable, tunable_buffer, base_u0,
        u0_buffer, valid_values, sync_keys, sync_values, ReentrantLock())
end

UpdateCache(prob::SciMLBase.ODEProblem, params::NamedTuple; strict::Bool=true) =
    UpdateCache(prob, keys(params); strict)

function UpdateCache(prob::SciMLBase.ODEProblem, pairs::AbstractVector{<:Pair};
                     strict::Bool=true, validate_units::Bool=true, convert_units::Bool=true)
    processed_pairs = _process_units(pairs, prob; validate_units, convert_units)
    raw_keys = Any[first(p) for p in processed_pairs]
    return UpdateCache(prob, raw_keys; strict)
end

function _update_from_cache_values!(cache::UpdateCache; kwargs...)
    plan = cache.plan
    prob = cache.prob
    if isempty(plan.valid_indices)
        return SciMLBase.remake(prob; kwargs...)
    end

    V = _value_eltype(cache.valid_values)

    if _state_only(plan) && !_needs_state_buffer_promotion(cache.base_u0, V)
        copyto!(cache.u0_buffer, cache.base_u0)
        plan.state_setter(cache.u0_buffer, cache.valid_values)
        build_initializeprob, remake_kwargs = _split_build_initializeprob(kwargs, false)
        new_prob = SciMLBase.remake(prob; u0=cache.u0_buffer,
            build_initializeprob=build_initializeprob, remake_kwargs...)
        return _sync_initial_parameters_from_u0!(cache, new_prob)
    end

    ps = parameter_values(prob)
    if _needs_buffer_promotion(ps, V) || !plan.plain_tunable
        ps_new = SymbolicIndexingInterface.remake_buffer(prob, ps, plan.valid_keys, cache.valid_values)
        build_initializeprob, remake_kwargs = _split_build_initializeprob(kwargs, !haskey(kwargs, :u0))
        return _remake_with_cached_synced_initials!(cache;
            p=ps_new, build_initializeprob, sync_initials=build_initializeprob,
            remake_kwargs...)
    end

    copyto!(cache.tunable_buffer, cache.base_tunable)
    # `replace(Tunable(), ps, …)` swaps ONLY the `.tunable` partition; every other
    # partition — crucially `.initials` — stays SHARED BY REFERENCE with the cached
    # base problem's parameters (`ps == parameter_values(cache.prob)`). Per-solve MTK
    # initialization writes `.initials` in place, so without a private copy the cached
    # base drifts toward the dosing steady state across repeated solves of the same
    # subject, making logdensity non-deterministic. Copy so `.initials` is private here.
    ps_new = replace(Tunable(), copy(ps), cache.tunable_buffer)
    plan.setter(ps_new, cache.valid_values)
    build_initializeprob, remake_kwargs = _split_build_initializeprob(kwargs, !haskey(kwargs, :u0))
    return _remake_with_cached_synced_initials!(cache;
        p=ps_new, build_initializeprob, sync_initials=build_initializeprob,
        remake_kwargs...)
end

"""
    update!(cache::UpdateCache, values; kwargs...)

Update through a caller-owned cache. The returned problem may borrow cache
buffers and is valid only until the next update on the same cache. Use
[`with_update_cache`](@ref) for guarded immediate consumption or [`update`](@ref)
for an independently retained problem.
"""
function update!(cache::UpdateCache, params::NamedTuple; kwargs...)
    lock(cache.borrow_lock)
    try
        ks = keys(params)
        _check_update_cache_keys(cache, ks)
        raw_values = Tuple(params[k] for k in ks)
        _fill_valid_values!(cache, raw_values)
        updated = _update_from_cache_values!(cache; kwargs...)
        return _register_prepared_update_source(
            updated, cache.prob, cache.plan.raw_keys, raw_values;
            strict=cache.plan.strict, kwargs...)
    finally
        unlock(cache.borrow_lock)
    end
end

function update!(cache::UpdateCache, values::AbstractVector; kwargs...)
    lock(cache.borrow_lock)
    try
        length(values) == length(cache.plan.raw_keys) ||
            throw(ArgumentError("Expected $(length(cache.plan.raw_keys)) values for UpdateCache, got $(length(values))."))
        _fill_valid_values!(cache, values)
        updated = _update_from_cache_values!(cache; kwargs...)
        return _register_prepared_update_source(
            updated, cache.prob, cache.plan.raw_keys, values;
            strict=cache.plan.strict, kwargs...)
    finally
        unlock(cache.borrow_lock)
    end
end

function update!(cache::UpdateCache, values::Tuple; kwargs...)
    lock(cache.borrow_lock)
    try
        length(values) == length(cache.plan.raw_keys) ||
            throw(ArgumentError("Expected $(length(cache.plan.raw_keys)) values for UpdateCache, got $(length(values))."))
        _fill_valid_values!(cache, values)
        updated = _update_from_cache_values!(cache; kwargs...)
        return _register_prepared_update_source(
            updated, cache.prob, cache.plan.raw_keys, values;
            strict=cache.plan.strict, kwargs...)
    finally
        unlock(cache.borrow_lock)
    end
end

function update!(cache::UpdateCache, pairs::AbstractVector{<:Pair};
                 validate_units::Bool=true, convert_units::Bool=true, kwargs...)
    lock(cache.borrow_lock)
    try
        processed_pairs = _process_units(pairs, cache.prob; validate_units, convert_units)
        raw_keys = Any[first(p) for p in processed_pairs]
        _check_update_cache_keys(cache, raw_keys)
        raw_values = Any[last(p) for p in processed_pairs]
        _fill_valid_values!(cache, raw_values)
        updated = _update_from_cache_values!(cache; kwargs...)
        return _register_prepared_update_source(
            updated, cache.prob, cache.plan.raw_keys, raw_values;
            strict=cache.plan.strict, kwargs...)
    finally
        unlock(cache.borrow_lock)
    end
end

"""
    with_update_cache(f, cache::UpdateCache, params; kwargs...)

Run `f(updated_problem)` while holding `cache`'s mutation lock.

This is the safe way to share an `UpdateCache` across tasks when the returned
problem is consumed immediately. The ordinary `update!` API serializes cache
mutation, but the returned `ODEProblem` may borrow mutable cache buffers after
`update!` returns; another update on the same cache can therefore invalidate it.
For persistent returned problems, use allocation-owning `update`.
"""
function _with_update_cache_values(f, cache::UpdateCache, raw_values; kwargs...)
    lock(cache.borrow_lock)
    try
        _fill_valid_values!(cache, raw_values)
        prob = _update_from_cache_values!(cache; kwargs...)
        prob = _register_prepared_update_source(
            prob, cache.prob, cache.plan.raw_keys, raw_values;
            strict=cache.plan.strict, kwargs...)
        return f(prob)
    finally
        unlock(cache.borrow_lock)
    end
end

"""
    with_update_cache(f, cache::UpdateCache, values; kwargs...)

Run `f(updated_problem)` while holding the cache's mutation/borrow lock. The
borrowed problem must not escape the callback.
"""
function with_update_cache(f, cache::UpdateCache, params::NamedTuple; kwargs...)
    ks = keys(params)
    _check_update_cache_keys(cache, ks)
    raw_values = Tuple(params[k] for k in ks)
    return _with_update_cache_values(f, cache, raw_values; kwargs...)
end

function with_update_cache(f, cache::UpdateCache, values::AbstractVector; kwargs...)
    length(values) == length(cache.plan.raw_keys) ||
        throw(ArgumentError("Expected $(length(cache.plan.raw_keys)) values for UpdateCache, got $(length(values))."))
    return _with_update_cache_values(f, cache, values; kwargs...)
end

function with_update_cache(f, cache::UpdateCache, values::Tuple; kwargs...)
    length(values) == length(cache.plan.raw_keys) ||
        throw(ArgumentError("Expected $(length(cache.plan.raw_keys)) values for UpdateCache, got $(length(values))."))
    return _with_update_cache_values(f, cache, values; kwargs...)
end

function with_update_cache(f, cache::UpdateCache, pairs::AbstractVector{<:Pair};
                           validate_units::Bool=true, convert_units::Bool=true, kwargs...)
    processed_pairs = _process_units(pairs, cache.prob; validate_units, convert_units)
    raw_keys = Any[first(p) for p in processed_pairs]
    _check_update_cache_keys(cache, raw_keys)
    raw_values = Any[last(p) for p in processed_pairs]
    return _with_update_cache_values(f, cache, raw_values; kwargs...)
end

function _thread_update_cache_key(prob::SciMLBase.ODEProblem, raw_keys, strict::Bool)
    h = _problem_cache_token(prob)
    h = hash(Base.Threads.threadid(), h)
    h = hash(objectid(prob), h)
    h = hash(strict, h)
    for k in raw_keys
        h = hash(k, h)
    end
    return h
end

function _same_update_cache(cache::UpdateCache, prob::SciMLBase.ODEProblem,
                            raw_keys::Tuple, strict::Bool)
    return cache.prob === prob &&
        cache.plan.strict == strict &&
        _same_raw_keys(cache.plan.raw_keys, raw_keys)
end

"""
    thread_update_cache(prob, keys; strict=true)

Return the current thread's reusable `UpdateCache` for `prob` and a fixed key
set, creating it on first use.

The returned cache owns mutable parameter and `u0` work buffers, so it is keyed
by thread as well as problem and keys. This is the shared hot-path primitive for
simulation, population fitting, and target scoring loops that need
`ConfigKit.update` semantics without per-proposal workspace allocation.
"""
function thread_update_cache(prob::SciMLBase.ODEProblem, raw_keys; strict::Bool=true)
    raw_tuple = Tuple(raw_keys)
    key = _thread_update_cache_key(prob, raw_tuple, strict)

    cached = lock(_THREAD_UPDATE_CACHE_LOCK) do
        entry = get(_THREAD_UPDATE_CACHE, key, nothing)
        entry !== nothing && _same_update_cache(entry, prob, raw_tuple, strict) ? entry : nothing
    end
    cached !== nothing && return cached

    built = UpdateCache(prob, raw_tuple; strict)
    return lock(_THREAD_UPDATE_CACHE_LOCK) do
        entry = get(_THREAD_UPDATE_CACHE, key, nothing)
        if entry !== nothing && _same_update_cache(entry, prob, raw_tuple, strict)
            return entry
        end
        _THREAD_UPDATE_CACHE[key] = built
        return built
    end
end

"""
    with_thread_update_cache(f, prob, params; strict=true, kwargs...)
    with_thread_update_cache(f, prob, keys, values; strict=true, kwargs...)

Run `f(updated_problem)` using the current thread's reusable update cache.
The callback is evaluated while the cache lock is held so the returned problem
can safely borrow cache-owned buffers during an immediate solve.
"""
function with_thread_update_cache(f, prob::SciMLBase.ODEProblem,
                                  params::NamedTuple; strict::Bool=true, kwargs...)
    cache = thread_update_cache(prob, keys(params); strict)
    return with_update_cache(f, cache, params; kwargs...)
end

function with_thread_update_cache(f, prob::SciMLBase.ODEProblem,
                                  raw_keys, raw_values; strict::Bool=true, kwargs...)
    cache = thread_update_cache(prob, raw_keys; strict)
    return with_update_cache(f, cache, raw_values; kwargs...)
end

# --- NamedTuple Fast Path (type-stable, ForwardDiff-compatible) ---

"""
    update(prob::ODEProblem, params::NamedTuple; strict=true, kwargs...)

Type-stable parameter update from a NamedTuple. Skips unit processing
(NamedTuple values are assumed unitless). The value type propagates
from the NamedTuple's element type, enabling ForwardDiff Dual numbers
to flow through without runtime type recovery.

This is the hot path for repeated simulation and estimation updates.
"""
function update(prob::SciMLBase.ODEProblem, params::NamedTuple; strict::Bool=true, kwargs...)
    ks = keys(params)
    isempty(ks) && return SciMLBase.remake(prob; kwargs...)
    raw_values = Tuple(params[k] for k in ks)

    plan = _get_update_plan(prob, ks; strict)
    isempty(plan.valid_indices) && return SciMLBase.remake(prob; kwargs...)

    # Collect values preserving their type (Dual-compatible)
    valid_vals = [params[ks[i]] for i in plan.valid_indices]

    ps = parameter_values(prob)
    V = eltype(valid_vals)

    # Dual-aware and non-tunable path: promote all partitions via remake_buffer.
    if _needs_buffer_promotion(ps, V) || !plan.plain_tunable
        ps_new = SymbolicIndexingInterface.remake_buffer(prob, ps, plan.valid_keys, valid_vals)
        build_initializeprob, remake_kwargs = _split_build_initializeprob(kwargs, !haskey(kwargs, :u0))
        updated = _remake_with_synced_initials(prob;
            p=ps_new, build_initializeprob, sync_initials=build_initializeprob,
            initial_sync_entries=plan.initial_sync_entries, remake_kwargs...)
        return _register_prepared_update_source(updated, prob, ks, raw_values; strict, kwargs...)
    end

    tunable, = canonicalize(Tunable(), ps)
    buffer = copy(tunable)
    # copy(ps): replace(Tunable(),…) shares non-tunable partitions (notably .initials)
    # with the base problem's params; the solve mutates .initials in place, leaking state
    # across repeated update() calls on the same problem (non-determinism). Keep private.
    ps_new = replace(Tunable(), copy(ps), buffer)
    plan.setter(ps_new, valid_vals)
    build_initializeprob, remake_kwargs = _split_build_initializeprob(kwargs, !haskey(kwargs, :u0))
    updated = _remake_with_synced_initials(prob;
        p=ps_new, build_initializeprob, sync_initials=build_initializeprob,
        initial_sync_entries=plan.initial_sync_entries, remake_kwargs...)
    return _register_prepared_update_source(updated, prob, ks, raw_values; strict, kwargs...)
end

# --- Overloads for Other Types ---

"""
    update(sys::AbstractSystem, pairs)

Update parameter values and initial conditions on an MTK System.
Returns a completed system with updated values.
"""
function update(sys::MTK.AbstractSystem, pairs; kwargs...)
    new_ics = try Dict{Any,Any}(MTK.get_initial_conditions(sys)) catch; Dict{Any,Any}() end

    for (k, v) in pairs
        real_key = _resolve_to_num(sys, k)
        if real_key === nothing
            real_key = k
        end
        new_ics[real_key] = v
    end

    @set! sys.initial_conditions = new_ics
    return MTK.complete(sys)
end

"""
    update(integrator::DEIntegrator, pairs; strict=true, reinit=false)

Update parameters or state variables of a running integrator.
"""
function update(integrator::SciMLBase.DEIntegrator, pairs; strict::Bool=true, kwargs...)
    sys = try
        prob = integrator.sol.prob
        _mtk_system(prob)
    catch err
        rethrow(err)
    end

    for (k, v) in pairs
        real_key = k
        resolved = _resolve_to_num(sys, k)
        if resolved !== nothing
            real_key = resolved
        end

        if parameter_index(integrator, real_key) !== nothing
            integrator.ps[real_key] = v
        elseif variable_index(integrator, real_key) !== nothing
            integrator[real_key] = v
        else
            (is_bound, binding_expr) = _is_binding(sys, real_key)
            if is_bound
                strict && throw(BindingUpdateError(k, binding_expr))
                @debug "Skipping binding '$k'"
            else
                @debug "Skipping ghost parameter '$k'"
            end
        end
    end

    get(kwargs, :reinit, false) && SciMLBase.reinit!(integrator)
    return integrator
end
