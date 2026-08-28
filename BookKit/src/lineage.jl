# ==============================================================================
# lineage_graph — discover and render a project's workflow dependency DAG
# ==============================================================================
#
# A project may organize independent scripts under folders such as
# `workflow/collect`, `workflow/build`, and `workflow/publish`. Each script writes
# a named, content-addressed artifact with `cached("Job20_SiteBundle"; …)` (or
# `book!`) and reads upstream artifacts with
# `latest(name="Job10_ContentManifest")` (or `lookup`).
#
# Those `latest(...)`/`cached(...)` pairs ARE the dependency edges: the result a
# script pulls feeds the result it produces. `lineage_graph` recovers that DAG
# automatically by
#   1. statically scanning the project's scripts for producer/consumer calls, and
#   2. enriching the discovered nodes with provenance-store metadata (timestamp,
#      content hash, VCS ref, and whether the step performed a fit), reading
#      either a file-backed artifact cache or a BookKit/StoreKit store
#      (`.provenance/`). Consumption edges recorded in a BookKit store
#      (`result_inputs`) are merged in as well.
#
# The graph is discovered from the project — never maintained by hand.

# ─── Types ────────────────────────────────────────────────────────────────

"""
    LineageNode

A node in a [`LineageGraph`]: one booked result (granularity `:result`) or one
collapsed workflow stage (granularity `:unit`).

# Fields
- `name::String` — result name (e.g. `"Job20_SiteBundle"`) or stage id (`"Job20"`)
- `kind::Symbol` — `:fit` (calibrated on data / fit parameters), `:prediction`
  (prediction-only, no new fit), or `:unknown`
- `description::String` — one-line summary discovered from the producing
  script's leading docstring/comment (may be empty)
- `timestamp::Union{String,Nothing}` — when the result was last produced
- `content_hash::Union{String,Nothing}` — content address of the stored result
- `vcs_ref::Union{String,Nothing}` — VCS revision recorded with the result
- `results::Vector{String}` — underlying result names (for `:unit` nodes)
- `scripts::Vector{String}` — producing script paths (relative to the project)
"""
struct LineageNode
    name::String
    kind::Symbol
    description::String
    timestamp::Union{String,Nothing}
    content_hash::Union{String,Nothing}
    vcs_ref::Union{String,Nothing}
    results::Vector{String}
    scripts::Vector{String}
end

"""
    LineageEdge

A directed dependency edge `src -> dst`: producing `dst` consumed `src`.

# Fields
- `src::String` — upstream node (the result/unit that was pulled)
- `dst::String` — downstream node (the result/unit that was produced)
- `label::String` — what was pulled (default: the upstream result name(s))
- `pulled::Vector{String}` — the exact upstream result name(s) behind this edge
- `via::Union{String,Nothing}` — the variable the read was bound to (e.g. `"content_manifest"`)
- `source::Symbol` — how the edge was discovered: `:script` or `:store`
"""
struct LineageEdge
    src::String
    dst::String
    label::String
    pulled::Vector{String}
    via::Union{String,Nothing}
    source::Symbol
end

"""
    LineageGraph

A directed acyclic graph of a workflow's booked results and their consumption
links, discovered by [`lineage_graph`](@ref). Carries full node and edge
metadata and is dependency-free; emit it with [`to_dot`](@ref) (Graphviz) or
convert to a Graphs.jl object with [`to_metagraph`](@ref).

# Fields
- `project::String` — project root the graph was discovered from
- `granularity::Symbol` — `:unit` (stage-collapsed) or `:result`
- `nodes::Vector{LineageNode}`
- `edges::Vector{LineageEdge}`
"""
struct LineageGraph
    project::String
    granularity::Symbol
    nodes::Vector{LineageNode}
    edges::Vector{LineageEdge}
end

