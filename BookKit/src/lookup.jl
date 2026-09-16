# lookup() and history()

"""
    lookup(name; store_dir=_default_store_dir(), verify=false) -> BookedResult

Retrieve the latest booked result for `name`.

If `verify=true`, checks whether any attributed files have changed since
booking and emits a warning if so.
"""
function lookup(name::String; store_dir::String=_default_store_dir(), verify::Bool=false)
    store = open_store(store_dir)
    row = StoreKit.latest_annotation(store.db, name)
    isnothing(row) && throw(KeyError("No booked result found for '$name'"))

    rh = _str_or_nothing(row.result_hash)   # SQLite NULL surfaces as `missing` → fold to nothing
    report = verify ? _staleness_report(store, store_dir, name, row; recurse=true) : nothing

    # Load the result. On the default path a missing/corrupt blob throws (fail loud,
    # as before). Under verify the blob dimension already records the problem, so we
    # degrade to `nothing` instead of throwing, keeping the booking inspectable.
    result = if rh === nothing
        nothing
    elseif verify && report.blob.stale
        nothing
    else
        _load_blob(store, rh)
    end
    booked = BookedResult(name, Symbol(row.status), result, something(row.rationale, ""))

    # Record this read so the next book! can capture the dependency edge.
    _record_consumption!(name; result_hash=rh)

    if verify && is_stale(report)
        dims = String[]
        report.files.stale        && push!(dims, "files")
        report.upstream.stale     && push!(dims, "upstream")
        report.vcs.stale          && push!(dims, "vcs")
        report.blob.stale         && push!(dims, "blob")
        report.fingerprints.stale && push!(dims, "fingerprints")
        @warn "$name may be stale: $(join(dims, ", "))" report
    end

    return booked
end

"""
    _load_blob(store, hash)

Load a result blob, picking the right reader by the blob's stored type: raw bytes
for a `"file"` blob (an [`Artifact`](@ref)), JLD2-deserialized object otherwise.
"""
function _load_blob(store, hash::String)
    rec = StoreKit.blob_record(store.db, hash)
    # Missing metadata (corrupt/legacy store) → read raw bytes (always succeeds)
    # rather than assuming a JLD2 envelope and throwing.
    return (rec === nothing || rec.type == "file") ? blob_get_file(store, hash) : blob_get(store, hash)
end

"""
    staleness(name; store_dir=_default_store_dir(), recurse=true, revision=:latest) -> StalenessReport

Check whether the booked result `name` is stale across every verifiable
dimension and return a structured [`StalenessReport`](@ref) (no warning emitted —
use the report's [`is_stale`](@ref) verdict). Dimensions:

- **files** — attributed data files re-hashed against their snapshots
- **upstream** — consumed upstream results whose current content has drifted from
  the hash pinned at booking time (transitive when `recurse=true`)
- **vcs** — the VCS ref recorded at booking vs the current working tree
- **blob** — the result blob re-hashed against its content-addressed key

`revision` selects which booking to check: `:latest` (default) or an annotation
id (`Integer`) for a specific past revision.
"""
function staleness(name::String; store_dir::String=_default_store_dir(),
                   recurse::Bool=true, revision::Union{Symbol,Integer}=:latest)
    store = open_store(store_dir)
    row = _select_annotation(store, name, revision)
    isnothing(row) && throw(KeyError(
        "No booked result found for '$name'" * (revision === :latest ? "" : " (revision $revision)")))
    return _staleness_report(store, store_dir, name, row; recurse=recurse)
end

"""
    staleness_sweep(; store_dir=_default_store_dir(), recurse=true, stale_only=true) -> Vector{Tuple{String,StalenessReport}}

Check every booked result in the store and return `(name, report)` pairs — a
project-wide "what is stale now?" query. By default only stale results are
returned; `stale_only=false` returns a report for every booked name.
"""
function staleness_sweep(; store_dir::String=_default_store_dir(),
                         recurse::Bool=true, stale_only::Bool=true)
    store = open_store(store_dir)
    out = Tuple{String,StalenessReport}[]
    for name in StoreKit.distinct_annotation_names(store.db)
        r = staleness(name; store_dir=store_dir, recurse=recurse)
        (!stale_only || is_stale(r)) && push!(out, (name, r))
    end
    return out
end

"""
    _select_annotation(store, name, revision) -> row or nothing

Resolve `revision` (`:latest` or an annotation id) to an annotation row scoped
to `name`.
"""
function _select_annotation(store, name::String, revision::Union{Symbol,Integer})
    if revision === :latest
        return StoreKit.latest_annotation(store.db, name)
    elseif revision isa Integer && !(revision isa Bool)
        row = StoreKit.annotation_by_id(store.db, revision)
        (row === nothing || row.name != name) && return nothing
        return row
    else
        throw(ArgumentError("revision must be :latest or an annotation id (Integer), got $(revision)"))
    end
end

