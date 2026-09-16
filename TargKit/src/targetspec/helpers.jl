# ============================================================
# Helpers — filter_flags (requires yspec metadata from SpecKit)
# ============================================================

"""
    filter_flags(ts::TargetSet, flag::Symbol) -> TargetSet

Filter a TargetSet to only targets whose dimension values match the given flag group.
Requires that the TargetSet has yspec metadata with flags defined.
"""
function filter_flags(ts::TargetSet, flag::Symbol)
    meta = ts.metadata
    isnothing(meta) && error("filter_flags requires yspec metadata")
    hasproperty(meta, :flags) || error("filter_flags requires yspec metadata with flags")
    haskey(meta.flags, flag) || error("Unknown flag: :$flag")

    flag_values = meta.flags[flag]

    mask = map(eachrow(ts.df)) do row
        for (col_name, col_spec) in meta.columns
            !isnothing(col_spec.values) || continue
            col_name in propertynames(ts.df) || continue
            val = getproperty(row, col_name)
            val in flag_values && return true
        end
        :name in propertynames(ts.df) && row.name in flag_values && return true
        false
    end

    TargetSet(ts.df[mask, :], ts.loss, ts.metadata)
end