"""Return the nodes of a [`LineageGraph`]."""
nodes(g::LineageGraph) = g.nodes
"""Return the edges of a [`LineageGraph`]."""
edges(g::LineageGraph) = g.edges
"""Node names that have no incoming edges (the DAG's sources)."""
roots(g::LineageGraph) = [n.name for n in g.nodes if !any(e -> e.dst == n.name, g.edges)]
"""Node names that have no outgoing edges (the DAG's sinks)."""
leaves(g::LineageGraph) = [n.name for n in g.nodes if !any(e -> e.src == n.name, g.edges)]

function Base.show(io::IO, g::LineageGraph)
    print(io, "LineageGraph(:$(g.granularity), $(length(g.nodes)) nodes, $(length(g.edges)) edges)")
end

function Base.show(io::IO, ::MIME"text/plain", g::LineageGraph)
    println(io, "LineageGraph — $(g.granularity)-level, discovered from $(g.project)")
    println(io, "  $(length(g.nodes)) nodes, $(length(g.edges)) edges")
    for n in g.nodes
        mark = n.kind == :fit ? "●" : n.kind == :prediction ? "○" : "?"
        ups = sort!([e.src for e in g.edges if e.dst == n.name])
        arrow = isempty(ups) ? "" : "  ← " * join(ups, ", ")
        println(io, "  $mark $(n.name)$arrow")
    end
end

# ─── Public entry points ────────────────────────────────────────────────────

"""
    lineage_graph(project; granularity=:unit, script_dirs=nothing,
                  store_dirs=nothing, include_store=true) -> LineageGraph

Discover the workflow dependency DAG of a QSPKit `project` and return it as a
[`LineageGraph`]. `project` is a project root directory (or a [`StoreKit.Store`]
handle, see below).

Nodes are booked results; edges are the `latest(name=…)` / `lookup(…)` reads
that each `cached(…)` / `book!(…)` consumed. The graph is reconstructed by
statically scanning the project's scripts and enriched with metadata read from
the provenance store.

# Keyword arguments
- `granularity::Symbol` — `:unit` (default) collapses result names sharing an
  initial alphabetic-and-number stage prefix (`Job10_ContentManifest` and
  `Job10_SourceIndex` become `Job10`) and drops intra-stage self-edges;
  `:result` keeps every booked result as its own node.
- `script_dirs` — directories/files to scan for producer/consumer calls.
  Defaults to the whole project root (skipping VCS/vendor dirs). For backward
  compatibility, an existing `<project>/mu` container is scanned directly.
- `store_dirs` — directories holding stored results to read metadata from.
  Defaults to the backward-compatible `<project>/data/sims` JLD2 location when
  present, plus `<project>` itself (BookKit `.provenance/`).
- `include_store::Bool` — if `false`, skip store enrichment and build the graph
  from scripts alone (no timestamps/hashes).

# Example
```julia
g = lineage_graph("path/to/site-project")
print(to_dot(g))                 # Graphviz dot
roots(g)                         # ["Job10"]
```
For this synthetic example, the discovered stage DAG is
`Job10 → Job20 → Job30`: collect content, build a site bundle, then publish it.

See also [`to_dot`](@ref), [`render_lineage`](@ref), [`to_metagraph`](@ref).
"""
function lineage_graph(project::AbstractString;
                       granularity::Symbol = :unit,
                       script_dirs = nothing,
                       store_dirs = nothing,
                       include_store::Bool = true)
    granularity in (:unit, :result) ||
        throw(ArgumentError("granularity must be :unit or :result, got :$granularity"))
    root = abspath(expanduser(String(project)))
    isdir(root) || throw(ArgumentError("project root not found: $root"))

    files = _find_scripts(root, script_dirs)
    parsed = _ParsedScript[]
    for f in files
        ps = _parse_script(f, root)
        ps === nothing || push!(parsed, ps)
    end

    nodemap, edges = _build_result_graph(parsed)

    if include_store
        dirs = store_dirs === nothing ? _default_store_dirs(root) : [abspath(expanduser(String(d))) for d in store_dirs]
        _enrich_from_result_files!(nodemap, dirs)
        _merge_provenance!(nodemap, edges, root)
    end

    g = LineageGraph(root, :result, _sorted_nodes(nodemap), _dedup_edges(edges))
    return granularity == :unit ? _collapse_to_units(g) : g
