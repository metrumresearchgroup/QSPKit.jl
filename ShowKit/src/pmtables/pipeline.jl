# ============================================================
# pmtables — st_* Pipeline Modifiers
# ============================================================
# Each function has two forms:
#   Direct:  st_units(tbl; WT="kg", AGE="years")
#   Curried: pt_cont_wide(df; cols=...) |> st_units(WT="kg") |> stable

"""
    st_units(tbl::PMTable; kwargs...) -> PMTable
    st_units(; kwargs...) -> Function

Add units row under column headers.

# Example
```julia
pt_cont_wide(df; cols=[:WT, :AGE]) |> st_units(WT="kg", AGE="years") |> stable
```
"""
function st_units(tbl::PMTable; kwargs...)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_units"), tbl.robject;
                  _pmtables_kwargs(kwargs)...)
    PMTable(robj)
end

st_units(; kwargs...) = tbl -> st_units(tbl; kwargs...)

"""
    st_notes(tbl::PMTable, notes::Vector{String}) -> PMTable
    st_notes(notes::Vector{String}) -> Function
    st_notes(tbl::PMTable, note::String) -> PMTable
    st_notes(note::String) -> Function

Add footnotes to the table.
"""
function st_notes(tbl::PMTable, notes::Vector{String})
    _require_pmtables()
    r_notes = _robject(notes)
    robj = _rcall(_reval("pmtables::st_notes"), tbl.robject, r_notes)
    PMTable(robj)
end

st_notes(tbl::PMTable, note::String) = st_notes(tbl, [note])
st_notes(notes::Vector{String}) = tbl -> st_notes(tbl, notes)
st_notes(note::String) = tbl -> st_notes(tbl, [note])

"""
    st_caption(tbl::PMTable, caption::String) -> PMTable
    st_caption(caption::String) -> Function

Set the table caption.
"""
function st_caption(tbl::PMTable, caption::String)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_caption"), tbl.robject, caption)
    PMTable(robj)
end

st_caption(caption::String) = tbl -> st_caption(tbl, caption)

"""
    st_files(tbl::PMTable; output::String) -> PMTable
    st_files(; output::String) -> Function

Set the output file path.
"""
function st_files(tbl::PMTable; output::String)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_files"), tbl.robject; output=output)
    PMTable(robj)
end

st_files(; output::String) = tbl -> st_files(tbl; output=output)

"""
    st_panel(tbl::PMTable, col; kwargs...) -> PMTable
    st_panel(col; kwargs...) -> Function

Group table rows into panels using `pmtables::st_panel()`.
"""
function st_panel(tbl::PMTable, col::Union{String, Symbol}; kwargs...)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_panel"), tbl.robject, string(col);
                  _pmtables_kwargs(kwargs)...)
    PMTable(robj)
end

st_panel(col::Union{String, Symbol}; kwargs...) = tbl -> st_panel(tbl, col; kwargs...)

"""
    col_fixed(width; kwargs...)

Wrapper for `pmtables::col_fixed()`. Width is in centimeters by default;
override with `unit` when needed.
"""
function col_fixed(width::Real; kwargs...)
    _require_pmtables()
    return _rcall(_reval("pmtables::col_fixed"), Float64(width);
                  _pmtables_kwargs(kwargs)...)
end

"""
    col_ragged(width; kwargs...)

Wrapper for `pmtables::col_ragged()`, commonly passed to `st_center()`.
"""
function col_ragged(width::Real; kwargs...)
    _require_pmtables()
    return _rcall(_reval("pmtables::col_ragged"), Float64(width);
                  _pmtables_kwargs(kwargs)...)
end

"""
    st_align(tbl::PMTable; kwargs...) -> PMTable
    st_align(; kwargs...) -> Function

Set default and per-column alignment or fixed-width specifications with
`pmtables::st_align()`. Use `_default` for pmtables' `.default` argument.
"""
function st_align(tbl::PMTable; kwargs...)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_align"), tbl.robject;
                  _pmtables_kwargs(kwargs)...)
    PMTable(robj)
end

st_align(; kwargs...) = tbl -> st_align(tbl; kwargs...)

"""
    st_center(tbl::PMTable; kwargs...) -> PMTable
    st_center(; kwargs...) -> Function

Set column alignment / ragged-column settings with `pmtables::st_center()`.
"""
function st_center(tbl::PMTable; kwargs...)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_center"), tbl.robject;
                  _pmtables_kwargs(kwargs)...)
    PMTable(robj)
end

st_center(; kwargs...) = tbl -> st_center(tbl; kwargs...)

"""
    st_blank(tbl::PMTable, cols...; kwargs...) -> PMTable
    st_blank(cols...; kwargs...) -> Function

Blank repeated values in selected columns with `pmtables::st_blank()`.
"""
function st_blank(tbl::PMTable, cols::Union{String, Symbol}...; kwargs...)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_blank"), tbl.robject, string.(cols)...;
                  _pmtables_kwargs(kwargs)...)
    PMTable(robj)
end

st_blank(cols::Union{String, Symbol}...; kwargs...) =
    tbl -> st_blank(tbl, cols...; kwargs...)

