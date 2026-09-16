# Numeric value resolution for keyfile entries.

const _KEYFILE_ENTRY_CONTEXTS = IdDict{ParameterEntry, Any}()
const _KEYFILE_VIEW_CONTEXTS = IdDict{ParametersView, Any}()
const _KEYFILE_ENTRY_CONTEXTS_LOCK = ReentrantLock()

function _register_keyfile_value_context!(kf::KeyfileAccessor)
    lock(_KEYFILE_ENTRY_CONTEXTS_LOCK) do
        for block in (:Parameters, :Variables, :Constants)
            view = getfield(kf, block)
            _KEYFILE_VIEW_CONTEXTS[view] = kf
            for entry in values(view)
                _KEYFILE_ENTRY_CONTEXTS[entry] = kf
            end
        end
    end
    return kf
end

function _keyfile_entry_context(entry::ParameterEntry)
    return lock(_KEYFILE_ENTRY_CONTEXTS_LOCK) do
        get(_KEYFILE_ENTRY_CONTEXTS, entry, nothing)
    end
end

function _keyfile_view_context(view::ParametersView)
    return lock(_KEYFILE_ENTRY_CONTEXTS_LOCK) do
        get(_KEYFILE_VIEW_CONTEXTS, view, nothing)
    end
end

"""
    value(kf::KeyfileAccessor, key; convert=true)

Return the numeric value for `key` from a loaded keyfile. Numeric entries are
returned directly, applying the entry's `convert` metadata when `convert=true`.
Expression-valued entries are evaluated recursively against the keyfile's
Parameters, Variables, and Constants blocks.

`key` may be a `Symbol`, `String`, or MTK/Symbolics object with a resolvable
name.
"""
function value(kf::KeyfileAccessor, key; convert::Bool=true)
    name = _keyfile_value_name(key)
    return _resolve_keyfile_value(kf, name; convert=convert, stack=Symbol[])
end

"""
    value(view::ParametersView, key; convert=true)

Resolve `key` within a single keyfile block such as `kf.Parameters`.
Expressions can refer to other entries in the same block. Use
`value(kf, key)` when expressions need dependencies from multiple blocks.
"""
function value(view::ParametersView, key; convert::Bool=true)
    name = _keyfile_value_name(key)
    entry = _lookup_keyfile_entry(view, name)
    context = something(_keyfile_view_context(view), view)
    return _resolve_entry_value(context, entry; convert=convert, stack=[name])
end

"""
    value(entry::ParameterEntry; convert=true)

Return the value of a numeric keyfile entry. Pure numeric string expressions
such as `"2 * 0.05"` are evaluated. Entries loaded from a keyfile retain enough
context to resolve expression dependencies; manually constructed entries can
only resolve dependency-free expressions.
"""
function value(entry::ParameterEntry; convert::Bool=true)
    context = _keyfile_entry_context(entry)
    stack = context === nothing ? Symbol[] : [entry.name]
    return _resolve_entry_value(context, entry; convert=convert, stack=stack)
end

function _keyfile_value_name(key::Symbol)
    return key
end

function _keyfile_value_name(key::AbstractString)
    return Symbol(key)
end

function _keyfile_value_name(key)
    try
        return Symbol(MTK.getname(key))
    catch mtk_err
        try
            return Symbol(SciMLBase.getname(key))
        catch sci_err
            throw(ArgumentError(
                "ConfigKit: Cannot resolve a keyfile name from $(repr(key)) " *
                "(type $(typeof(key))). Pass a Symbol, String, or MTK symbolic variable."
            ))
        end
    end
end

function _context_has_entry(kf::KeyfileAccessor, name::Symbol)
    count = 0
    for block in (:Parameters, :Variables, :Constants)
        haskey(getfield(kf, block).data, name) && (count += 1)
    end
    return count > 0
end

_context_has_entry(view::ParametersView, name::Symbol) = haskey(view.data, name)
_context_has_entry(::Nothing, ::Symbol) = false

function _lookup_keyfile_entry(kf::KeyfileAccessor, name::Symbol)
    matches = Pair{Symbol, ParameterEntry}[]
    for block in (:Parameters, :Variables, :Constants)
        view = getfield(kf, block)
        haskey(view.data, name) && push!(matches, block => view.data[name])
    end

    if isempty(matches)
        throw(KeyError(name))
    elseif length(matches) > 1
        blocks = join(first.(matches), ", ")
        throw(ArgumentError(
            "ConfigKit: Key '$name' appears in multiple keyfile blocks ($blocks). " *
            "Use a block-scoped call such as `value(kf.Parameters, :$name)`."
        ))
    end

    return last(only(matches))
