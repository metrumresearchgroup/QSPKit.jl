# Core Data Structures for ConfigKit
# Defines types for storage, access, and pretty printing of keyfile data.

# ------------------------------------------------------------------
# 1. Core Entry Type
# ------------------------------------------------------------------

"""
    ParameterEntry

Represents a single parameter or variable entry from a keyfile.

# Fields
- `name`: Symbol identifier.
- `value`: Numeric value or expression string.
- `unit`: Unitful unit (or `NoUnits`).
- `value_original`: The raw value from YAML (string expression or number).
- `metadata`: Dictionary of additional fields (description, guess, etc.).
- `equation`: (Optional) The symbolic equation if this is an implicit parameter.
"""
struct ParameterEntry
    name::Symbol
    value::Any
    unit::Any
    value_original::Any
    metadata::Dict{Symbol, Any}
    equation::Any
end

# Property access: entry.description, entry.source, entry.bounds, etc.
# Standard fields are direct struct fields; validated metadata keys are forwarded.
const _ENTRY_STRUCT_FIELDS = fieldnames(ParameterEntry)

function Base.getproperty(entry::ParameterEntry, s::Symbol)
    if s in _ENTRY_STRUCT_FIELDS
        return getfield(entry, s)
    else
        meta = getfield(entry, :metadata)
        haskey(meta, s) && return meta[s]
        return nothing
    end
end

function Base.propertynames(entry::ParameterEntry)
    (fieldnames(ParameterEntry)..., keys(getfield(entry, :metadata))...)
end

# ------------------------------------------------------------------
# 2. View Wrappers (For Dot-Access & Dictionary Behavior)
# ------------------------------------------------------------------

"""
    ParametersView

A view into a dictionary of ParameterEntries that allows both
dot-syntax (`view.key`) and bracket-syntax (`view[:key]`).
"""
struct ParametersView
    data::OrderedCollections.OrderedDict{Symbol, ParameterEntry}
end

# Dot access: view.CL
function Base.getproperty(view::ParametersView, sym::Symbol)
    if sym === :data
        return getfield(view, :data)
    elseif haskey(view.data, sym)
        return view.data[sym]
    else
        # Allow fallback to standard properties if not found in data
        return getfield(view, sym)
    end
end

# Bracket access: view[:CL]
Base.getindex(view::ParametersView, k::Symbol) = view.data[k]
Base.getindex(view::ParametersView, k::String) = view.data[Symbol(k)]

# Dictionary interface
Base.propertynames(view::ParametersView) = Tuple(keys(view.data))
Base.length(view::ParametersView) = length(view.data)
Base.iterate(view::ParametersView, state...) = iterate(view.data, state...)
Base.keys(view::ParametersView) = keys(view.data)
Base.values(view::ParametersView) = values(view.data)
Base.haskey(view::ParametersView, k) = haskey(view.data, k)

# ------------------------------------------------------------------
# 3. Main Accessor
# ------------------------------------------------------------------

"""
    KeyfileAccessor

The main container returned by `load_keyfile`.

# Fields
- `Parameters`: A `ParametersView` of the parameters.
- `Variables`: A `ParametersView` of the variables.
- `Constants`: A `ParametersView` of the constants.
- `source_path`: Path to the loaded file.
"""
struct KeyfileAccessor
    Parameters::ParametersView
    Variables::ParametersView
    Constants::ParametersView
    __internal__metadata::Dict{Symbol, Any} # Kept for legacy compatibility
    source_path::String
end

# Constructor to wrap Dicts into Views automatically
function KeyfileAccessor(
    params::OrderedCollections.OrderedDict{Symbol, ParameterEntry},
    vars::OrderedCollections.OrderedDict{Symbol, ParameterEntry},
    consts::OrderedCollections.OrderedDict{Symbol, ParameterEntry},
    meta::Dict{Symbol, Any},
    path::String
)
    kf = KeyfileAccessor(ParametersView(params), ParametersView(vars), ParametersView(consts), meta, path)
    if isdefined(@__MODULE__, :_register_keyfile_value_context!)
        _register_keyfile_value_context!(kf)
    end
    return kf