"""
    _staleness_report(store, store_dir, name, row; recurse=true) -> StalenessReport

Build the four-dimension report for an already-resolved annotation `row`.
"""
function _staleness_report(store, store_dir::String, name::String, row; recurse::Bool=true)
    files    = _files_dim(store, store_dir, row)
    upstream = _upstream_dim(store, name, row; recurse=recurse)
    vcs      = _vcs_dim(row)
    blob     = _blob_dim(store, row)
    fps      = _fingerprints_dim(store, name, row)
    return StalenessReport(name, Int(row.id), files, upstream, vcs, blob, fps)
end

# ── per-dimension checks ────────────────────────────────────────────────────

function _files_dim(store, store_dir::String, row)
    snapshots = StoreKit.get_file_snapshots(store.db, row.id)
    isempty(snapshots) && return DimResult()   # nothing attributed → not verifiable
    changed = String[]
    for snap in snapshots
        full = _resolve_path(snap.path, store_dir)
        current = isfile(full) ? hash_file(full) : "DELETED"
        if current != snap.content_hash
            push!(changed, current == "DELETED" ? "$(snap.path) (deleted)" : "$(snap.path) (modified)")
        end
    end
    return DimResult(true, !isempty(changed), changed)
end

function _blob_dim(store, row)
    rh = _str_or_nothing(row.result_hash)   # NULL (surfaces as missing) → no payload
    rh === nothing && return DimResult()
    status = StoreKit.blob_verify(store, rh)
    status === :ok && return DimResult(true, false, String[])
    msg = status === :missing ?
        "result blob missing ($(_short(rh)))" :
        "result blob corrupt — bytes no longer hash to $(_short(rh))"
    return DimResult(true, true, [msg])
end

"""
    _prior_annotation(store, name, row) -> annotation row or nothing

The booking of `name` immediately preceding `row` (largest annotation id strictly
less than `row.id`); annotation id is BookKit's canonical revision order.
"""
function _prior_annotation(store, name::String, row)
    for a in StoreKit.all_annotations(store.db, name)   # ordered by id DESC
        a.id < row.id && return a
    end
    return nothing
end

# In-memory dependency fingerprints (params/model/solver/source): captured at book!
# time, so they cannot be cold-re-hashed like files — instead compare this booking's
# fingerprints to the immediately-prior booking of the same name (diff-at-rebook). A
# fingerprint is stale when a key present in BOTH bookings has a changed value; keys
# added/removed between bookings are informational, not stale.
function _fingerprints_dim(store, name::String, row)
    cur = StoreKit.get_result_fingerprints(store.db, row.id)
    isempty(cur) && return DimResult()   # nothing captured → not verifiable
    prior = _prior_annotation(store, name, row)
    prior === nothing && return DimResult(true, false, ["first booking — no prior fingerprints to compare"])
    curd  = Dict(e.key => e.value for e in cur)
    prevd = Dict(e.key => e.value for e in StoreKit.get_result_fingerprints(store.db, prior.id))
    changed = String[]
    notes = String[]
    for (k, v) in curd
        if haskey(prevd, k)
            prevd[k] != v && push!(changed, "$k changed: $(_short(prevd[k])) → $(_short(v))")
        else
            push!(notes, "$k added (not in prior booking)")
        end
    end
    for k in keys(prevd)
        haskey(curd, k) || push!(notes, "$k removed (was in prior booking)")
    end
    return DimResult(true, !isempty(changed), vcat(changed, notes))
end

function _vcs_dim(row)
    stored = _str_or_nothing(row.vcs_ref)
    stored === nothing && return DimResult(false, false, ["no VCS ref recorded at booking"])
    cur_ref, cur_dirty = _vcs_describe()
    if _is_unknown_ref(stored) || _is_unknown_ref(cur_ref)
        return DimResult(false, false, ["VCS unavailable for comparison (stored=$stored, current=$cur_ref)"])
    end
    if _base_ref(stored) != _base_ref(cur_ref)
        return DimResult(true, true, ["VCS ref changed: was $stored, now $cur_ref"])
    end
    # Same committed ref — dirtiness differences are informational, not stale.
    stored_dirty = _to_bool_or_nothing(row.vcs_dirty)
    notes = String[]
    if stored_dirty === true && cur_dirty
        push!(notes, "working tree was dirty at booking and is dirty now (ref $(_base_ref(cur_ref)))")
    elseif stored_dirty === true
        push!(notes, "booked from a dirty working tree (ref $(_base_ref(cur_ref)))")
    elseif cur_dirty
        push!(notes, "working tree now dirty (ref $(_base_ref(cur_ref)))")
    end
    return DimResult(true, false, notes)
end