end

function _lookup_keyfile_entry(view::ParametersView, name::Symbol)
    haskey(view.data, name) || throw(KeyError(name))
    return view.data[name]
end

function _resolve_keyfile_value(context, name::Symbol; convert::Bool, stack::Vector{Symbol})
    if name in stack
        first_idx = findfirst(==(name), stack)
        cycle = [stack[first_idx:end]; name]
        throw(ArgumentError("ConfigKit: Cyclic keyfile value dependency: $(join(cycle, " -> "))"))
    end

    entry = _lookup_keyfile_entry(context, name)
    return _resolve_entry_value(context, entry; convert=convert, stack=[stack; name])
end

function _resolve_entry_value(context, entry::ParameterEntry; convert::Bool, stack::Vector{Symbol})
    raw = entry.value

    raw === nothing && throw(ArgumentError(
        "ConfigKit: Entry '$(entry.name)' has no value. Select a variant or add a default value."
    ))

    if raw isa DQ.AbstractQuantity
        raw = DQ.ustrip(raw)
    end

    if raw isa Number
        return _maybe_convert_entry_value(entry, raw; convert=convert)
    elseif raw isa AbstractString
        return _evaluate_keyfile_expression(context, entry, raw; convert=convert, stack=stack)
    else
        throw(ArgumentError(
            "ConfigKit: Entry '$(entry.name)' has non-numeric value $(repr(raw)) " *
            "(type $(typeof(raw)))."
        ))
    end
end

function _maybe_convert_entry_value(entry::ParameterEntry, raw::Number; convert::Bool)
    convert || return raw
    haskey(entry.metadata, :convert) || return raw

    target_unit_str = string(entry.metadata[:convert])
    isempty(target_unit_str) && return raw

    source_has_dims = entry.unit !== nothing && !isempty(string(DQ.dimension(entry.unit)))
    if !source_has_dims
        @warn "ConfigKit: Cannot convert '$(entry.name)' to '$target_unit_str' - no source unit specified."
        return raw
    end

    target_unit = getMTKUnit(target_unit_str)
    conversion_factor = DQ.ustrip(entry.unit / target_unit)
    return raw * conversion_factor
end

function _evaluate_keyfile_expression(context, entry::ParameterEntry, expr_str::AbstractString;
                                      convert::Bool, stack::Vector{Symbol})
    parsed = try
        Meta.parse(expr_str)
    catch err
        throw(ArgumentError(
            "ConfigKit: Could not parse expression for '$(entry.name)': $(repr(expr_str)). Error: $err"
        ))
    end

    mod = Module()
    Core.eval(mod, :(using Base))

    for dep in sort!(collect(_expression_symbols(parsed)); by=string)
        if _context_has_entry(context, dep)
            dep_value = _resolve_keyfile_value(context, dep; convert=convert, stack=stack)
            Core.eval(mod, Expr(:(=), dep, dep_value))
        end
    end

    result = try
        Core.eval(mod, parsed)
    catch err
        if err isa UndefVarError
            throw(ArgumentError(
                "ConfigKit: Could not evaluate expression for '$(entry.name)': " *
                "$(repr(expr_str)). Unresolved symbol: $(err.var)."
            ))
        else
            throw(ArgumentError(
                "ConfigKit: Could not evaluate expression for '$(entry.name)': " *
                "$(repr(expr_str)). Error: $err"
            ))
        end
    end

    result isa Number || throw(ArgumentError(
        "ConfigKit: Expression for '$(entry.name)' did not evaluate to a number. " *
        "Got $(repr(result)) (type $(typeof(result)))."
    ))

    return result
end

function _expression_symbols(ex)
    out = Set{Symbol}()
    _collect_expression_symbols!(out, ex)
    return out
end

function _collect_expression_symbols!(out::Set{Symbol}, ex::Symbol)
    push!(out, ex)
    return out
end

function _collect_expression_symbols!(out::Set{Symbol}, ex::Expr)
    if ex.head === :call
        for arg in Iterators.drop(ex.args, 1)
            _collect_expression_symbols!(out, arg)
        end
    elseif ex.head === :.
        return out
    else
        for arg in ex.args
            _collect_expression_symbols!(out, arg)
        end
    end
    return out
end

_collect_expression_symbols!(out::Set{Symbol}, _) = out
