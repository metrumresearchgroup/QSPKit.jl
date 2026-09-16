# ============================================================
# pmtables — Rendering (stable, stable_long, stable_save, st2png)
# ============================================================

function _escape_text_carets(latex::String)
    io = IOBuffer()
    in_math = false
    escaped = false
    for ch in latex
        if ch == '$' && !escaped
            in_math = !in_math
            write(io, ch)
        elseif ch == '^' && !in_math && !escaped
            write(io, "\\textasciicircum{}")
        else
            write(io, ch)
        end
        escaped = ch == '\\' && !escaped
        ch == '\\' || (escaped = false)
    end
    String(take!(io))
end

"""
    stable(tbl::PMTable; kwargs...) -> LaTeXTable
    stable(; kwargs...) -> Function

Render a PMTable to LaTeX code.

# Example
```julia
latex = pt_cont_wide(df; cols=[:WT, :AGE]) |>
        st_units(WT="kg") |>
        stable
```
"""
function stable(tbl::PMTable; kwargs...)
    _require_pmtables()
    r_kwargs = _pmtables_kwargs(kwargs)
    robj = if isempty(r_kwargs)
        _rcall(_reval("pmtables::stable"), tbl.robject)
    else
        _rcall(_reval("pmtables::stable"), tbl.robject; r_kwargs...)
    end
    latex_str = _rcopy(String, _rcall(_reval("paste"), robj; collapse="\n"))
    LaTeXTable(_escape_text_carets(latex_str))
end

# Curried form for piping
stable(; kwargs...) = tbl::PMTable -> stable(tbl; kwargs...)

"""
    stable_long(tbl::PMTable; kwargs...) -> LaTeXTable
    stable_long(; kwargs...) -> Function

Render a PMTable to LaTeX code using longtable environment.

!!! note "`st_caption` and `lt_cap_*` are mutually exclusive"
    This is upstream pmtables behavior, not a ShowKit limitation. When a
    caption has been set with `st_caption()`, `pmtables::stable_long()` emits
    `\\caption{...}` from it and silently ignores `lt_cap_text`,
    `lt_cap_short`, `lt_cap_label`, and `lt_cap_macro`. To get a `\\label{}`,
    drop `st_caption()` and pass the caption as `lt_cap_text` instead.

# Example
```julia
latex = params |> st_new |>
        stable_long(lt_cap_text="Model parameters.",
                    lt_cap_label="tab-param-table")
```
"""
function stable_long(tbl::PMTable; kwargs...)
    _require_pmtables()
    r_kwargs = _pmtables_kwargs(kwargs)
    robj = if isempty(r_kwargs)
        _rcall(_reval("pmtables::stable_long"), tbl.robject)
    else
        _rcall(_reval("pmtables::stable_long"), tbl.robject; r_kwargs...)
    end
    latex_str = _rcopy(String, _rcall(_reval("paste"), robj; collapse="\n"))
    LaTeXTable(_escape_text_carets(latex_str))
end

stable_long(; kwargs...) = tbl::PMTable -> stable_long(tbl; kwargs...)

"""
    stable_save(tbl::LaTeXTable, path::String)

Write a LaTeXTable to a .tex file.
"""
function stable_save(tbl::LaTeXTable, path::String)
    open(path, "w") do io
        write(io, tbl.latex)
    end
    path
end

"""
    stable_save(tbl::PMTable, path::String; longtable=false)

Render a PMTable to LaTeX and write to a .tex file. Pass `longtable=true` to
render with `stable_long()` instead of `stable()`.
"""
function stable_save(tbl::PMTable, path::String; longtable::Bool=false)
    lt = longtable ? stable_long(tbl) : stable(tbl)
    stable_save(lt, path)
end

"""
    stable_save(tbl::PMTable; longtable=false, kwargs...)
    stable_save(; longtable=false, kwargs...) -> Function

Render with `pmtables::stable()` and save with `pmtables::stable_save()`.
This supports the Expo/R-style workflow where `st_files(output=...)` is part
of the pmtables pipeline. Remaining `kwargs` go to `pmtables::stable_save()`
(`file`, `dir`, `write_caption`).

Pass `longtable=true` to render with `pmtables::stable_long()`. To pass
`stable_long()` arguments such as `lt_cap_label`, render and save in two steps:

```julia
latex = tbl |> stable_long(lt_cap_label="tab-param-table")
stable_save(latex, "param-table.tex")
```
"""
function stable_save(tbl::PMTable; longtable::Bool=false, kwargs...)
    _require_pmtables()
    r_kwargs = _pmtables_kwargs(kwargs)
    renderer = longtable ? "pmtables::stable_long" : "pmtables::stable"
    r_stable = _rcall(_reval(renderer), tbl.robject)
    _rcall(_reval("pmtables::stable_save"), r_stable; r_kwargs...)
    return tbl
end

stable_save(; kwargs...) = tbl -> stable_save(tbl; kwargs...)

function _as_r_stable(tbl::LaTeXTable)
    latex = _escape_text_carets(tbl.latex)
    r_latex = _robject(split(latex, '\n'; keepempty=true))
    _rcall(_reval("structure"), r_latex; class="stable")
end

function _render_r_stable_png(r_stable, path::String; kwargs...)
    target_path = abspath(path)
    target_dir = dirname(target_path)
    target_stem = splitext(basename(target_path))[1]
    mkpath(target_dir)

    pdf_kwargs = Dict{Symbol, Any}(:stem => target_stem, :dir => target_dir)
    dpi = 200
    for (k, v) in kwargs
        rname = Symbol(_pmtables_to_r_name(k))
        if rname === :dpi
            dpi = v
        else
            pdf_kwargs[rname] = v
        end
    end

    pdf_path = _rcopy(
        String,
        _rcall(_reval("pmtables::st_aspdf"), r_stable; pdf_kwargs...),
    )
    filename_format = joinpath(target_dir, target_stem * "_%d.%s")
    converted = _rcopy(
        Vector{String},
        _rcall(
            _reval("pdftools::pdf_convert"),
            pdf_path;
            format="png",
            pages=1,
            dpi=dpi,
            filenames=filename_format,
            verbose=false,
        ),
    )
    isempty(converted) && error("Table PDF conversion produced no PNG files")
    cp(only(converted), target_path; force=true)
    isfile(target_path) || error("Table PNG rendering did not create $target_path")
    path
end

"""
    st2png(tbl::Union{PMTable, LaTeXTable}, path::String; kwargs...)

Render a table to PNG via LaTeX.
"""
function st2png(tbl::PMTable, path::String; kwargs...)
    _require_st2png()
    r_stable = _rcall(_reval("pmtables::stable"), tbl.robject)
    _render_r_stable_png(r_stable, path; kwargs...)
end

function st2png(tbl::LaTeXTable, path::String; kwargs...)
    _require_st2png()
    # `stable()` returns an R character vector with class `stable`.  The
    # Julia wrapper stores that vector as one newline-delimited string, so
    # restore both the vector shape and class before rendering it.
    r_stable = _as_r_stable(tbl)
    _render_r_stable_png(r_stable, path; kwargs...)
end
