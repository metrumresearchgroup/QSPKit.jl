# book!() — the core function

# ──────────────────────────────────────────────────────────────────────────
# Consumption log
#
# `lookup()` records every booked result it reads into a task-local log; the
# next `book!()` drains it and persists the reads as dependency edges. This is
# what lets `lineage_graph` recover the compute DAG from the store alone — the
# provenance store ends up encoding which upstream result fed which downstream
# computation, exactly as the user wrote
# `manifest = lookup("content_manifest"); book!("site_bundle", ...)`.
# ──────────────────────────────────────────────────────────────────────────

const _CONSUMED_KEY = :_bookkit_consumed

"""
    _record_consumption!(name; result_hash=nothing)

Record that the booked result `name` was just read (via `lookup`), so the next
`book!` can persist it as a dependency edge. Stored in task-local storage.
"""
function _record_consumption!(name::String; result_hash::Union{String,Nothing}=nothing)
    log = get!(task_local_storage(), _CONSUMED_KEY, Vector{NamedTuple}())::Vector{NamedTuple}
    push!(log, (name=name, result_hash=result_hash))
    return nothing
end

"""
    _drain_consumption!() -> Vector{NamedTuple}

Return and clear the task-local consumption log. Deduplicates by name,
keeping the most recent read of each upstream result.
"""
function _drain_consumption!()
    log = get(task_local_storage(), _CONSUMED_KEY, nothing)
    log === nothing && return NamedTuple[]
    delete!(task_local_storage(), _CONSUMED_KEY)
    seen = Dict{String,NamedTuple}()
    for entry in log
        seen[entry.name] = entry          # last write wins
    end
    return collect(values(seen))
end

"""
    clear_consumption!()

Discard any pending consumption log for the current task. Useful in tests or
when `lookup` reads should not be attributed to the next `book!`.
"""
clear_consumption!() = (delete!(task_local_storage(), _CONSUMED_KEY); nothing)

"""
    book!(name, status; result=nothing, rationale="", fit_quality=nothing, loss=nothing, inputs=String[], store_dir=_default_store_dir())

Record a result with provenance. This is the primary user-facing function.

# Arguments
- `name::String` — identifier for this result (e.g., `"site_bundle"`)
- `status::Symbol` — `:accepted` or `:rejected`

# Keyword Arguments
- `result` — the result object to store (serialized to blob store)
- `rationale::String` — explanation for the booking decision
- `fit_quality` — optional Dict or object describing fit quality metrics
- `loss` — optional numeric loss/score value
- `inputs` — upstream result names this computation consumed, recorded as
  dependency edges. Accepts a `Vector{String}` of names, or a vector of
  `name => label` pairs to annotate what was pulled. Reads captured
  automatically via `lookup` are merged in (see [`clear_consumption!`](@ref)).
- `fingerprints::Dict{String,String}` — in-memory dependency fingerprints to
  record (e.g. `"params"`, `"model"`, `"solver"`, `"source"` => a hash). Compared
  against the prior booking of `name` by the staleness check (diff-at-rebook),
  since in-memory deps have nothing on disk to cold-re-hash.
- `store_dir::String` — project directory for provenance storage

# What happens
1. Serializes `result` to the blob store
2. Determines file attribution (which files contributed to this result)
3. Hashes and stores attributed files as file snapshots
4. Records dependency edges (consumed upstream results) for lineage tracking
5. Writes a `.decision.md` summary
6. Records the VCS ref (git/svn)
7. Returns a `BookedResult`
"""
const VALID_STATUSES = (:accepted, :rejected)

