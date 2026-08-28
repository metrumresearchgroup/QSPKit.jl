"""
    Store

Content-addressed blob store backed by SQLite metadata and filesystem blobs.

# Fields
- `dir::String` — path to the `.provenance/` directory
- `db::SQLite.DB` — handle to `provenance.db` within `dir`
"""
struct Store
    dir::String
    db::SQLite.DB
end

const _STORE_CACHE = Dict{String, Store}()

"""
    reset_store!(dir::String=pwd())

Clear the provenance store for `dir`. Deletes the `.provenance/` directory
and removes the cached connection. Call before `book!()` to start fresh.
"""
function reset_store!(dir::String=pwd())
    prov_dir = joinpath(abspath(dir), ".provenance")
    lock(_STOREKIT_LOCK) do
        rm(prov_dir; force=true, recursive=true)
        delete!(_STORE_CACHE, prov_dir)
    end
    nothing
end

"""
    open_store(dir::String) -> Store

Open or create a provenance store at `dir/.provenance/`.

Creates the directory structure and SQLite schema on first call. Subsequent
calls in the same process reuse the cached `Store` for that absolute path.
"""
function open_store(dir::String)
    prov_dir = joinpath(abspath(dir), ".provenance")

    return lock(_STOREKIT_LOCK) do
        # Reuse cached connection to avoid SQLite locking.
        if haskey(_STORE_CACHE, prov_dir)
            return _STORE_CACHE[prov_dir]
        end

        blobs_dir = joinpath(prov_dir, "blobs")
        mkpath(blobs_dir)

        db_path = joinpath(prov_dir, "provenance.db")
        db = SQLite.DB(db_path)
        ensure_schema!(db)

        store = Store(prov_dir, db)
        _STORE_CACHE[prov_dir] = store
        return store
    end
end

"""
    hash_content(x) -> String

Compute a SHA-256 hex digest of a JLD2/HDF5 payload for a Julia object.
"""
function hash_content(x)
    return bytes2hex(SHA.sha256(_jld2_payload_bytes(x)))
end

"""
    hash_file(path::String) -> String

Compute the SHA-256 hex digest of a file's raw contents.
"""
function hash_file(path::String)
    return open(path, "r") do f
        bytes2hex(SHA.sha256(f))
    end
end

"""
    blob_put!(store::Store, data; type::String="result") -> String

Write `data` as a JLD2/HDF5 payload, compute its SHA-256 hash, and store it as a blob.
Returns the hash string. Content-addressed: identical data produces the same
hash and is stored only once.
"""
function blob_put!(store::Store, data; type::String="result")
    bytes = _jld2_payload_bytes(data)

    hash = bytes2hex(SHA.sha256(bytes))
    blob_path = joinpath(store.dir, "blobs", "$(hash).blob")

    lock(_STOREKIT_LOCK) do
        if !isfile(blob_path)
            write(blob_path, bytes)
        end

        insert_blob!(store.db, hash, type, length(bytes))
    end
    return hash
end

"""
    blob_put_file!(store::Store, path::String) -> String

Store the raw contents of the file at `path` as a content-addressed blob and
return its SHA-256 hash. The bytes are written verbatim (no JLD2 envelope), so
the key equals the hash of exactly the stored bytes — the same value
[`hash_file`](@ref) returns for the original file. Read them back with
[`blob_get_file`](@ref).

Both blob writers obey one rule: the key is the SHA-256 of the bytes actually
written to disk. [`blob_put!`](@ref) stores a JLD2-serialized Julia object (key
= hash of the serialized payload); this stores raw file bytes (key = raw file
hash). Keeping the file's raw hash as the key is what lets the same value serve
as the `file_snapshots.content_hash` referenced by `restore` *and* match
re-hashing the live file in `lookup(...; verify=true)`.
"""
function blob_put_file!(store::Store, path::String)
    bytes = read(path)
    hash = bytes2hex(SHA.sha256(bytes))
    blob_path = joinpath(store.dir, "blobs", "$(hash).blob")

    lock(_STOREKIT_LOCK) do
        if !isfile(blob_path)
            write(blob_path, bytes)
        end
        insert_blob!(store.db, hash, "file", length(bytes))
    end
    return hash
end

"""
    blob_get(store::Store, hash::String)

Read a JLD2/HDF5 blob (a serialized Julia object, as written by
[`blob_put!`](@ref)) by its hash. Throws an error if the blob does not exist.
For raw file blobs written by [`blob_put_file!`](@ref), use
[`blob_get_file`](@ref) instead.
"""
function blob_get(store::Store, hash::String)
    blob_path = joinpath(store.dir, "blobs", "$(hash).blob")
    isfile(blob_path) || error("Blob not found: $hash")
    return JLD2.load(blob_path, "payload")
end

"""
    blob_get_file(store::Store, hash::String) -> Vector{UInt8}

Read a raw file blob (as written by [`blob_put_file!`](@ref)) by its hash,
returning its bytes verbatim. Throws an error if the blob does not exist.
"""
function blob_get_file(store::Store, hash::String)
    blob_path = joinpath(store.dir, "blobs", "$(hash).blob")
    isfile(blob_path) || error("Blob not found: $hash")
    return read(blob_path)
end

"""
    blob_exists(store::Store, hash::String) -> Bool

Check whether a blob with the given hash exists in the store.
"""
function blob_exists(store::Store, hash::String)
    blob_path = joinpath(store.dir, "blobs", "$(hash).blob")
    return isfile(blob_path)
end

"""
    blob_verify(store::Store, hash::String) -> Symbol

Check the on-disk integrity of a blob by re-hashing its raw bytes and comparing
to `hash` (the blob's content-addressed key). Returns `:ok` if the bytes still
hash to `hash`, `:corrupt` if they differ (bit-rot / manual edit), or `:missing`
if the blob file is absent.

Operates on the raw bytes only — it never deserializes — so it sidesteps JLD2
non-determinism and works identically for object blobs ([`blob_put!`](@ref)) and
raw-file blobs ([`blob_put_file!`](@ref)).
"""
function blob_verify(store::Store, hash::String)
    blob_path = joinpath(store.dir, "blobs", "$(hash).blob")
    isfile(blob_path) || return :missing
    actual = bytes2hex(SHA.sha256(read(blob_path)))
    return actual == hash ? :ok : :corrupt
end

function _jld2_payload_bytes(data)
    mktemp() do path, io
        close(io)
        JLD2.jldsave(path; payload=data)
        return read(path)
    end
end