end

"""
    lineage_graph(store::StoreKit.Store; granularity=:unit) -> LineageGraph

Build a lineage graph directly from a BookKit/StoreKit provenance store, using
its annotations as nodes and the recorded `result_inputs` consumption edges. The
project root (the store's parent directory) is also scanned for scripts so that
edges hold even when they were not captured into the store.
"""
function lineage_graph(store::Store; granularity::Symbol = :unit, kwargs...)
    root = dirname(store.dir)   # store.dir is `<root>/.provenance`
    return lineage_graph(root; granularity=granularity, kwargs...)
end

# ─── Script scanning ──────────────────────────────────────────────────────

const _SCRIPT_SKIP_DIRS = Set([".git", ".svn", ".julia", ".QSPKit", "renv",
                               ".Rproj.user", "node_modules", ".vscode", "blobs"])

function _find_scripts(root::String, script_dirs)
    targets = String[]
    if script_dirs !== nothing
        for d in script_dirs
            p = isabspath(String(d)) ? String(d) : joinpath(root, String(d))
            push!(targets, p)
        end
    elseif isdir(joinpath(root, "mu"))
        push!(targets, joinpath(root, "mu"))
    else
        push!(targets, root)
    end

    files = String[]
    for t in targets
        if isfile(t) && endswith(t, ".jl")
            push!(files, t)
        elseif isdir(t)
            for (dir, subdirs, fs) in walkdir(t)
                filter!(s -> !(s in _SCRIPT_SKIP_DIRS) && !startswith(s, "."), subdirs)
                for f in fs
                    endswith(f, ".jl") && push!(files, joinpath(dir, f))
                end
            end
        end
    end
    return sort!(unique!(files))
end

struct _ProducerRef
    name::String
end
struct _ConsumerRef
    name::String
    via::Union{String,Nothing}
end
mutable struct _ParseCtx
    producers::Vector{_ProducerRef}
    consumers::Vector{_ConsumerRef}
    is_fit::Bool
end
struct _ParsedScript
    file::String         # relative to project root
    producers::Vector{_ProducerRef}
    consumers::Vector{_ConsumerRef}
    is_fit::Bool
    description::String
end

function _parse_script(file::String, root::String)
    src = read(file, String)
    expr = try
        Meta.parseall(src; filename=file)
    catch err
        @warn "lineage_graph: skipping unparseable script" file exception=err
        return nothing
    end
    ctx = _ParseCtx(_ProducerRef[], _ConsumerRef[], false)
    _walk!(expr, ctx, nothing)
    (isempty(ctx.producers) && isempty(ctx.consumers)) && return nothing
    rel = _rel(file, root)
    return _ParsedScript(rel, ctx.producers, ctx.consumers, ctx.is_fit, _leading_description(src))
end

# Resolve the callee symbol of a call expression: `foo(...)` -> :foo,
# `Mod.foo(...)` -> :foo.
function _callee(x)
    x isa Symbol && return x
    if x isa Expr && x.head === :. && length(x.args) == 2 && x.args[2] isa QuoteNode
        return x.args[2].value
    end
    return nothing
end

# Return `(funcname, callexpr)` for a call or do-block, else `(nothing, nothing)`.
function _as_call(e::Expr)
    if e.head === :call
        return (_callee(e.args[1]), e)
    elseif e.head === :do && !isempty(e.args) && e.args[1] isa Expr && e.args[1].head === :call
        inner = e.args[1]
        return (_callee(inner.args[1]), inner)
    end
    return (nothing, nothing)
end

function _first_string_arg(call::Expr)
    for a in call.args
        a isa String && return a
    end
    return nothing
end

function _kw_string(call::Expr, key::Symbol)
    for a in call.args
        if a isa Expr && a.head === :kw && a.args[1] === key && a.args[2] isa String
            return a.args[2]
        elseif a isa Expr && a.head === :parameters
            for p in a.args
                if p isa Expr && p.head === :kw && p.args[1] === key && p.args[2] isa String
                    return p.args[2]
                end
            end
        end
    end
    return nothing
end

