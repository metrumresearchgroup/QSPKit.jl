# Variant Resolution for ConfigKit.jl
# Variant extraction and comparison helpers.

"""
    _normalize_variant_source(source) -> Tuple{Dict, Union{String, Nothing}}

Internal helper to normalize different source types to a raw YAML Dict and optional path.

# Arguments
- `source`: Can be `KeyfileAccessor`, `String` (file path), or `Dict` (raw YAML)

# Returns
- `Tuple{Dict, Union{String, Nothing}}`: (raw_yaml_dict, source_path)
"""
function _normalize_variant_source(source)::Tuple{Dict, Union{String, Nothing}}
    if source isa KeyfileAccessor
        # KeyfileAccessor doesn't store raw YAML, so we need to throw a helpful error
        error("""
            KeyfileAccessor does not store raw YAML data needed for variant comparison.

            Please use one of these alternatives:
            1. Pass the keyfile path: get_variant_diff("path/to/keys.yml"; variant_a=:human, variant_b=:mouse)
            2. Pass raw YAML Dict: get_variant_diff(YAML.load_file("keys.yml"); variant_a=:human, variant_b=:mouse)
            """)
    elseif source isa AbstractString
        return (YAML.load_file(source; dicttype=OrderedDict{String, Any}), source)
    elseif source isa AbstractDict
        return (source, nothing)
    else
        error("Unsupported source type: $(typeof(source)). Expected String (path), Dict, or KeyfileAccessor.")
    end
end

"""
    _try_numeric_comparison(a, b) -> Tuple{Union{Float64, Nothing}, Union{Float64, Nothing}}

Internal helper to compute numeric difference and ratio for two values.

# Returns
- `(difference, ratio)` where difference = b - a and ratio = b / a
- Returns `(nothing, nothing)` if either value is non-numeric
"""
function _try_numeric_comparison(a, b)::Tuple{Union{Float64, Nothing}, Union{Float64, Nothing}}
    if a isa Number && b isa Number
        diff = Float64(b - a)
        ratio = (a != 0) ? Float64(b / a) : nothing
        return (diff, ratio)
    end
    return (nothing, nothing)
end

"""
    _get_entry_metadata(entry::Dict) -> Tuple{Any, String}

Extract unit and description from a keyfile entry.
"""
function _get_entry_metadata(entry::AbstractDict)
    unit = nothing
    desc = nothing

    if haskey(entry, "unit")
        try
            unit = getMTKUnit(entry["unit"])
        catch
            unit = nothing
        end
    end

    if haskey(entry, "desc")
        desc = entry["desc"]
    end

    return (unit, desc)
end

"""
    get_variant_diff(source; variant_a, variant_b=nothing, only_different=true) -> VariantDiffResult

Compare parameter and variable values between two variants, or between a variant and base values.

# Arguments
- `source`: Source of keyfile data. Can be:
  - `String`: Path to YAML keyfile
  - `Dict`: Raw YAML dictionary (from `YAML.load_file`)

# Keyword Arguments
- `variant_a::Symbol`: First variant to compare (required)
- `variant_b::Union{Symbol, Nothing}=nothing`: Second variant to compare.
  If `nothing`, compares `variant_a` against base values (top-level `value`/`initial`)
- `only_different::Bool=true`: If true, only include entries where values differ.
  If false, include all entries that exist in both variants.

# Returns
- `VariantDiffResult`: Structured result with iteration and indexing support

# Examples

## Compare two variants
```julia
# From file path
diff = get_variant_diff("keys.yml"; variant_a=:human, variant_b=:mouse)

# From raw YAML
yaml = YAML.load_file("keys.yml")
diff = get_variant_diff(yaml; variant_a=:human, variant_b=:mouse)

# Iterate over differences
for entry in diff
    println("\$(entry.name): \$(entry.value_a) → \$(entry.value_b) (ratio: \$(entry.ratio))")
end
```

## Compare variant to base values
```julia
# See what the 'human' variant changes from base
diff = get_variant_diff("keys.yml"; variant_a=:human)

# Access specific parameter
if haskey(diff, :CL)
    cl_diff = diff[:CL]
    println("CL changed by \$(cl_diff.ratio)x")
end
```

## Include all entries (not just different ones)
```julia
diff = get_variant_diff("keys.yml"; variant_a=:human, variant_b=:mouse, only_different=false)
```

# See also
- [`list_available_variants`](@ref): List all variants in a keyfile
- [`load_keyfile`](@ref): Load keyfile with specific variant
"""
function get_variant_diff(source; variant_a::Symbol, variant_b::Union{Symbol, Nothing}=nothing, only_different::Bool=true)::VariantDiffResult
    # Normalize source
    keyfile, source_path = _normalize_variant_source(source)

    variant_a_str = string(variant_a)
    variant_b_str = isnothing(variant_b) ? nothing : string(variant_b)
    variant_b_label = isnothing(variant_b) ? :base : variant_b

    entries = VariantDiffEntry[]

    # Process Parameters block
    if haskey(keyfile, "Parameters")
        for (param_name, param_entry) in keyfile["Parameters"]
            if !isa(param_entry, AbstractDict)
                continue
            end

            entry = _process_variant_entry(
                param_name, param_entry, "value",
                variant_a_str, variant_b_str, :Parameters, only_different
            )
            if !isnothing(entry)
                push!(entries, entry)
            end
        end
    end

    # Process Variables block
    if haskey(keyfile, "Variables")
        for (var_name, var_entry) in keyfile["Variables"]
            if !isa(var_entry, AbstractDict)
                continue
            end

            entry = _process_variant_entry(
                var_name, var_entry, "initial",
                variant_a_str, variant_b_str, :Variables, only_different
            )
            if !isnothing(entry)
                push!(entries, entry)
            end
        end
    end

    # Sort entries by name for consistent output
    sort!(entries, by=e -> string(e.name))

    return VariantDiffResult(variant_a, variant_b_label, entries, source_path)
