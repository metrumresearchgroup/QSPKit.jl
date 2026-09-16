# ============================================================
# ggplot2 Escape Hatch — gg() for unwrapped functions
# ============================================================

"""
    gg(fn_name::Symbol, args...; kwargs...) -> GGLayer

Generic escape hatch to call any ggplot2 function not yet wrapped.

# Example
```julia
p + gg(:geom_density_ridges; scale=0.9)
p + gg(:annotation_logticks; sides="bl")
```
"""
function gg(fn_name::Symbol, args...; kwargs...)
    robj = _rcall_gg(fn_name, args, kwargs)
    GGLayer(robj, fn_name)
end

"""
    r_gg(fn_name::Symbol, args...; kwargs...) -> GGLayer

Alias for `gg()` — generic escape hatch to call any ggplot2 function.
"""
const r_gg = gg

"""
    factor(x; levels=nothing, labels=nothing, ordered=false)

Two usage modes:

**Inside `aes()` — pass a Symbol for lazy column evaluation:**
```julia
aes(color = factor(:DOSE))
aes(color = factor(:DOSE; levels = [10, 100, 1000], ordered = true))
```
Returns an R call expression that ggplot2 evaluates against the plot data,
equivalent to `aes(color = factor(DOSE))` in R.

**On actual data — pass a vector to convert a column:**
```julia
df.DOSE = factor(df.DOSE; levels = [10, 100, 1000])
```
Calls R's `base::factor()` immediately and returns an R factor object.
"""
function factor(x; levels=nothing, labels=nothing, ordered=false)
    _require_r()
    if x isa Symbol
        # Build a lazy R call expression: factor(col_name, ...) for use in aes().
        # ggplot2 evaluates this against the data frame, same as rlang::sym() for :col.
        parts = ["rlang::sym('$(x)')"]
        if levels !== nothing
            lvl_str = join(map(l -> l isa AbstractString ? "'$l'" : string(l), levels), ", ")
            push!(parts, "levels = c($lvl_str)")
        end
        push!(parts, "ordered = $(ordered ? "TRUE" : "FALSE")")
        return _reval("rlang::call2('factor', $(join(parts, ", ")))")
    else
        r_fn = _reval("base::factor")
        kw = Pair{Symbol, Any}[:ordered => ordered]
        levels !== nothing && push!(kw, :levels => levels)
        labels !== nothing && push!(kw, :labels => labels)
        _rcall(r_fn, x; kw...)
    end
end
export factor