function _walk!(e, ctx::_ParseCtx, binding)
    e isa Expr || return
    # Capture `var = latest(...)` / `var = lookup(...)` bindings.
    if e.head === :(=) && length(e.args) == 2 && e.args[1] isa Symbol
        _walk!(e.args[2], ctx, String(e.args[1]))
        return
    end

    fname, call = _as_call(e)
    if fname === :cached || fname === :book!
        nm = _first_string_arg(call)
        nm === nothing || push!(ctx.producers, _ProducerRef(nm))
    elseif fname === :latest
        nm = _kw_string(call, :name)
        nm === nothing || push!(ctx.consumers, _ConsumerRef(nm, binding))
    elseif fname === :lookup
        nm = _first_string_arg(call)
        nm === nothing || push!(ctx.consumers, _ConsumerRef(nm, binding))
    elseif fname === :tracked_fit || fname === :fit
        ctx.is_fit = true
    end

    for a in e.args
        _walk!(a, ctx, nothing)
    end
    return
end

# First meaningful line of a leading docstring or comment block.
function _leading_description(src::String)
    lines = split(src, '\n')
    i = 1
    while i <= length(lines)
        line = strip(lines[i])
        if isempty(line)
            i += 1; continue
        end
        if startswith(line, "\"\"\"")
            rest = strip(line[4:end])
            isempty(rest) || return _clean_desc(rest)
            i += 1
            while i <= length(lines) && isempty(strip(lines[i])); i += 1; end
            i <= length(lines) && return _clean_desc(strip(replace(lines[i], "\"\"\"" => "")))
            return ""
        elseif startswith(line, "#=")
            rest = strip(line[3:end])
            isempty(rest) || return _clean_desc(rest)
            i += 1
            while i <= length(lines) && isempty(strip(lines[i])); i += 1; end
            i <= length(lines) && return _clean_desc(strip(lines[i]))
            return ""
        elseif startswith(line, "#")
            return _clean_desc(strip(lstrip(line, '#')))
        else
            return ""   # hit code before any doc
        end
    end
    return ""
end

_clean_desc(s) = String(strip(replace(s, "\"\"\"" => "")))

# ─── Result-level graph assembly ─────────────────────────────────────────────

mutable struct _NodeAgg
    name::String
    kind::Symbol
    description::String
    timestamp::Union{String,Nothing}
    content_hash::Union{String,Nothing}
    vcs_ref::Union{String,Nothing}
    scripts::Vector{String}
end
_new_agg(name) = _NodeAgg(name, :unknown, "", nothing, nothing, nothing, String[])

function _build_result_graph(parsed::Vector{_ParsedScript})
    nodemap = Dict{String,_NodeAgg}()
    edges = LineageEdge[]

    for ps in parsed
        for prod in ps.producers
            agg = get!(() -> _new_agg(prod.name), nodemap, prod.name)
            ps.is_fit && (agg.kind = :fit)
            agg.kind == :unknown && (agg.kind = :prediction)
            isempty(agg.description) && !isempty(ps.description) && (agg.description = ps.description)
            push!(agg.scripts, ps.file)
        end
        for cons in ps.consumers, prod in ps.producers
            cons.name == prod.name && continue
            push!(edges, LineageEdge(cons.name, prod.name, cons.name, [cons.name], cons.via, :script))
        end
    end

    # Ensure every edge endpoint has a node.
    for e in edges
        haskey(nodemap, e.src) || (nodemap[e.src] = _new_agg(e.src))
        haskey(nodemap, e.dst) || (nodemap[e.dst] = _new_agg(e.dst))
    end
    for agg in values(nodemap)
        unique!(sort!(agg.scripts))
    end
    return nodemap, edges
end

function _sorted_nodes(nodemap::Dict{String,_NodeAgg})
    aggs = sort!(collect(values(nodemap)); by = a -> a.name)
    return [LineageNode(a.name, a.kind, a.description, a.timestamp, a.content_hash,
                        a.vcs_ref, [a.name], a.scripts) for a in aggs]
end

