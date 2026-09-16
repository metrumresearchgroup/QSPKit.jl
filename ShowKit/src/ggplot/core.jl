# ============================================================
# ggplot2 Core — ggplot(), aes()
# ============================================================

"""
    ggplot(data::DataFrame; mapping=nothing) -> GGPlot
    ggplot(data::DataFrame, mapping::GGLayer) -> GGPlot

Create a ggplot2 plot object from a Julia DataFrame.

# Example
```julia
p = ggplot(df, aes(x=:TIME, y=:DV)) + geom_point()
```
"""
function ggplot(data::DataFrame, mapping::GGLayer)
    _require_ggplot2()
    # Validate aes column references against DataFrame
    if !isempty(mapping.columns)
        df_cols = Symbol.(names(data))
        for col in mapping.columns
            if col ∉ df_cols
                error("ShowKit: aes() references column :$col but DataFrame only has columns: $(df_cols)")
            end
        end
    end
    r_data = _robject(plot_data(data))
    r_fn = _reval("ggplot2::ggplot")
    robj = _rcall(r_fn, r_data, mapping.robject)
    GGPlot(robj)
end

function ggplot(data::DataFrame; mapping=nothing)
    _require_ggplot2()
    r_data = _robject(plot_data(data))
    r_fn = _reval("ggplot2::ggplot")
    if isnothing(mapping)
        robj = _rcall(r_fn, r_data)
    else
        robj = _rcall(r_fn, r_data, mapping.robject)
    end
    GGPlot(robj)
end

# ggplot() with no data (for layered specs)
function ggplot()
    _require_ggplot2()
    r_fn = _reval("ggplot2::ggplot")
    GGPlot(_rcall(r_fn))
end

"""
    aes(; kwargs...) -> GGLayer

Define aesthetic mappings for ggplot2. Column names are specified as Symbols.

# Example
```julia
aes(x=:TIME, y=:DV, color=:STUDY)
```
"""
function aes(; kwargs...)
    _require_ggplot2()
    r_fn = _reval("ggplot2::aes")

    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rk = Symbol(_julia_to_r_name(k))
        # Convert Julia Symbols to R symbols (column references)
        rv = if v isa Symbol
            _reval("rlang::sym('$(v)')")
        elseif v isa AbstractString
            _reval("rlang::sym('$(v)')")
        else
            v
        end
        push!(r_kwargs, rk => rv)
    end

    # Track which columns are referenced (Symbols/Strings = column names)
    cols = Symbol[]
    for (k, v) in kwargs
        if v isa Symbol
            push!(cols, v)
        elseif v isa AbstractString
            push!(cols, Symbol(v))
        end
    end

    robj = _rcall(r_fn; r_kwargs...)
    GGLayer(robj, :aes, cols)
end
