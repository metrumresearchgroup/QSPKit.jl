"""
    Artifact(path)
    artifact(path)

A file to be booked as the result itself — a figure, CSV, report, etc.
`book!("site_preview", artifact("build/preview.png"))` stores the file's bytes as the result
blob (via raw-file blob storage) and records it as an on-disk dependency that the
staleness check cold-verifies. This routes around the fragile `Base.open`
attribution for outputs you want to book explicitly.
"""
struct Artifact
    path::String
end

"""
    artifact(path::AbstractString) -> Artifact

Wrap a file path for the artifact-specific [`book!`](@ref) workflow. The file
is stored as raw bytes and retained as a cold-verifiable dependency.
"""
artifact(path::AbstractString) = Artifact(String(path))

"""
    BookedResult

A result that has been booked via `book!()`, wrapping the original data with
provenance metadata. Supports property forwarding so that `result.files` works
by delegating to the stored data.

# Fields
- `name::String` — the booking name (e.g., `"site_bundle"`)
- `status::Symbol` — `:accepted` or `:rejected`
- `data::Any` — the actual result (named tuple, DataFrame, fitted result, etc.)
- `rationale::String` — why this result was booked with this status
"""
struct BookedResult
    name::String
    status::Symbol
    data::Any
    rationale::String
end

# Property forwarding: BookedResult fields first, then delegate to data
function Base.getproperty(r::BookedResult, s::Symbol)
    s in fieldnames(BookedResult) && return getfield(r, s)
    data = getfield(r, :data)
    return getproperty(data, s)
end

function Base.propertynames(r::BookedResult)
    own = collect(fieldnames(BookedResult))
    data = getfield(r, :data)
    try
        return vcat(own, collect(propertynames(data)))
    catch
        return own
    end
end

function Base.show(io::IO, r::BookedResult)
    print(io, "BookedResult(\"$(r.name)\", :$(r.status))")
end

"""
    DimResult

One dimension of a [`StalenessReport`].

# Fields
- `checked::Bool` — was this dimension actually evaluated (false ⇒ no data to check)
- `stale::Bool`   — did this dimension detect drift
- `details::Vector{String}` — human-readable descriptions of what changed (or notes)
"""
struct DimResult
    checked::Bool
    stale::Bool
    details::Vector{String}
end
DimResult() = DimResult(false, false, String[])

"""
    StalenessReport

Structured result of checking whether a booked result is stale, across every
dimension BookKit can verify. `revision` is the annotation id actually evaluated.

# Fields
- `name::String`, `revision::Int`
- `files::DimResult`    — attributed data files re-hashed vs their snapshots
- `upstream::DimResult` — consumed upstream results whose current content drifted from the pinned hash (transitive)
- `vcs::DimResult`      — VCS ref recorded at booking vs the current working tree
- `blob::DimResult`     — the result blob re-hashed vs its content-addressed key
- `fingerprints::DimResult` — in-memory dependency fingerprints (params/model/solver/source) vs the prior booking (diff-at-rebook)

Use [`is_stale`](@ref) for the overall verdict.
"""
struct StalenessReport
    name::String
    revision::Int
    files::DimResult
    upstream::DimResult
    vcs::DimResult
    blob::DimResult
    fingerprints::DimResult
end

"""
    is_stale(r::StalenessReport) -> Bool

True if any checked dimension detected drift.
"""
is_stale(r::StalenessReport) = r.files.stale || r.upstream.stale || r.vcs.stale || r.blob.stale || r.fingerprints.stale

function Base.show(io::IO, r::StalenessReport)
    status = is_stale(r) ? "STALE" : "fresh"
    println(io, "StalenessReport(\"$(r.name)\" rev=$(r.revision)): $status")
    for (label, d) in (("files", r.files), ("upstream", r.upstream), ("vcs", r.vcs), ("blob", r.blob), ("fingerprints", r.fingerprints))
        mark = !d.checked ? "-" : (d.stale ? "x" : "ok")
        println(io, "  [$mark] $label")
        for line in d.details
            println(io, "        $line")
        end
    end
end
