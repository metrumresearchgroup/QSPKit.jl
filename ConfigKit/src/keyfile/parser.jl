# YAML Parser for ConfigKit
# Handles parsing of Parameters, Variables, and metadata from YAML files.

"""
    load_keyfile(path; variant=nothing, strict=true)

Load a YAML keyfile from disk and return a `KeyfileAccessor`.

When `strict=true`, unsupported fields inside Parameters, Variables, and
Constants entries are rejected. When `strict=false`, unsupported entry fields
are ignored.
"""
function load_keyfile(path::String; variant::Union{Symbol, String, Nothing}=nothing, strict::Bool=true)
    if !isfile(path)
        throw(ArgumentError("Keyfile not found: $path"))
    end

    # Load raw YAML using ordered dicts to preserve structure
    raw_data = YAML.load_file(path; dicttype=OrderedDict{String, Any})

    return parse_keyfile_data(raw_data, path; variant=variant, strict=strict)
end

function parse_keyfile_data(data::AbstractDict, source_path::String; variant=nothing, strict=true)
    # 1. Parse Parameters
    params_dict = OrderedDict{Symbol, ParameterEntry}()
    raw_params = get(data, "Parameters", OrderedDict())

    for (key, entry_data) in raw_params
        sym_key = Symbol(key)

        # Normalize simple scalar values to dict format
        normalized_data = entry_data isa AbstractDict ? entry_data : Dict{String,Any}("value" => entry_data)
        active_data = resolve_variant(normalized_data, variant)

        # Get Raw Value
        val_raw = get(active_data, "value", nothing)

        # Unit (Use getMTKUnit for DQ compatibility)
        unit_original = get(active_data, "unit", "")
        unit_val = getMTKUnit(unit_original)

        # Metadata
        metadata = Dict{Symbol, Any}()
        unit_original === nothing || isempty(strip(string(unit_original))) ||
            (metadata[:unit_original] = string(unit_original))
        # ALLOWED FIELDS: desc is alias for description, convert specifies target unit for conversion
        allowed_fields = ["value", "unit", "variants", "description", "desc", "label", "bounds", "convert", "Implicit", "abbr", "source"]
        for (mk, mv) in active_data
            if strict && !(mk in allowed_fields)
                error("ConfigKit: Parameter '$key' has unknown field '$mk'. " *
                      "Allowed fields are: $(join(allowed_fields, ", "))")
            end
            if mk in ["description", "desc", "label", "bounds", "abbr", "convert", "source"]
                # Normalize "desc" to "description"
                norm_key = mk == "desc" ? :description : Symbol(mk)
                metadata[norm_key] = mv
            end
        end

        if get(active_data, "Implicit", false)
            metadata[:is_implicit] = true
        end

        # Track if value is an expression
        is_expr = val_raw isa String
        if is_expr
            try
                parsed = Meta.parse(val_raw)
                is_expr = !(parsed isa Number)
            catch
                is_expr = true
            end
        end
        if is_expr
            metadata[:expression] = val_raw
        end

        params_dict[sym_key] = ParameterEntry(
            sym_key,
            val_raw,
            unit_val,
            val_raw,
            metadata,
            nothing
        )
    end

    # 2. Process Variables
    vars_dict = OrderedDict{Symbol, ParameterEntry}()
    raw_vars = get(data, "Variables", OrderedDict())

    for (key, entry_data) in raw_vars
        sym_key = Symbol(key)

        # Normalize simple scalar values to dict format
        normalized_data = entry_data isa AbstractDict ? entry_data : Dict{String,Any}("initial" => entry_data)
        active_data = resolve_variant(normalized_data, variant)

        val_raw = get(active_data, "initial", get(active_data, "value", 0.0))
        # Unit (Use getMTKUnit for DQ compatibility)
        unit_original = get(active_data, "unit", "")
        unit_val = getMTKUnit(unit_original)

        # Validate allowed fields for Variables
        allowed_var_fields = ["initial", "value", "unit", "variants", "description", "desc", "label", "guess", "abbr"]
        for (mk, _) in active_data
            if strict && !(mk in allowed_var_fields)
                error("ConfigKit: Variable '$key' has unknown field '$mk'. " *
                      "Allowed fields are: $(join(allowed_var_fields, ", "))")
            end
        end

        metadata = Dict{Symbol, Any}()
        unit_original === nothing || isempty(strip(string(unit_original))) ||
            (metadata[:unit_original] = string(unit_original))
        if haskey(active_data, "guess"); metadata[:guess] = active_data["guess"]; end

        # Capture description/label/abbr for variables too (desc is alias for description)
        for field in ["description", "desc", "label", "abbr"]
            if haskey(active_data, field)
                norm_key = field == "desc" ? :description : Symbol(field)
                metadata[norm_key] = active_data[field]
            end
        end

        vars_dict[sym_key] = ParameterEntry(
            sym_key,
            val_raw,
            unit_val,
            val_raw,
            metadata,
            nothing
        )
    end

    # 3. Process Constants
    consts_dict = OrderedDict{Symbol, ParameterEntry}()
    raw_consts = get(data, "Constants", OrderedDict())

    for (key, entry_data) in raw_consts
        sym_key = Symbol(key)
        # Constants don't support variants - they're constant across all conditions
        active_data = entry_data isa AbstractDict ? entry_data : Dict("value" => entry_data)

        val_raw = get(active_data, "value", entry_data)
        unit_original = get(active_data, "unit", "")
        unit_val = getMTKUnit(unit_original)

        # Validate allowed fields for Constants
        allowed_const_fields = ["value", "unit", "description", "desc", "label", "abbr"]
        for (mk, _) in active_data
            if strict && !(mk in allowed_const_fields)
                error("ConfigKit: Constant '$key' has unknown field '$mk'. " *
                      "Allowed fields are: $(join(allowed_const_fields, ", "))")
            end
        end

        metadata = Dict{Symbol, Any}()
        unit_original === nothing || isempty(strip(string(unit_original))) ||
            (metadata[:unit_original] = string(unit_original))
        for field in ["description", "desc", "label", "abbr"]
            if haskey(active_data, field)
                norm_key = field == "desc" ? :description : Symbol(field)
                metadata[norm_key] = active_data[field]
            end
        end

        consts_dict[sym_key] = ParameterEntry(
            sym_key,
            val_raw,
            unit_val,
            val_raw,
            metadata,
            nothing
        )
    end

    return KeyfileAccessor(params_dict, vars_dict, consts_dict, Dict{Symbol,Any}(), source_path)
end

function resolve_variant(data, variant)
    if isnothing(variant) || !isa(data, AbstractDict) || !haskey(data, "variants")
        return data
    end
    variants_block = data["variants"]
    variant_key = String(variant)
    if haskey(variants_block, variant_key)
        override = variants_block[variant_key]
        if override isa AbstractDict
            # Merge the override values into a copy of data
            result = copy(data)
            for (k, v) in override
                result[k] = v
            end
            return result
        else
            # Simple value override
            result = copy(data)
            result["value"] = override
            return result
        end
    else
        return data
    end
end