function book!(name::String, status::Symbol;
    result = nothing,
    rationale::String = "",
    fit_quality = nothing,
    loss::Union{Real, Nothing} = nothing,
    inputs = String[],
    fingerprints::Dict{String,String} = Dict{String,String}(),
    metrics::Union{AbstractDict,Nothing} = nothing,
    capture_env::Bool = true,
    store_dir::String = _default_store_dir(),
)
    # Fold loss <-> metrics so the queryable `loss` column and the open metrics
    # table agree (loss stays a privileged, queryable scalar).
    metrics_d = metrics === nothing ? Dict{String,Any}() :
                Dict{String,Any}(string(k) => v for (k, v) in metrics)
    if loss === nothing && get(metrics_d, "loss", nothing) isa Real
        loss = metrics_d["loss"]
    elseif loss !== nothing
        # The explicit `loss` kwarg is authoritative; keep both stores consistent
        # (warn if metrics carried a different loss rather than diverging silently).
        if haskey(metrics_d, "loss") && metrics_d["loss"] != loss
            @warn "BookKit: loss=$loss overrides metrics[\"loss\"]=$(metrics_d["loss"])"
        end
        metrics_d["loss"] = loss
    end
    # `fit_quality` is deprecated in favor of the open `metrics` dict; fold it in so
    # it is queryable there (the legacy fit_quality column is still written below).
    if fit_quality !== nothing && !haskey(metrics_d, "fit_quality")
        metrics_d["fit_quality"] = string(fit_quality)
    end
    status ∈ VALID_STATUSES || error("BookKit: Invalid status :$status. Must be one of: $(join(VALID_STATUSES, ", "))")
    # Snapshot upstream reads captured via lookup() before doing anything else.
    auto_inputs = _drain_consumption!()
    store = open_store(store_dir)

    # book!'s own internal file reads below (result/artifact/Manifest blobbing) must
    # not pollute attribution — record the mark and truncate back to it on EVERY exit
    # (the `finally` runs on early return AND on exceptions).
    _reads_mark = length(StoreKit.FILE_READS)
    try

    # Capture the package environment. Julia VERSION (+ Manifest hash) ride
    # the fingerprints map (diff-at-rebook, so a Julia/env change forces a new
    # booking); the active Manifest.toml is also snapshotted below as a
    # cold-verifiable file dependency. Work on a copy so the caller's dict is intact.
    fps = copy(fingerprints)
    manifest_path = capture_env ? _manifest_path() : nothing
    if capture_env
        fps["julia_version"] = string(VERSION)
        # Numerical-environment knobs that can change floating-point results
        # (thread/BLAS reduction order, CPU/OS). Diff-at-rebook fingerprints.
        fps["julia_threads"] = string(Threads.nthreads())
        fps["blas_threads"]  = string(BLAS.get_num_threads())
        fps["cpu"]           = string(Sys.ARCH)
        fps["os"]            = string(Sys.KERNEL)
        if manifest_path !== nothing && isfile(manifest_path)
            fps["julia_manifest_hash"] = StoreKit.hash_file(manifest_path)
        end
    end

    # 1. Serialize result to blob store. An Artifact is stored as its raw file
    #    bytes (so the same blob hash == hash_file, making it cold-verifiable);
    #    anything else is JLD2-serialized.
    result_hash = if result isa Artifact
        apath = abspath(result.path)
        isfile(apath) || error("BookKit: artifact file not found: $apath")
        StoreKit.blob_put_file!(store, apath)
    elseif isnothing(result)
        nothing
    else
        blob_put!(store, result; type="result")
    end

    # For an Artifact, the booked .data is the file bytes (matching what `lookup`
    # returns), not the wrapper — a consistent result contract across book!/lookup.
    result_data = result isa Artifact ? blob_get_file(store, result_hash) : result

    # 2. Determine which files contributed to this result
    attributed_files = Set{String}()
    if !isempty(StoreKit.SESSION_LOG)
        # Interactive mode: precise attribution via session log
        result_var = _find_result_var(result)
        if result_var !== nothing
            attribution = files_for_result(result_var)
            attributed_files = attribution.data_files
        end
    else
        # Script mode: use FILE_READS as best-effort attribution
        for fr in StoreKit.FILE_READS
            StoreKit._is_read_mode(fr.mode) || continue   # skip files opened for writing (outputs)
            push!(attributed_files, fr.path)
        end
    end

    # Filter out package internals — only track project-local files. Use the
    # data-file predicate (not the .jl-only _is_user_file): book! attributes
    # data dependencies (.csv, .txt, …), not just source files.
    filter!(f -> StoreKit._is_attributable_file(f), attributed_files)

    # An Artifact / the Manifest are snapshotted explicitly (steps 5b/5c); drop them
    # here so book!'s own blob_put_file!/hash_file reads (logged in FILE_READS) aren't
    # double-snapshotted as data dependencies.
    result isa Artifact && delete!(attributed_files, abspath(result.path))
    manifest_path !== nothing && delete!(attributed_files, abspath(manifest_path))

    # 3. VCS state
    vcs_ref, vcs_dirty = _vcs_describe()

    # 4. Check if this is a duplicate of the latest booking (same result, same status)
    # Like git — don't create empty commits
    prev = StoreKit.latest_annotation(store.db, name)
    if prev !== nothing && _str_or_nothing(prev.result_hash) == result_hash &&
       prev.status == string(status) &&
       something(_str_or_nothing(prev.rationale), "") == rationale &&
       _fingerprints_match(store, prev.id, fps) &&
       _metrics_match(store, prev.id, metrics_d)
        @info "BookKit: '$name' unchanged — skipping duplicate booking"
        return BookedResult(name, status, result_data, rationale)   # finally truncates FILE_READS
    end

    # 5. Insert annotation into SQLite
    fq_str = fit_quality !== nothing ? string(fit_quality) : nothing
    annotation_id = StoreKit.insert_annotation!(store.db;
        name=name,
        status=string(status),
        rationale=rationale,
        fit_quality=fq_str,
        result_hash=result_hash,
        loss=loss,
        vcs_ref=vcs_ref,
        vcs_dirty=vcs_dirty,
    )

    # 5. Store attributed file contents as blobs and record snapshots.
    # blob_put_file! keys the blob by the file's raw SHA-256 (matching hash_file,
    # which lookup's verify check uses) so the snapshot's content_hash both
    # references the stored blob (for restore) and matches re-hashing the live
    # file (for verify). Relativize against `store_dir` (the booking's root) so the
    # staleness check, which resolves snapshot paths against `store_dir`, agrees.
    project_root = store_dir
    for path in attributed_files
        isfile(path) || continue
        content_hash = StoreKit.blob_put_file!(store, path)
        rel = _relative_path(path, project_root)
        StoreKit.insert_file_snapshot!(store.db, annotation_id, rel, content_hash, "data")
    end

    # 6. Record dependency edges (consumed upstream results)
    for inp in _normalize_inputs(inputs, auto_inputs)
        inp.name == name && continue   # ignore self-references
        StoreKit.insert_result_input!(store.db, annotation_id, inp.name;
            input_hash=inp.result_hash, label=inp.label)
    end

    # 5b. Snapshot the artifact file itself as a cold-verifiable dependency
    #     (explicit, so it is recorded even if it lives outside the project root).
    if result isa Artifact
        rel = _relative_path(abspath(result.path), project_root)
        StoreKit.insert_file_snapshot!(store.db, annotation_id, rel, result_hash, "data")
    end

    # 5c. Snapshot the active Manifest.toml as a cold-verifiable environment
    #     dependency (so the files dimension flags a dependency/version change).
    if capture_env && manifest_path !== nothing && isfile(manifest_path)
        mhash = StoreKit.blob_put_file!(store, manifest_path)
        msnap = _relative_path(manifest_path, project_root)
        StoreKit.insert_file_snapshot!(store.db, annotation_id, msnap, mhash, "env")
    end

    # 6b. Record in-memory dependency fingerprints (params/model/solver/source/env…)
    for (k, v) in fps
        StoreKit.insert_result_fingerprint!(store.db, annotation_id, String(k), String(v))
    end

    # 6c. Record advisory metrics
    for (k, v) in metrics_d
        StoreKit.insert_metric!(store.db, annotation_id, String(k), string(v))
    end

    # 7. Generate .decision.md
    rel_files = Set{String}(_relative_path(f, project_root) for f in attributed_files if isfile(f))
    _write_decision_md(store_dir, name, status, rationale, fit_quality, result, rel_files)

    return BookedResult(name, status, result_data, rationale)
    finally
        StoreKit.truncate_file_reads!(_reads_mark)   # drop book!'s own internal reads, even on error
    end