function _dedup_edges(edges::Vector{LineageEdge})
    seen = Dict{Tuple{String,String}, LineageEdge}()
    for e in edges
        key = (e.src, e.dst)
        if haskey(seen, key)
            prev = seen[key]
            pulled = sort!(unique!(vcat(prev.pulled, e.pulled)))
            via = prev.via === nothing ? e.via : prev.via
            seen[key] = LineageEdge(e.src, e.dst, join(pulled, "\n"), pulled, via, prev.source)
        else
            seen[key] = e
        end
    end
    return sort!(collect(values(seen)); by = e -> (e.dst, e.src))
end

# ─── Store enrichment ─────────────────────────────────────────────────────

function _default_store_dirs(root::String)
    dirs = String[]
    isdir(joinpath(root, "data", "sims")) && push!(dirs, joinpath(root, "data", "sims"))
    push!(dirs, root)   # for a `.provenance/` BookKit store
    return dirs
end

# Content-addressed result store: one `<name>_<fingerprint>.jld2` file per result
# revision (a legacy `cached(...)` layout). We read only file-level metadata —
# the newest revision's modification time (a real "when produced" timestamp),
# its content hash, and the content-address fingerprint from the filename — so
# no heavyweight (de)serialization or extra dependency is needed.
function _enrich_from_result_files!(nodemap::Dict{String,_NodeAgg}, dirs)
    best = Dict{String,NamedTuple}()   # result name => (mtime, path, fingerprint)
    for d in dirs
        isdir(d) || continue
        for f in readdir(d; join=true)
            endswith(f, ".jld2") || continue
            nm, fp = _split_result_filename(basename(f))
            nm === nothing && continue
            t = mtime(f)
            prev = get(best, nm, nothing)
            if prev === nothing || t > prev.mtime
                best[nm] = (mtime=t, path=f, fingerprint=fp)
            end
        end
    end
    for (nm, info) in best
        agg = get!(() -> _new_agg(nm), nodemap, nm)
        if agg.timestamp === nothing && info.mtime > 0
            agg.timestamp = Dates.format(Dates.unix2datetime(info.mtime), "yyyy-mm-dd HH:MM:SS")
        end
        if agg.content_hash === nothing
            agg.content_hash = info.fingerprint !== nothing ? info.fingerprint :
                               (isfile(info.path) ? (try hash_file(info.path) catch; nothing end) : nothing)
        end
    end
    return nodemap
end

# File shape: `<result-name>_<hex-digest>.jld2`. The trailing `_<hex>` segment is
# parsed as the content-address fingerprint; no particular digest is special.
function _split_result_filename(fname::String)
    stem = endswith(fname, ".jld2") ? fname[1:end-5] : fname
    m = match(r"^(.*)_([0-9a-fA-F]{8,})$", stem)
    m === nothing && return (stem, nothing)
    return (String(m.captures[1]), String(m.captures[2]))
end

# BookKit/StoreKit `.provenance/` store: annotations + recorded result_inputs.
function _merge_provenance!(nodemap::Dict{String,_NodeAgg}, edges::Vector{LineageEdge}, root::String)
    isdir(joinpath(root, ".provenance")) || return nodemap, edges
    store = try open_store(root) catch err
        @warn "lineage_graph: could not open provenance store" root exception=err
        return nodemap, edges
    end
    for name in StoreKit.distinct_annotation_names(store.db)
        row = StoreKit.latest_annotation(store.db, name)
        row === nothing && continue
        agg = get!(() -> _new_agg(name), nodemap, name)
        if agg.kind == :unknown
            agg.kind = (_present(row.loss) || _present(row.fit_quality)) ? :fit : :prediction
        end
        agg.timestamp === nothing && (agg.timestamp = _str_or_nothing(row.timestamp))
        agg.content_hash === nothing && (agg.content_hash = _str_or_nothing(row.result_hash))
        agg.vcs_ref === nothing && (agg.vcs_ref = _str_or_nothing(row.vcs_ref))
        for inp in StoreKit.get_result_inputs(store.db, row.id)
            up = string(inp.input_name)
            up == name && continue
            haskey(nodemap, up) || (nodemap[up] = _new_agg(up))
            lbl = _present(inp.label) ? string(inp.label) : up
            push!(edges, LineageEdge(up, name, lbl, [up], nothing, :store))
        end
    end
    return nodemap, edges
