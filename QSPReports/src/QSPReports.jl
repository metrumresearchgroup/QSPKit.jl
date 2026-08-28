"""
    QSPReports

Report-building primitives for QSPKit workflows: ranked action lists, option
provenance summaries, parameter-update files, metadata overlays, and
ConfigKit-backed parameter tables.
"""
module QSPReports

using DataFrames
using YAML
using ConfigKit

export report_action, push_action!, rank_actions, print_action_list
export print_section, print_key_values
export option_resolution_rows, print_option_resolution
export ParameterRowKey, parameter_key, initial_key, constant_key
export ParameterUpdate, model_update, parameter_update, optimization_update
export save_parameter_update, load_parameter_update
export ParameterOverlay, parameter_overlay, parameter_metadata_overlay, load_parameter_metadata
export parameter_table

const ACTION_PRIORITY_RANK = Dict(:critical => 1, :high => 2, :medium => 3,
                                  :low => 4, :info => 5)

"""
    report_action(priority, category, action, message, reason)

Create the canonical named-tuple representation of a recommended report
action.
"""
function report_action(priority::Symbol, category::Symbol, action::Symbol,
                       message::AbstractString, reason::AbstractString)
    return (
        priority = priority,
        category = category,
        action = action,
        message = String(message),
        reason = String(reason),
    )
end

"""Append a report action unless the same category, action, and message exists."""
function push_action!(actions::Vector{NamedTuple}, priority::Symbol,
                      category::Symbol, action::Symbol,
                      message::AbstractString, reason::AbstractString)
    candidate = report_action(priority, category, action, message, reason)
    any(a -> a.category === candidate.category &&
             a.action === candidate.action &&
             a.message == candidate.message, actions) ||
        push!(actions, candidate)
    return actions
end

"""
    rank_actions(actions; max_actions=10)

Sort actions by priority and stable identifying fields, returning at most
`max_actions` rows with one-based `rank` fields.
"""
function rank_actions(actions::AbstractVector{<:NamedTuple}; max_actions::Int=10)
    max_actions >= 0 || throw(ArgumentError("max_actions must be non-negative; got $max_actions"))
    sorted = collect(actions)
    sort!(sorted; by=a -> (get(ACTION_PRIORITY_RANK, a.priority, typemax(Int)),
                           string(a.category), string(a.action), a.message))
    ranked = NamedTuple[]
    for (i, action) in enumerate(sorted[1:min(max_actions, length(sorted))])
        push!(ranked, merge((rank=i,), action))
    end
    return ranked
end

"""Print ranked report actions to `io` in a compact numbered list."""
function print_action_list(io::IO, actions::AbstractVector{<:NamedTuple};
                           max_actions::Int=10,
                           indent::AbstractString="  ")
    max_actions >= 0 || throw(ArgumentError("max_actions must be non-negative; got $max_actions"))
    ranked = all(a -> hasproperty(a, :rank), actions) ?
        collect(actions[1:min(max_actions, length(actions))]) :
        rank_actions(actions; max_actions=max_actions)
    for action in ranked
        println(io, indent, action.rank, ". [", action.priority, "] ",
                action.message, " (", action.reason, ")")
    end
    return nothing
end

"""Print a blank line followed by a report section title."""
function print_section(io::IO, title::AbstractString)
    println(io)
    println(io, title)
    return nothing
end

"""Print key/value pairs as one indented, separator-delimited line."""
function print_key_values(io::IO, rows::AbstractVector{<:Pair};
                          indent::AbstractString="  ",
                          separator::AbstractString=", ")
    isempty(rows) && return nothing
    parts = String[string(first(row), "=", last(row)) for row in rows]
    println(io, indent, join(parts, separator))
    return nothing
end

"""
    option_resolution_rows(resolved, defaults; kwargs...)

Describe each selected configuration field as user-provided, smart-replaced,
or default, returning report-ready named tuples.
"""
function option_resolution_rows(resolved, defaults;
                                smart_replaced::AbstractSet{Symbol}=Set{Symbol}(),
                                fields = fieldnames(typeof(resolved)),
                                value_formatter = (_field, value) -> string(value))
    rows = NamedTuple[]
    for field in fields
        value = getfield(resolved, field)
        default = getfield(defaults, field)
        provenance = if field in smart_replaced
            :smart
        elseif value != default
            :user
        else
            :default
        end
        push!(rows, (
            field = field,
            value = String(value_formatter(field, value)),
            provenance = provenance,
        ))
    end
    return rows
end

"""Print [`option_resolution_rows`](@ref) with aligned values and provenance."""
function print_option_resolution(io::IO, title::AbstractString, resolved, defaults;
                                 smart_replaced::AbstractSet{Symbol}=Set{Symbol}(),
                                 fields = fieldnames(typeof(resolved)),
                                 value_formatter = (_field, value) -> string(value),
                                 indent::AbstractString="  ",
                                 min_value_width::Int=14)
    rows = option_resolution_rows(resolved, defaults;
        smart_replaced=smart_replaced,
        fields=fields,
        value_formatter=value_formatter)
    println(io, title)
    isempty(rows) && return nothing
    max_field = maximum(length(string(row.field)) for row in rows)
    for row in rows
        println(io, indent,
                rpad(string(row.field), max_field), " = ",
                rpad(row.value, min_value_width), "  [", row.provenance, "]")
    end
    return nothing
end

include("parameter_tables.jl")

end # module QSPReports
