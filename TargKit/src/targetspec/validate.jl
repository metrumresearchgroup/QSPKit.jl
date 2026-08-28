# ============================================================
# Validation
# ============================================================

"""
    validate(ts::TargetSet) -> Bool

Validate a TargetSet:
- All target names are unique
- All values are finite (not NaN/Inf), unless explicitly NaN for missing
- Ranges are valid (lower < upper where both exist)
- Required columns exist
"""
function validate(ts::TargetSet)
    df = ts.df
    errors = String[]

    # Check required columns
    for col in (:name, :value)
        col in propertynames(df) || push!(errors, "Missing required column: :$col")
    end

    !isempty(errors) && error("TargetSet validation failed:\n" * join(errors, "\n"))

    # Check unique names
    names_vec = df.name
    if length(unique(names_vec)) != length(names_vec)
        dupes = [n for n in names_vec if count(==(n), names_vec) > 1]
        push!(errors, "Duplicate target names: $(unique(dupes))")
    end

    # Check values
    for row in eachrow(df)
        v = row.value
        if v isa Real && (isinf(v))
            push!(errors, "Target :$(row.name) has Inf value")
        end
    end

    # Check ranges
    if :lower in propertynames(df) && :upper in propertynames(df)
        for row in eachrow(df)
            lo = row.lower
            hi = row.upper
            has_lo = lo isa Real && !isnan(lo)
            has_hi = hi isa Real && !isnan(hi)
            if has_lo && has_hi && lo > hi
                push!(errors, "Target :$(row.name) has lower ($(lo)) > upper ($(hi))")
            end
        end
    end

    if !isempty(errors)
        error("TargetSet validation failed:\n" * join(errors, "\n"))
    end

    return true
end