end

"""
    _process_variant_entry(name, entry, value_field, variant_a_str, variant_b_str, category, only_different)

Internal helper to process a single parameter/variable entry for variant comparison.
"""
function _process_variant_entry(
    name::AbstractString,
    entry::AbstractDict,
    value_field::String,
    variant_a_str::String,
    variant_b_str::Union{String, Nothing},
    category::Symbol,
    only_different::Bool
)::Union{VariantDiffEntry, Nothing}

    # Get unit and description metadata
    unit, desc = _get_entry_metadata(entry)

    # Check if entry has variants
    if !haskey(entry, "variants")
        return nothing  # No variants to compare
    end

    variants = entry["variants"]
    if !isa(variants, AbstractDict)
        return nothing
    end

    # Get value_a from variant_a
    if !haskey(variants, variant_a_str)
        return nothing  # variant_a doesn't exist for this entry
    end

    variant_a_entry = variants[variant_a_str]
    # Handle both scalar (invitro: 230.0) and dict (invitro: {value: 230.0}) formats
    value_a = if isa(variant_a_entry, AbstractDict)
        haskey(variant_a_entry, value_field) ? variant_a_entry[value_field] : return nothing
    else
        variant_a_entry  # scalar value directly
    end

    # Get value_b from variant_b (or base value if variant_b is nothing)
    local value_b
    if isnothing(variant_b_str)
        # Compare to base value (top-level value/initial)
        if haskey(entry, value_field)
            value_b = entry[value_field]
        else
            return nothing  # No base value to compare against
        end
    else
        # Compare to another variant
        if !haskey(variants, variant_b_str)
            return nothing  # variant_b doesn't exist for this entry
        end
        variant_b_entry = variants[variant_b_str]
        # Handle both scalar and dict formats
        value_b = if isa(variant_b_entry, AbstractDict)
            haskey(variant_b_entry, value_field) ? variant_b_entry[value_field] : return nothing
        else
            variant_b_entry  # scalar value directly
        end
    end

    # Check if values differ (if only_different is true)
    if only_different && value_a == value_b
        return nothing
    end

    # Calculate numeric comparison
    diff, ratio = _try_numeric_comparison(value_a, value_b)

    return VariantDiffEntry(
        Symbol(name),
        category,
        value_a,
        value_b,
        diff,
        ratio,
        unit,
        desc
    )
end

# Legacy compatibility
"""
    get_variant_diff(variant1::Symbol, variant2::Symbol; keyfile) -> VariantDiffResult

Legacy function signature for backwards compatibility.

Accepts keyfile as either a String path or a Dict.

# Example
```julia
# From file path
diffs = get_variant_diff(:human, :mouse; keyfile="keys.yml")

# From raw YAML
diffs = get_variant_diff(:human, :mouse; keyfile=yaml_dict)

# New style (recommended)
result = get_variant_diff("keys.yml"; variant_a=:human, variant_b=:mouse)
```
"""
function get_variant_diff(variant1::Symbol, variant2::Symbol; keyfile)::VariantDiffResult
    # Call new implementation - handles both String paths and Dict
    return get_variant_diff(keyfile; variant_a=variant1, variant_b=variant2, only_different=true)
end

"""
    list_available_variants(keyfile_path::String) -> Set{Symbol}

List all variants defined across all parameters and variables in a keyfile.

# Arguments
- `keyfile_path::String` - Path to the keyfile

# Returns
- `Set{Symbol}` - Set of variant names found in the keyfile

# Example
```julia
variants = list_available_variants("keys.yml")
# Returns: Set([:human, :mouse, :rat, :default])
```
"""
function list_available_variants(keyfile_path::String)::Set{Symbol}
    keyfile = YAML.load_file(keyfile_path; dicttype=OrderedDict{String, Any})
    string_variants = list_available_variants(keyfile)
    return Set{Symbol}(Symbol(v) for v in string_variants)
end

"""
    list_available_variants(keyfile::Dict) -> Set{String}

List all variants defined across all parameters and variables in a keyfile.

# Arguments
- `keyfile::Dict` - Parsed keyfile (raw YAML Dict)

# Returns
- `Set{String}` - Set of variant names found in the keyfile

# Example
```julia
yaml = YAML.load_file("keys.yml")
variants = list_available_variants(yaml)
# Returns: Set(["human", "mouse", "rat", "default"])
```
"""
function list_available_variants(keyfile::AbstractDict)::Set{String}
    all_variants = Set{String}()

    # Collect from Parameters
    if haskey(keyfile, "Parameters")
        for (param_name, param_entry) in keyfile["Parameters"]
            if haskey(param_entry, "variants")
                for variant_name in keys(param_entry["variants"])
                    push!(all_variants, variant_name)
                end
            end
        end
    end

    # Collect from Variables
    if haskey(keyfile, "Variables")
        for (var_name, var_entry) in keyfile["Variables"]
            if haskey(var_entry, "variants")
                for variant_name in keys(var_entry["variants"])
                    push!(all_variants, variant_name)
                end
            end
        end
    end

    return all_variants
end
