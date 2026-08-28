# book_extract — typed extraction for the no-ceremony `book!(name, result)` path.
#
# `book_extract(r)` lets a result type describe how it should be booked: what to
# store, its status, its metrics, and its dependency fingerprints — so the
# scientist never hand-copies loss/params/source. Package extensions
# (BookKitTargKitExt, BookKitSimKitExt) add methods for FitResult / SimContext;
# the generic fallback books any object opaquely.

"""
    book_extract(r) -> NamedTuple

Describe how to book result object `r`. Returns a NamedTuple with fields (any
subset; missing fields are defaulted):

- `kind::Symbol`        — `:fit`, `:prediction`, `:artifact`, `:generic`, …
- `payload`             — the object to store as the result blob (default `r`)
- `status_hint::Union{Symbol,Nothing}` — suggested `:accepted`/`:rejected` (or `nothing`)
- `fingerprints::Dict{String,String}`  — in-memory dependency hashes (params/model/solver/source)
- `metrics::Union{AbstractDict,Nothing}` — advisory metrics (loss, rmse, …)
- `fit_quality`         — optional fit-quality object
- `inputs`              — upstream result names (as `book!` accepts)

The generic fallback books `r` opaquely with no derived status (caller must pass
`status=`). Specialize this for your result type to get zero-ceremony booking.
"""
book_extract(r) = (
    kind = :generic,
    payload = r,
    status_hint = nothing,
    fingerprints = Dict{String,String}(),
    metrics = nothing,
    fit_quality = nothing,
    inputs = String[],
)

# A file artifact books as :accepted with the Artifact as payload (book! stores it
# as a raw-file blob + a cold-verifiable file dependency).
book_extract(a::Artifact) = (
    kind = :artifact,
    payload = a,
    status_hint = :accepted,
    fingerprints = Dict{String,String}(),
    metrics = nothing,
    fit_quality = nothing,
    inputs = String[],
)

"""
    book!(name, result; status=nothing, rationale="", inputs=String[], store_dir=...) -> BookedResult

No-ceremony booking: dispatch on `result`'s type via [`book_extract`](@ref) to
derive the payload, status, metrics, and dependency fingerprints automatically.
`status` (if given) overrides the extracted `status_hint`. The explicit
`book!(name, status::Symbol; ...)` remains the lower-level escape hatch (selected
by dispatch when the second argument is a `Symbol`).
"""
function book!(name::String, result; status::Union{Symbol,Nothing}=nothing,
               rationale::String="", inputs=String[],
               store_dir::String=_default_store_dir())
    et = _extract_tuple(book_extract(result), result)
    final_status = _resolve_status(et.status_hint, status)
    return book!(name, final_status;
        result      = et.payload,
        rationale   = rationale,
        fit_quality = et.fit_quality,
        fingerprints = et.fingerprints,
        metrics     = et.metrics,
        inputs      = _merge_inputs(inputs, et.inputs),
        store_dir   = store_dir)
end

"""
    _extract_tuple(nt, fallback_payload=nothing) -> NamedTuple

Normalize a (possibly partial) `book_extract` return value to the full field set,
coercing `fingerprints` to `Dict{String,String}`. An extractor that omits
`payload` defaults to `fallback_payload` (the original result object) so a partial
extractor still stores a result blob.
"""
function _extract_tuple(nt, fallback_payload=nothing)
    return (
        kind        = get(nt, :kind, :generic),
        payload     = get(nt, :payload, fallback_payload),
        status_hint = get(nt, :status_hint, nothing),
        fingerprints = _to_str_dict(get(nt, :fingerprints, Dict{String,String}())),
        metrics     = get(nt, :metrics, nothing),
        fit_quality = get(nt, :fit_quality, nothing),
        inputs      = get(nt, :inputs, String[]),
    )
end

_to_str_dict(d::Dict{String,String}) = d
_to_str_dict(d) = Dict{String,String}(string(k) => string(v) for (k, v) in d)

"""
    _resolve_status(hint, override) -> Symbol

Explicit `override` wins; else the extractor's `hint`; else error loudly (no
silent default).
"""
function _resolve_status(hint, override)
    override !== nothing && return override
    hint !== nothing && return hint
    error("BookKit: book!(name, result) could not derive a status " *
          "(book_extract returned status_hint=nothing); pass status= explicitly")
end

# Combine caller inputs with extractor-supplied inputs (both in the shape book!
# accepts: a vector of names or name => label pairs).
_merge_inputs(a, b) = vcat(collect(a), collect(b))
