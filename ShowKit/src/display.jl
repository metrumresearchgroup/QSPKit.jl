# ============================================================
# Display — Base.show for all types, MIME rendering
# ============================================================

# ---- Text display ----

function Base.show(io::IO, p::GGPlot)
    print(io, "GGPlot(...)")
end

function Base.show(io::IO, l::GGLayer)
    print(io, "GGLayer(:$(l.name))")
end

function Base.show(io::IO, t::PMTable)
    print(io, "PMTable(...)")
end

function Base.show(io::IO, t::LaTeXTable)
    n = count('\n', t.latex)
    print(io, "LaTeXTable($(n + 1) lines)")
end

function Base.show(io::IO, ::MIME"text/plain", t::LaTeXTable)
    lines = split(t.latex, '\n')
    println(io, "LaTeXTable ($(length(lines)) lines):")
    for line in first(lines, 10)
        println(io, "  ", line)
    end
    if length(lines) > 10
        println(io, "  ... ($(length(lines) - 10) more lines)")
    end
end

# LaTeX rendering in classic Jupyter notebooks
function Base.show(io::IO, ::MIME"text/latex", t::LaTeXTable)
    write(io, t.latex)
end

# HTML rendering for PMTable (works in VS Code and Jupyter notebooks)
function Base.show(io::IO, ::MIME"text/html", t::PMTable)
    _require_r()
    _require_pmtables()
    # Convert R pmtable to a Julia DataFrame, then render as HTML table
    r_df = _rcall(_reval("as.data.frame"), t.robject)
    df = _rcopy(DataFrames.DataFrame, r_df)
    _write_html_table(io, df)
end

# HTML rendering for LaTeXTable — preformatted fallback
function Base.show(io::IO, ::MIME"text/html", t::LaTeXTable)
    write(io, "<pre style=\"font-family: monospace; font-size: 12px;\">", t.latex, "</pre>")
end

function _write_html_table(io::IO, df::DataFrames.DataFrame)
    write(io, "<table style=\"border-collapse: collapse; margin: 10px 0;\">")
    # Header
    write(io, "<thead><tr>")
    for col in names(df)
        write(io, "<th style=\"border: 1px solid #ddd; padding: 6px 12px; background: #f5f5f5; font-weight: bold;\">")
        write(io, string(col))
        write(io, "</th>")
    end
    write(io, "</tr></thead>")
    # Body
    write(io, "<tbody>")
    for row in eachrow(df)
        write(io, "<tr>")
        for val in row
            write(io, "<td style=\"border: 1px solid #ddd; padding: 6px 12px;\">")
            write(io, string(val))
            write(io, "</td>")
        end
        write(io, "</tr>")
    end
    write(io, "</tbody></table>")
end

# ---- Rich display: PNG via ggsave ----

const _DISPLAY_WIDTH = Ref(7.0)
const _DISPLAY_HEIGHT = Ref(5.0)
const _DISPLAY_DPI = Ref(150)

"""
    set_display_size(; width=7.0, height=5.0, dpi=150)

Set the default dimensions for rendering plots in VS Code / Jupyter.
"""
function set_display_size(; width=_DISPLAY_WIDTH[], height=_DISPLAY_HEIGHT[], dpi=_DISPLAY_DPI[])
    _DISPLAY_WIDTH[] = width
    _DISPLAY_HEIGHT[] = height
    _DISPLAY_DPI[] = dpi
    nothing
end

function Base.show(io::IO, ::MIME"image/png", p::GGPlot)
    _require_r()
    tmpfile = _rcopy(String, _reval("tempfile(fileext='.png')"))
    ggsave_fn = _reval("ggplot2::ggsave")
    w = _DISPLAY_WIDTH[]
    h = _DISPLAY_HEIGHT[]
    dpi = _DISPLAY_DPI[]
    _rcall(ggsave_fn, tmpfile; plot=p.robject, width=w, height=h, dpi=dpi, units="in")
    write(io, read(tmpfile))
    rm(tmpfile; force=true)
end

function Base.show(io::IO, ::MIME"image/svg+xml", p::GGPlot)
    _require_r()
    tmpfile = _rcopy(String, _reval("tempfile(fileext='.svg')"))
    ggsave_fn = _reval("ggplot2::ggsave")
    w = _DISPLAY_WIDTH[]
    h = _DISPLAY_HEIGHT[]
    _rcall(ggsave_fn, tmpfile; plot=p.robject, width=w, height=h, units="in")
    write(io, read(tmpfile))
    rm(tmpfile; force=true)
end

function _show_table_png(io::IO, tbl::Union{PMTable, LaTeXTable})
    mktempdir() do dir
        path = joinpath(dir, "table.png")
        st2png(tbl, path)
        write(io, read(path))
    end
end

function Base.show(io::IO, ::MIME"image/png", tbl::PMTable)
    _show_table_png(io, tbl)
end

function Base.show(io::IO, ::MIME"image/png", tbl::LaTeXTable)
    _show_table_png(io, tbl)
end

Base.showable(::MIME"image/png", ::GGPlot) = _RCALL_AVAILABLE[]
Base.showable(::MIME"image/svg+xml", ::GGPlot) = _RCALL_AVAILABLE[]
Base.showable(::MIME"image/png", ::PMTable) = _RCALL_AVAILABLE[]
Base.showable(::MIME"image/png", ::LaTeXTable) = _RCALL_AVAILABLE[]
Base.showable(::MIME"text/html", ::PMTable) = _RCALL_AVAILABLE[]
Base.showable(::MIME"text/html", ::LaTeXTable) = true