end

# ------------------------------------------------------------------
# 4. Property Accessors (API Helpers)
# ------------------------------------------------------------------

function Base.getproperty(k::KeyfileAccessor, s::Symbol)
    if s === :parameter_defaults
        # Generate Dict{Symbol, Value} for parameters with non-missing values
        return Dict{Any, Any}(p.name => p.value for p in values(k.Parameters) if !ismissing(p.value))
    elseif s === :variable_initials
        # Generate Dict{Symbol, Value} for variables
        return Dict{Any, Any}(v.name => v.value for v in values(k.Variables))
    else
        return getfield(k, s)
    end
end

# ------------------------------------------------------------------
# 4b. Bulk Accessor Functions
# ------------------------------------------------------------------

"""
    get_values(kf::KeyfileAccessor, names::Vector{Symbol}; convert=true) → Vector{Float64}

Extract parameter values for the given names, in order.
Throws `KeyError` if a name is not found in `kf.Parameters`.
Expression-valued parameters are evaluated with `value(kf, name)`.

# Example
```julia
kf = load_keyfile("keyfile.yml")
get_values(kf, [:CL, :V1])  # → [5.0, 50.0]
```
"""
function get_values(kf::KeyfileAccessor, names::Vector{Symbol}; convert::Bool=true)
    out = Float64[]
    for name in names
        haskey(kf.Parameters.data, name) || throw(KeyError(name))
        entry = kf.Parameters.data[name]
        push!(out, Float64(_resolve_entry_value(kf, entry; convert=convert, stack=[name])))
    end
    return out
end

"""
    get_bounds(kf::KeyfileAccessor, names::Vector{Symbol}) → NamedTuple{(:lb, :ub)}

Extract lower and upper bounds for the given parameter names.
Throws an error if any parameter does not have `:bounds` in its metadata.

# Example
```julia
kf = load_keyfile("keyfile.yml")
get_bounds(kf, [:CL, :V1])  # → (lb = [0.1, 1.0], ub = [100.0, 500.0])
```
"""
function get_bounds(kf::KeyfileAccessor, names::Vector{Symbol})
    lb = Float64[]
    ub = Float64[]
    for name in names
        entry = kf.Parameters[name]
        if !haskey(entry.metadata, :bounds)
            error("Parameter :$name has no bounds defined in keyfile")
        end
        bounds = entry.metadata[:bounds]
        push!(lb, Float64(bounds[1]))
        push!(ub, Float64(bounds[2]))
    end
    return (lb = lb, ub = ub)
end

"""
    get_all_values(kf::KeyfileAccessor) → Dict{Symbol, Float64}

Extract all numeric parameter values as a typed `Dict{Symbol, Float64}`.
Skips expression-valued parameters (non-numeric values).

# Example
```julia
kf = load_keyfile("keyfile.yml")
params = get_all_values(kf)  # → Dict(:CL => 5.0, :V1 => 50.0, ...)
```
"""
function get_all_values(kf::KeyfileAccessor)
    d = Dict{Symbol, Float64}()
    for (name, entry) in kf.Parameters
        if entry.value isa Number
            d[name] = Float64(entry.value)
        end
    end
    return d
end

# ------------------------------------------------------------------
# 5. Pretty Printing & Formatting
# ------------------------------------------------------------------

function _scientific_string(x::Number; digits=3)
    if x == 0
        return "0.0"
    elseif abs(x) < 1e-3 || abs(x) >= 1e4
        return string(round(x, sigdigits=digits+1))
    else
        return string(round(x, digits=digits))
    end
end
_scientific_string(x; kwargs...) = string(x)

function Base.show(io::IO, entry::ParameterEntry)
    # Show expression if value is a string, otherwise show numeric value
    val_str = entry.value isa String ? "Expr($(entry.value))" : _scientific_string(entry.value)
    unit_str = string(entry.unit) == "" ? "" : " $(entry.unit)"
    print(io, "$(entry.name): $val_str$unit_str")
