# ============================================================
# Plot data boundary helpers
# ============================================================

const DEFAULT_PLOT_CATEGORICAL_COLUMNS = Set(Symbol[
    :ID, :SUBJID, :PKID,
    :CHAIN, :PARAM, :METHOD,
    :ENDPOINT, :ENDPOINT_LABEL, :FACET_LABEL,
    :ETA_NAME, :ETA_COL,
    :AGE_GROUP, :ROUTE, :NOMTNUM_LABEL,
    :STDY, :STYP, :PID, :SEX, :RACE,
])

function _plot_string_or_missing(value)
    ismissing(value) && return missing
    return string(value)
end

"""
    plot_data(data; categorical=DEFAULT_PLOT_CATEGORICAL_COLUMNS)

Return a copy of `data` with common grouping / faceting columns converted to
strings before sending it to R plotting packages.
"""
function plot_data(data::DataFrame;
                   categorical=DEFAULT_PLOT_CATEGORICAL_COLUMNS)
    out = copy(data)
    names_present = Set(Symbol.(names(out)))
    for col in categorical
        col in names_present || continue
        out[!, col] = _plot_string_or_missing.(out[!, col])
    end
    return out
end

export plot_data