function _upstream_dim(store, name::String, row; recurse::Bool=true)
    visited = Set{String}([name])
    findings = _check_upstream_staleness(store, row.id; visited=visited, recurse=recurse, max_depth=64, depth=0)
    isempty(findings) && return DimResult()   # no recorded upstream edges
    stale = false
    details = String[]
    for f in findings
        if f.status === :drifted
            stale = true
            push!(details, "$(f.name) drifted: pinned $(_short(f.pinned)) → now $(_short(f.current))")
        elseif f.status === :dangling
            push!(details, "$(f.name) dangling (never booked)")
        elseif f.status === :unpinned
            push!(details, "$(f.name) unpinned (no baseline hash to compare)")
        elseif f.status === :upstream_no_hash
            push!(details, "$(f.name) has no result blob to compare")
        elseif f.status === :depth_exceeded
            push!(details, "upstream analysis truncated at max depth")
        end
        # :fresh → no detail line
    end
    return DimResult(true, stale, unique(details))
end

"""
    _check_upstream_staleness(store, annotation_id; visited, recurse, max_depth, depth) -> Vector

Compare each recorded upstream input's pinned hash to that upstream's *current*
result hash, recursing transitively (cycle-guarded by `visited`, keyed on
upstream name). Returns per-edge findings `(name, status, pinned, current)` with
`status ∈ (:drifted, :fresh, :unpinned, :upstream_no_hash, :dangling, :depth_exceeded)`.
Only `:drifted` is treated as staleness; the rest are informational.
"""
function _check_upstream_staleness(store, annotation_id::Integer; visited::Set{String},
                                   recurse::Bool, max_depth::Int, depth::Int)
    findings = NamedTuple[]
    if depth > max_depth
        push!(findings, (name="", status=:depth_exceeded, pinned=nothing, current=nothing))
        return findings
    end
    for inp in StoreKit.get_result_inputs(store.db, annotation_id)
        up = String(inp.input_name)
        pinned = _str_or_nothing(inp.input_hash)
        up_row = StoreKit.latest_annotation(store.db, up)
        if up_row === nothing
            push!(findings, (name=up, status=:dangling, pinned=pinned, current=nothing))
            continue
        end
        current = _str_or_nothing(up_row.result_hash)
        status = pinned === nothing       ? :unpinned :
                 current === nothing      ? :upstream_no_hash :
                 pinned == current        ? :fresh : :drifted
        push!(findings, (name=up, status=status, pinned=pinned, current=current))
        if recurse && !(up in visited)
            push!(visited, up)
            append!(findings, _check_upstream_staleness(store, up_row.id;
                visited=visited, recurse=recurse, max_depth=max_depth, depth=depth + 1))
        end
    end
    return findings
end

# ── normalization helpers ───────────────────────────────────────────────────

# `_str_or_nothing` (defined in lineage.jl, shared across BookKit) folds SQLite
# NULLs (nothing/missing) to nothing; empty refs are caught by `_is_unknown_ref`.
_to_bool_or_nothing(x) = (x === nothing || x isa Missing) ? nothing : (x isa Bool ? x : !iszero(x))

function _is_unknown_ref(r::AbstractString)
    isempty(r) && return true
    r in ("unknown", "git:unknown", "svn:unknown") && return true
    # svn non-revision outputs, e.g. svnversion "exported" / "Unversioned directory"
    startswith(r, "svn:r") && return !occursin(r"\d", r)
    return false
end

# Reduce a VCS ref to its committed identity for comparison: strip git's "-dirty"
# suffix and svn's working-copy status (mixed-rev range a:b → b; trailing M/S/P),
# so a merely-dirty tree at the same revision is not mistaken for a ref change.
function _base_ref(r::AbstractString)
    if startswith(r, "svn:r")
        body = String(last(split(r[6:end], ':')))   # "123:125M" → "125M"
        body = rstrip(body, ('M', 'S', 'P'))         # drop svnversion status letters
        return "svn:r" * body
    end
    return endswith(r, "-dirty") ? r[1:end-6] : r
end
_short(h) = h === nothing ? "∅" : (length(h) > 8 ? String(first(h, 8)) : String(h))

"""
    history(name; store_dir=_default_store_dir())

Print a summary of all annotations for `name`, ordered newest first.
"""
function history(name::String; store_dir::String=_default_store_dir())
    store = open_store(store_dir)
    rows = StoreKit.all_annotations(store.db, name)

    if isempty(rows)
        println("No history for '$name'")
        return nothing
    end

    println("History for '$name' ($(length(rows)) entries):")
    println("-"^60)
    for row in rows
        status_str = row.status
        ts = row.timestamp
        vcs = something(row.vcs_ref, "-")
        rationale = something(row.rationale, "")
        short_rationale = length(rationale) > 50 ? rationale[1:50] * "..." : rationale
        loss_str = row.loss !== nothing ? " loss=$(round(row.loss; digits=4))" : ""
        println("  #$(row.id)  [$status_str]  $ts  vcs=$vcs$loss_str")
        if !isempty(short_rationale)
            println("        $short_rationale")
        end
    end
    println("-"^60)

    return rows
end

"""
    _resolve_path(rel_path, project_root) -> String

Resolve a relative path stored in file_snapshots to an absolute path.
"""
function _resolve_path(rel_path::String, project_root::String)
    isabspath(rel_path) && return rel_path
    return joinpath(abspath(project_root), rel_path)
end
