# ============================================================
# Time unit helpers (base unit = days)
# ============================================================

"""
    weeks(n)

Convert weeks to days: `n * 7.0`.
"""
weeks(n) = n * 7.0

"""
    days(n)

Identity conversion — returns `Float64(n)`.
"""
days(n) = Float64(n)

"""
    hours(n)

Convert hours to days: `n / 24.0`.
"""
hours(n) = n / 24.0