end

# SQLite NULLs surface as `missing`; treat both missing and nothing as absent.
_present(x) = x !== nothing && !(x isa Missing)
_str_or_nothing(x) = _present(x) ? string(x) : nothing

# ─── Unit collapse ──────────────────────────────────────────────────────────

function _unit_of(name::String)
    m = match(r"^([A-Za-z]+\d+)", name)
    return m === nothing ? name : String(m.captures[1])
end

function _collapse_to_units(g::LineageGraph)
    units = Dict{String,_NodeAgg}()
    members = Dict{String,Vector{String}}()
    for n in g.nodes
        u = _unit_of(n.name)
        agg = get!(() -> _new_agg(u), units, u)
        n.kind == :fit && (agg.kind = :fit)
        agg.kind == :unknown && n.kind == :prediction && (agg.kind = :prediction)
        # Prefer the description of a fit member (the unit's run script).
        if isempty(agg.description) || n.kind == :fit
            isempty(n.description) || (agg.description = n.description)
        end
        if n.timestamp !== nothing && (agg.timestamp === nothing || n.timestamp > agg.timestamp)
            agg.timestamp = n.timestamp
        end
        (agg.content_hash === nothing && n.content_hash !== nothing) && (agg.content_hash = n.content_hash)
        (agg.vcs_ref === nothing && n.vcs_ref !== nothing) && (agg.vcs_ref = n.vcs_ref)
        append!(agg.scripts, n.scripts)
        push!(get!(members, u, String[]), n.name)
    end

    unit_edges = LineageEdge[]
    for e in g.edges
        su, du = _unit_of(e.src), _unit_of(e.dst)
        su == du && continue
        push!(unit_edges, LineageEdge(su, du, e.label, copy(e.pulled), e.via, e.source))
    end

    unit_nodes = LineageNode[]
    for (u, agg) in units
        unique!(sort!(agg.scripts))
        push!(unit_nodes, LineageNode(u, agg.kind, agg.description, agg.timestamp,
                                      agg.content_hash, agg.vcs_ref,
                                      sort!(unique!(members[u])), agg.scripts))
    end
    sort!(unit_nodes; by = n -> n.name)
    return LineageGraph(g.project, :unit, unit_nodes, _dedup_edges(unit_edges))
end

# ─── Graphviz emission ──────────────────────────────────────────────────────

"""
    to_dot(g::LineageGraph; rankdir="LR", title=nothing, edge_labels=true) -> String

Render a [`LineageGraph`] as a Graphviz `dot` string. Nodes produced by scripts
that perform a fit are drawn in teal; other producing nodes are drawn in amber.
Pipe the result to `dot`, or use [`render_lineage`](@ref).
"""
function to_dot(g::LineageGraph; rankdir::AbstractString="LR",
                title::Union{Nothing,AbstractString}=nothing, edge_labels::Bool=true)
    io = IOBuffer()
    println(io, "// Lineage graph discovered from $(g.project)")
    println(io, "// granularity=:$(g.granularity)  $(length(g.nodes)) nodes  $(length(g.edges)) edges")
    println(io, "// Edges = the latest()/lookup() provenance reads in workflow scripts.")
    println(io, "digraph lineage {")
    println(io, "  rankdir=$(rankdir);")
    println(io, "  bgcolor=\"transparent\";")
    println(io, "  nodesep=0.34; ranksep=0.95;")
    println(io, "  node [shape=box, style=\"rounded,filled\", fontname=\"Helvetica\", fontsize=13, penwidth=1.5, margin=\"0.17,0.11\"];")
    println(io, "  edge [color=\"#8a8f93\", fontname=\"Helvetica\", fontsize=10, fontcolor=\"#5d6f72\", penwidth=1.4, arrowsize=0.85];")
    title === nothing || println(io, "  label=\"$(_dot_escape(title))\"; labelloc=t; fontname=\"Helvetica\"; fontsize=15;")
    for n in g.nodes
        fill, color = n.kind === :fit ? ("#dcefe9", "#2E8B72") :
                      n.kind === :prediction ? ("#ffe3bd", "#D9952F") :
                      ("#ececec", "#999999")
        println(io, "  \"$(_dot_escape(n.name))\" [label=$(_node_label(n)), fillcolor=\"$fill\", color=\"$color\"];")
    end
    for e in g.edges
        attrs = (edge_labels && !isempty(e.label)) ? " [label=\"$(_dot_escape(e.label))\"]" : ""
        println(io, "  \"$(_dot_escape(e.src))\" -> \"$(_dot_escape(e.dst))\"$attrs;")
    end
    println(io, "}")
    return String(take!(io))