end

"""
    _normalize_inputs(inputs, auto_inputs) -> Vector{NamedTuple}

Merge explicit `inputs` (a vector of `String` names or `name => label` pairs)
with reads captured automatically via `lookup`. Deduplicates by name; an
explicit entry overrides an auto-captured one (so a user-supplied label wins).
"""
function _normalize_inputs(inputs, auto_inputs)
    merged = Dict{String,NamedTuple}()
    for entry in auto_inputs
        merged[entry.name] = (name=entry.name, result_hash=get(entry, :result_hash, nothing), label=nothing)
    end
    for item in inputs
        if item isa Pair
            nm, lbl = string(first(item)), string(last(item))
            prev = get(merged, nm, nothing)
            merged[nm] = (name=nm, result_hash=prev === nothing ? nothing : prev.result_hash, label=lbl)
        else
            nm = string(item)
            haskey(merged, nm) || (merged[nm] = (name=nm, result_hash=nothing, label=nothing))
        end
    end
    return collect(values(merged))
end

"""
    _fingerprints_match(store, prev_id, fingerprints) -> Bool

True if the fingerprints already stored for annotation `prev_id` equal the given
`fingerprints` dict. Used to widen the duplicate-booking skip so a re-booking that
changes ONLY an in-memory fingerprint (e.g. params/solver) is still recorded.
"""
function _fingerprints_match(store, prev_id, fingerprints)
    prev = Dict(e.key => e.value for e in StoreKit.get_result_fingerprints(store.db, prev_id))
    cur = Dict(String(k) => String(v) for (k, v) in fingerprints)
    return prev == cur
