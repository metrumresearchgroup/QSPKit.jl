# ============================================================
# pmtables — Table Constructors
# ============================================================

function _prepare_pmtable_data(data::DataFrame)
    prepared = copy(data)
    for column in names(prepared)
        values = prepared[!, column]
        any(value -> value isa Symbol, values) || continue
        prepared[!, column] = map(
            value -> value isa Symbol ? string(value) : value,
            values,
        )
    end
    prepared
end

"""
    _pt_kwargs(cols, kwargs) -> Vector{Pair{Symbol, Any}}

Build the keyword list for a `pt_*` constructor, prepending the `cols`
selection (accepted as a Symbol/String or a vector of either) when given.
Values are converted at the `_rcall_pkg` boundary.
"""
function _pt_kwargs(cols, kwargs)
    r_kwargs = Pair{Symbol, Any}[]
    if !isnothing(cols)
        selection = if cols isa Vector{Symbol}
            join(string.(cols), ",")
        elseif cols isa Vector{String}
            join(cols, ",")
        else
            string(cols)
        end
        push!(r_kwargs, :cols => selection)
    end
    for (k, v) in kwargs
        push!(r_kwargs, k => v)
    end
    return r_kwargs
end

_rcall_pmtables(fn::Symbol, pos_args, kwargs) =
    _rcall_pkg("pmtables", fn, pos_args, kwargs; name_fun=_pmtables_to_r_name)

"""
    st_new(data::DataFrame; kwargs...) -> PMTable

Create a pmtables table from an already summarized data frame.
This is the Julia wrapper for `pmtables::st_new()`, used for Expo-style
analysis tables where the rows have already been assembled.
"""
function st_new(data::DataFrame; kwargs...)
    _require_pmtables()
    r_data = _robject(_prepare_pmtable_data(data))
    robj = _rcall_pmtables(:st_new, (r_data,), kwargs)
    PMTable(robj)
end

"""
    pt_cont_wide(data::DataFrame; cols, kwargs...) -> PMTable

Create a wide-format continuous summary table.

# Example
```julia
tbl = pt_cont_wide(df; cols=[:WT, :AGE, :BMI], by="STUDY")
```
"""
function pt_cont_wide(data::DataFrame; cols=nothing, kwargs...)
    _require_pmtables()
    r_data = _robject(_prepare_pmtable_data(data))
    robj = _rcall_pmtables(:pt_cont_wide, (r_data,), _pt_kwargs(cols, kwargs))
    PMTable(robj)
end

"""
    pt_cont_long(data::DataFrame; cols, kwargs...) -> PMTable

Create a long-format continuous summary table.
"""
function pt_cont_long(data::DataFrame; cols=nothing, kwargs...)
    _require_pmtables()
    r_data = _robject(_prepare_pmtable_data(data))
    robj = _rcall_pmtables(:pt_cont_long, (r_data,), _pt_kwargs(cols, kwargs))
    PMTable(robj)
end

"""
    pt_cat_wide(data::DataFrame; cols, kwargs...) -> PMTable

Create a wide-format categorical summary table.
"""
function pt_cat_wide(data::DataFrame; cols=nothing, kwargs...)
    _require_pmtables()
    r_data = _robject(_prepare_pmtable_data(data))
    robj = _rcall_pmtables(:pt_cat_wide, (r_data,), _pt_kwargs(cols, kwargs))
    PMTable(robj)
end

"""
    pt_cat_long(data::DataFrame; cols, kwargs...) -> PMTable

Create a long-format categorical summary table.
"""
function pt_cat_long(data::DataFrame; cols=nothing, kwargs...)
    _require_pmtables()
    r_data = _robject(_prepare_pmtable_data(data))
    robj = _rcall_pmtables(:pt_cat_long, (r_data,), _pt_kwargs(cols, kwargs))
    PMTable(robj)
end

"""
    pt_demographics(data::DataFrame; kwargs...) -> PMTable

Create a mixed continuous + categorical demographics table.
"""
function pt_demographics(data::DataFrame; kwargs...)
    _require_pmtables()
    r_data = _robject(_prepare_pmtable_data(data))
    robj = _rcall_pmtables(:pt_demographics, (r_data,), kwargs)
    PMTable(robj)
end

"""
    pt_data_inventory(data::DataFrame; kwargs...) -> PMTable

Create a data inventory table (subject/obs/BLQ counts).
"""
function pt_data_inventory(data::DataFrame; kwargs...)
    _require_pmtables()
    r_data = _robject(_prepare_pmtable_data(data))
    robj = _rcall_pmtables(:pt_data_inventory, (r_data,), kwargs)
    PMTable(robj)
end