end

# HTML-like label: bold name + (optional) discovered description sublabel.
function _node_label(n::LineageNode)
    desc = _strip_unit_prefix(n.description, n.name)
    if isempty(desc)
        return "\"$(_dot_escape(n.name))\""
    end
    d = _html_escape(length(desc) > 46 ? desc[1:43] * "…" : desc)
    return "<<b>$(_html_escape(n.name))</b><br/><font point-size=\"11\">$d</font>>"
end

function _strip_unit_prefix(desc::String, name::String)
    isempty(desc) && return desc
    u = _unit_of(name)
    stripped = replace(desc, Regex("^\\Q$u\\E[\\s:.)\\-]+") => "")
    return String(strip(stripped))
end

_dot_escape(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n")
_html_escape(s) = replace(String(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

"""
    render_lineage(g::LineageGraph, outpath; format=nothing, title=nothing, kwargs...) -> String

Write a [`LineageGraph`] to `outpath`. If `outpath` ends in `.dot` the Graphviz
source is written directly; otherwise the `dot` binary (if installed) renders to
the format inferred from the extension (e.g. `.svg`, `.png`, `.pdf`) or the
explicit `format`. Returns the path written. Extra keyword arguments are
forwarded to [`to_dot`](@ref).
"""
function render_lineage(g::LineageGraph, outpath::AbstractString;
                        format::Union{Nothing,AbstractString,Symbol}=nothing,
                        kwargs...)
    out = String(outpath)
    dot = to_dot(g; kwargs...)
    if endswith(lowercase(out), ".dot")
        write(out, dot)
        return out
    end
    fmt = format === nothing ? lstrip(splitext(out)[2], '.') : String(format)
    isempty(fmt) && (fmt = "svg")
    if Sys.which("dot") === nothing
        dotpath = out * ".dot"
        write(dotpath, dot)
        @warn "render_lineage: Graphviz `dot` not found on PATH; wrote source only" dotpath
        return dotpath
    end
    open(`dot -T$fmt -o $out`, "w") do io
        write(io, dot)
    end
    return out
end

# ─── Graphs.jl / MetaGraphsNext conversion (via package extension) ───────────

"""
    to_metagraph(g::LineageGraph) -> MetaGraph

Convert a [`LineageGraph`] into a `MetaGraphsNext.MetaGraph` carrying the node
and edge metadata as vertex/edge properties. Requires MetaGraphsNext to be
loaded:

```julia
using BookKit, MetaGraphsNext
mg = to_metagraph(lineage_graph(project))
```

The dependency-free [`LineageGraph`] itself already holds all metadata; this is
provided for interoperability with the Graphs.jl ecosystem.
"""
function to_metagraph(g; kwargs...)
    error("to_metagraph requires MetaGraphsNext. Run `using MetaGraphsNext` before " *
          "calling. The LineageGraph returned by " *
          "lineage_graph already carries all node/edge metadata — use to_dot(g) for Graphviz.")
end

# ─── helpers ────────────────────────────────────────────────────────────────

function _rel(path::String, root::String)
    ap, ar = abspath(path), abspath(root)
    endswith(ar, "/") || (ar *= "/")
    return startswith(ap, ar) ? ap[length(ar)+1:end] : ap
end