end

"""
    _metrics_match(store, prev_id, metrics_d) -> Bool

True if the metrics already stored for `prev_id` equal `metrics_d` (string-encoded
as they are persisted). Part of the duplicate-skip identity so a re-booking that
changes only `loss`/`metrics` (e.g. re-scoring a result) is still recorded rather
than silently dropped. (`loss` is folded into `metrics_d`, so this covers it.)
"""
function _metrics_match(store, prev_id, metrics_d)
    prev = Dict(e.key => e.value for e in StoreKit.get_metrics(store.db, prev_id))
    cur = Dict(String(k) => string(v) for (k, v) in metrics_d)
    return prev == cur
end

"""
    _default_store_dir() -> String

Return the default store directory (current working directory).
"""
_default_store_dir() = pwd()

"""
    _manifest_path() -> String or nothing

Path to the active project's `Manifest.toml` (via `Base.active_project()`), or
`nothing` when there is no active project. Existence is checked at the call site
(the Manifest may legitimately be absent, e.g. an unresolved env or a Pkg app).
"""
function _manifest_path()
    p = Base.active_project()
    p === nothing && return nothing
    dir = dirname(p)
    # Resolve like Pkg: version-specific manifests are preferred over the plain name.
    v = "$(VERSION.major).$(VERSION.minor)"
    for name in ("Manifest-v$v.toml", "JuliaManifest-v$v.toml", "Manifest.toml", "JuliaManifest.toml")
        cand = joinpath(dir, name)
        isfile(cand) && return cand
    end
    return joinpath(dir, "Manifest.toml")   # default candidate; existence checked by caller
end

"""
    _relative_path(path, root) -> String

Compute the relative path of `path` with respect to `root`.
Falls back to the absolute path if relativizing fails.
"""
function _relative_path(path::String, root::String)
    abs_path = abspath(path)
    abs_root = abspath(root)
    if !endswith(abs_root, "/")
        abs_root *= "/"
    end
    if startswith(abs_path, abs_root)
        return abs_path[length(abs_root)+1:end]
    end
    return abs_path
end

"""
    _find_result_var(result) -> Union{Symbol, Nothing}

Find which session log variable holds `result` by walking SESSION_LOG backward
and checking identity (===) against Main module bindings.
"""
function _find_result_var(result)
    result === nothing && return nothing
    for entry in reverse(StoreKit.SESSION_LOG)
        for sym in entry.defs
            try
                val = getfield(Main, sym)
                if val === result
                    return sym
                end
            catch
                continue
            end
        end
    end
    return nothing
end