end

function Base.show(io::IO, view::ParametersView)
    n = length(view)
    print(io, "ParametersView with $n entries")
    if n > 0
        println(io, ":")
        # Simple table preview
        limit = 10
        count = 0
        for (k, entry) in view.data
            count += 1
            if count > limit
                println(io, "  ... (and $(n - limit) more)")
                break
            end

            # Show expression if value is a string, otherwise show numeric value
            val_display = entry.value isa String ? "Expr" : _scientific_string(entry.value)
            unit_display = string(entry.unit) == "" ? "-" : string(entry.unit)
            desc = get(entry.metadata, :description, "")

            # Pad for alignment
            k_pad = rpad(string(k), 15)
            v_pad = rpad(val_display, 12)
            u_pad = rpad(unit_display, 10)

            println(io, "  $k_pad $v_pad $u_pad $desc")
        end
    end
end

function Base.show(io::IO, k::KeyfileAccessor)
    print(io, "KeyfileAccessor loaded from \"$(basename(k.source_path))\"\n")
    print(io, "  Parameters: $(length(k.Parameters))\n")
    print(io, "  Variables:  $(length(k.Variables))\n")
    print(io, "  Constants:  $(length(k.Constants))\n")
end

# ------------------------------------------------------------------
# 6. Variant Diff Types
# ------------------------------------------------------------------

"""
    VariantDiffEntry

Represents a single difference between two variants for a parameter or variable.

# Fields
- `name`: Symbol identifier of the parameter/variable
- `category`: `:Parameters` or `:Variables`
- `value_a`: Value in variant A
- `value_b`: Value in variant B
- `difference`: Numeric difference (b - a) or nothing if non-numeric
- `ratio`: Ratio (b / a) or nothing if non-numeric or a == 0
- `unit`: Unit of the parameter/variable (or nothing)
- `description`: Description from the keyfile (or nothing)
"""
struct VariantDiffEntry
    name::Symbol
    category::Symbol
    value_a::Any
    value_b::Any
    difference::Union{Float64, Nothing}
    ratio::Union{Float64, Nothing}
    unit::Any
    description::Union{String, Nothing}
end

"""
    VariantDiffResult

Container for variant comparison results with iteration and indexing support.

# Fields
- `variant_a`: Name of first variant
- `variant_b`: Name of second variant (or `:base` if comparing to base values)
- `entries`: Vector of VariantDiffEntry
- `source_path`: Path to the keyfile (or nothing if from Dict)
"""
struct VariantDiffResult
    variant_a::Symbol
    variant_b::Symbol
    entries::Vector{VariantDiffEntry}
    source_path::Union{String, Nothing}
end

# Iteration interface for VariantDiffResult
Base.length(r::VariantDiffResult) = length(r.entries)
Base.iterate(r::VariantDiffResult, state...) = iterate(r.entries, state...)

# Indexing interface for VariantDiffResult
function Base.getindex(r::VariantDiffResult, name::Symbol)
    for entry in r.entries
        if entry.name == name
            return entry
        end
    end
    throw(KeyError(name))
end

function Base.haskey(r::VariantDiffResult, name::Symbol)
    return any(e -> e.name == name, r.entries)
end

function Base.show(io::IO, entry::VariantDiffEntry)
    val_a = _scientific_string(entry.value_a)
    val_b = _scientific_string(entry.value_b)
    unit_str = isnothing(entry.unit) ? "" : " $(entry.unit)"
    print(io, "$(entry.name): $val_a → $val_b$unit_str")
end

function Base.show(io::IO, r::VariantDiffResult)
    n = length(r.entries)
    print(io, "VariantDiffResult: $(r.variant_a) vs $(r.variant_b) ($n differences)")
    if n > 0
        println(io, ":")
        limit = 10
        for (i, entry) in enumerate(r.entries)
            if i > limit
                println(io, "  ... (and $(n - limit) more)")
                break
            end
            println(io, "  ", entry)
        end
    end
end
