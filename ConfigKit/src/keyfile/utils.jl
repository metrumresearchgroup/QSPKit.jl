# Keyfile Utilities for ConfigKit.jl

"""
    load_yaml_ordered(path::AbstractString) -> OrderedDict{String,Any}
"""
function load_yaml_ordered(path::AbstractString)
    return YAML.load_file(path, dicttype = OrderedCollections.OrderedDict{String, Any})
end

"""
    getMTKUnit(unit_str)

Parse a unit string using Unitful (handling prefixes correctly),
then convert to a DynamicQuantities.Quantity for MTK v11.
Example: "MW" -> Quantity(1.0e6, mass=1, length=2, time=-3)
"""
function getMTKUnit(unit_str)
    str = strip(string(unit_str))
    if isempty(str) || str == "1" || str == "nothing"
        return DQ.Quantity(1.0) # Dimensionless, value 1.0
    end
    try
        # 1. Parse with Unitful to handle prefixes (k, M, m, etc.) robustly
        u_val = Unitful.uparse(str)

        # 2. Convert to DynamicQuantities
        # We multiply by 1.0 to ensure we have a Quantity (1.0 mol/s)
        # instead of just Units (mol/s), which DynamicQuantities cannot convert directly.
        val_with_mag = 1.0 * u_val

        return convert(DQ.Quantity, val_with_mag)
    catch e
        error("ConfigKit: Could not parse unit string '$str'. Error: $e")
    end
end