"""
    st_noteconf(tbl::PMTable; kwargs...) -> PMTable
    st_noteconf(; kwargs...) -> Function

Configure table notes with `pmtables::st_noteconf()`.
"""
function st_noteconf(tbl::PMTable; kwargs...)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_noteconf"), tbl.robject;
                  _pmtables_kwargs(kwargs)...)
    PMTable(robj)
end

st_noteconf(; kwargs...) = tbl -> st_noteconf(tbl; kwargs...)

"""
    st_span_split(tbl::PMTable; kwargs...) -> PMTable
    st_span_split(; kwargs...) -> Function

Split column names into spanning headers with `pmtables::st_span_split()`.
"""
function st_span_split(tbl::PMTable; kwargs...)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_span_split"), tbl.robject;
                  _pmtables_kwargs(kwargs)...)
    PMTable(robj)
end

st_span_split(; kwargs...) = tbl -> st_span_split(tbl; kwargs...)

"""
    st_as_image(tbl::PMTable; kwargs...)
    st_as_image(; kwargs...) -> Function

Preview a table with `pmtables::st_as_image()`.
"""
function st_as_image(tbl::PMTable; kwargs...)
    _require_pmtables()
    return _rcall(_reval("pmtables::st_as_image"), tbl.robject;
                  _pmtables_kwargs(kwargs)...)
end

st_as_image(; kwargs...) = tbl -> st_as_image(tbl; kwargs...)

"""
    st_span(tbl::PMTable, label::String; vars...) -> PMTable
    st_span(label::String; vars...) -> Function

Add a spanning header over columns.
"""
function st_span(tbl::PMTable, label::String; kwargs...)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_span"), tbl.robject, label;
                  _pmtables_kwargs(kwargs)...)
    PMTable(robj)
end

st_span(label::String; kwargs...) = tbl -> st_span(tbl, label; kwargs...)

"""
    st_rename(tbl::PMTable; kwargs...) -> PMTable
    st_rename(; kwargs...) -> Function

Rename columns in the table.
"""
function st_rename(tbl::PMTable; kwargs...)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_rename"), tbl.robject;
                  _pmtables_kwargs(kwargs)...)
    PMTable(robj)
end

st_rename(; kwargs...) = tbl -> st_rename(tbl; kwargs...)

"""
    st_bold(tbl::PMTable; kwargs...) -> PMTable
    st_bold(; kwargs...) -> Function

Bold cell content.
"""
function st_bold(tbl::PMTable; kwargs...)
    _require_pmtables()
    r_kwargs = _pmtables_kwargs(kwargs)
    robj = if isempty(r_kwargs)
        _rcall(_reval("pmtables::st_bold"), tbl.robject)
    else
        _rcall(_reval("pmtables::st_bold"), tbl.robject; r_kwargs...)
    end
    PMTable(robj)
end

st_bold(; kwargs...) = tbl -> st_bold(tbl; kwargs...)

"""
    st_clear_reps(tbl::PMTable, cols...) -> PMTable
    st_clear_reps(cols...) -> Function

Blank repeated values in a column.
"""
function st_clear_reps(tbl::PMTable, cols::Union{String, Symbol}...)
    _require_pmtables()
    robj = _rcall(_reval("pmtables::st_clear_reps"), tbl.robject, string.(cols)...)
    PMTable(robj)
end

st_clear_reps(cols::Union{String, Symbol}...) = tbl -> st_clear_reps(tbl, cols...)

"""
    st_clear_grouped(tbl::PMTable, cols...) -> PMTable
    st_clear_grouped(cols...) -> Function

Blank repeated values hierarchically across columns. This is useful for
long-form tables where one parameter spans several variant rows.
"""
function st_clear_grouped(tbl::PMTable, cols::Union{String, Symbol}...)
    _require_pmtables()
    robj = _rcall(
        _reval("pmtables::st_clear_grouped"),
        tbl.robject,
        string.(cols)...,
    )
    PMTable(robj)
end

st_clear_grouped(cols::Union{String, Symbol}...) =
    tbl -> st_clear_grouped(tbl, cols...)

"""
    tab_clear_reps(data::DataFrame, cols...; grouped=false) -> DataFrame

Return a copy of `data` with repeated values in `cols` replaced by empty
strings. With `grouped=true`, clear values hierarchically using pmtables'
`clear_grouped_reps` behavior.

Unlike `st_clear_reps` and `st_clear_grouped`, this operates immediately on a
Julia `DataFrame` rather than recording presentation settings on a `PMTable`.
"""
function tab_clear_reps(data::DataFrame, cols::Union{String, Symbol}...;
        grouped::Bool=false)
    _require_pmtables()
    isempty(cols) && return copy(data)
    r_data = _robject(data)
    r_cols = _robject(string.(cols))
    keyword = grouped ? :clear_grouped_reps : :clear_reps
    r_kwargs = Pair{Symbol, Any}[keyword => r_cols]
    result = _rcall(_reval("pmtables::tab_clear_reps"), r_data; r_kwargs...)
    _rcopy(DataFrames.DataFrame, result)
end
