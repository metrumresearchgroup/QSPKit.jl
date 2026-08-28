# restore() — recreate attributed files from stored blobs

"""
    restore(name; to::String, store_dir=_default_store_dir())

Restore the file snapshots associated with the latest booking of `name`
to the directory `to`.

Each file is written to its original relative path under `to`.
"""
function restore(name::String; to::String, store_dir::String=_default_store_dir())
    store = open_store(store_dir)
    row = StoreKit.latest_annotation(store.db, name)
    isnothing(row) && throw(KeyError("No booked result found for '$name'"))

    snapshots = StoreKit.get_file_snapshots(store.db, row.id)
    if isempty(snapshots)
        @warn "No file snapshots found for '$name'"
        return nothing
    end

    mkpath(to)
    restored = String[]
    for snap in snapshots
        # A snapshot path can be absolute (e.g. an artifact outside the store root).
        # joinpath(to, abs) would discard `to` and overwrite the ORIGINAL file, so
        # relocate absolute paths under `to` by stripping the leading separator.
        relpath = isabspath(snap.path) ? lstrip(snap.path, ('/', '\\')) : snap.path
        dest = joinpath(to, relpath)
        mkpath(dirname(dest))
        content = blob_get_file(store, snap.content_hash)
        write(dest, content)
        push!(restored, relpath)
    end

    return restored
end
