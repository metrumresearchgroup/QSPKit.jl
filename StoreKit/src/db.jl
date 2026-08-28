"""
    ensure_schema!(db::SQLite.DB)

Create the StoreKit tables if they don't already exist.
"""
function ensure_schema!(db::SQLite.DB)
    lock(_STOREKIT_LOCK) do
        SQLite.execute(db, """
            CREATE TABLE IF NOT EXISTS blobs (
                hash TEXT PRIMARY KEY,
                type TEXT,
                created_at TEXT,
                size_bytes INTEGER
            )
        """)

        SQLite.execute(db, """
            CREATE TABLE IF NOT EXISTS annotations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT,
                status TEXT,
                timestamp TEXT,
                vcs_ref TEXT,
                vcs_dirty BOOLEAN,
                rationale TEXT,
                fit_quality TEXT,
                params_hash TEXT,
                result_hash TEXT,
                loss REAL
            )
        """)

        SQLite.execute(db, """
            CREATE TABLE IF NOT EXISTS file_snapshots (
                annotation_id INTEGER,
                path TEXT,
                content_hash TEXT,
                file_type TEXT,
                FOREIGN KEY(annotation_id) REFERENCES annotations(id),
                FOREIGN KEY(content_hash) REFERENCES blobs(hash)
            )
        """)

        # Consumption edges: which upstream booked results were read to produce
        # this annotation (captured from lookup() reads or an explicit inputs=).
        # `input_name` is the upstream result name; `input_hash` its result_hash
        # at read time (may be NULL); `label` is an optional human description of
        # what was pulled (e.g. "baseline inputs", "alternative parameters").
        SQLite.execute(db, """
            CREATE TABLE IF NOT EXISTS result_inputs (
                annotation_id INTEGER,
                input_name TEXT,
                input_hash TEXT,
                label TEXT,
                FOREIGN KEY(annotation_id) REFERENCES annotations(id)
            )
        """)

        # In-memory dependency fingerprints: one row per (key, value) for an
        # annotation, e.g. ("params", <hash>), ("model", <hash>), ("source", <hash>).
        # Captured at book! time and compared across revisions (diff-at-rebook), since
        # in-memory deps have nothing on disk to cold-re-hash.
        SQLite.execute(db, """
            CREATE TABLE IF NOT EXISTS result_fingerprints (
                annotation_id INTEGER,
                key TEXT,
                value TEXT,
                FOREIGN KEY(annotation_id) REFERENCES annotations(id)
            )
        """)

        # Open, advisory metrics for an annotation (e.g. loss, rmse, n_met). One
        # row per (key, value); values are string-encoded (metrics are for human
        # review / queries, not staleness comparison).
        SQLite.execute(db, """
            CREATE TABLE IF NOT EXISTS annotation_metrics (
                annotation_id INTEGER,
                key TEXT,
                value TEXT,
                FOREIGN KEY(annotation_id) REFERENCES annotations(id)
            )
        """)
    end

    return nothing
end

"""
    insert_blob!(db::SQLite.DB, hash::String, type::String, size_bytes::Integer)

Insert a blob record into the blobs table. Skips if hash already exists.
"""
function insert_blob!(db::SQLite.DB, hash::String, type::String, size_bytes::Integer)
    lock(_STOREKIT_LOCK) do
        SQLite.execute(db, """
            INSERT OR IGNORE INTO blobs (hash, type, created_at, size_bytes)
            VALUES (?, ?, ?, ?)
        """, (hash, type, string(Dates.now()), size_bytes))
    end
    return nothing
end

"""
    blob_record(db::SQLite.DB, hash::String)

Look up a blob record by hash. Returns a NamedTuple or `nothing`.
"""
function blob_record(db::SQLite.DB, hash::String)
    return lock(_STOREKIT_LOCK) do
        stmt = SQLite.Stmt(db, "SELECT hash, type, created_at, size_bytes FROM blobs WHERE hash = ?")
        result = DBInterface.execute(stmt, (hash,))
        for r in result
            return (hash=r[:hash], type=r[:type], created_at=r[:created_at], size_bytes=r[:size_bytes])
        end
        return nothing
    end
end

"""
    insert_annotation!(db::SQLite.DB; kwargs...)

Insert an annotation record and return its id.
"""
function insert_annotation!(db::SQLite.DB;
    name::String,
    status::String,
    rationale::String="",
    fit_quality::Union{String,Nothing}=nothing,
    params_hash::Union{String,Nothing}=nothing,
    result_hash::Union{String,Nothing}=nothing,
    loss::Union{Real,Nothing}=nothing,
    vcs_ref::Union{String,Nothing}=nothing,
    vcs_dirty::Union{Bool,Nothing}=nothing,
)
    return lock(_STOREKIT_LOCK) do
        SQLite.execute(db, """
            INSERT INTO annotations (name, status, timestamp, vcs_ref, vcs_dirty, rationale, fit_quality, params_hash, result_hash, loss)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (name, status, string(Dates.now()), vcs_ref, vcs_dirty, rationale, fit_quality, params_hash, result_hash, loss))
        # Return the last inserted row id
        return Int(SQLite.last_insert_rowid(db))
    end
end

"""
    insert_file_snapshot!(db::SQLite.DB, annotation_id::Integer, path::String, content_hash::String, file_type::String)

Record a file snapshot associated with an annotation.
"""
function insert_file_snapshot!(db::SQLite.DB, annotation_id::Integer, path::String, content_hash::String, file_type::String)
    lock(_STOREKIT_LOCK) do
        SQLite.execute(db, """
            INSERT INTO file_snapshots (annotation_id, path, content_hash, file_type)
            VALUES (?, ?, ?, ?)
        """, (annotation_id, path, content_hash, file_type))
    end
    return nothing
end

"""
    get_file_snapshots(db::SQLite.DB, annotation_id::Integer)

Return all file snapshots for a given annotation.
"""
function get_file_snapshots(db::SQLite.DB, annotation_id::Integer)
    return lock(_STOREKIT_LOCK) do
        stmt = SQLite.Stmt(db, "SELECT annotation_id, path, content_hash, file_type FROM file_snapshots WHERE annotation_id = ?")
        result = DBInterface.execute(stmt, (annotation_id,))
        return [(path=r[:path], content_hash=r[:content_hash], file_type=r[:file_type]) for r in result]
    end
end

"""
    latest_annotation(db::SQLite.DB, name::String)

Return the most recent annotation for `name`, or `nothing`.
"""
function latest_annotation(db::SQLite.DB, name::String)
    return lock(_STOREKIT_LOCK) do
        stmt = SQLite.Stmt(db, """
            SELECT id, name, status, timestamp, vcs_ref, vcs_dirty, rationale, fit_quality, params_hash, result_hash, loss
            FROM annotations WHERE name = ? ORDER BY id DESC LIMIT 1
        """)
        result = DBInterface.execute(stmt, (name,))
        for r in result
            return (id=r[:id], name=r[:name], status=r[:status], timestamp=r[:timestamp],
                    vcs_ref=r[:vcs_ref], vcs_dirty=r[:vcs_dirty], rationale=r[:rationale],
                    fit_quality=r[:fit_quality], params_hash=r[:params_hash],
                    result_hash=r[:result_hash], loss=r[:loss])
        end
        return nothing
    end
end

"""
    annotation_by_id(db::SQLite.DB, id::Integer)

Return the annotation row with the given `id`, or `nothing`. Same shape as
[`latest_annotation`](@ref). Used to verify a specific (non-head) revision.
"""
function annotation_by_id(db::SQLite.DB, id::Integer)
    return lock(_STOREKIT_LOCK) do
        stmt = SQLite.Stmt(db, """
            SELECT id, name, status, timestamp, vcs_ref, vcs_dirty, rationale, fit_quality, params_hash, result_hash, loss
            FROM annotations WHERE id = ? LIMIT 1
        """)
        result = DBInterface.execute(stmt, (id,))
        for r in result
            return (id=r[:id], name=r[:name], status=r[:status], timestamp=r[:timestamp],
                    vcs_ref=r[:vcs_ref], vcs_dirty=r[:vcs_dirty], rationale=r[:rationale],
                    fit_quality=r[:fit_quality], params_hash=r[:params_hash],
                    result_hash=r[:result_hash], loss=r[:loss])
        end
        return nothing
    end
end

"""
    all_annotations(db::SQLite.DB, name::String)

Return all annotations for `name`, ordered by id descending.
"""
function all_annotations(db::SQLite.DB, name::String)
    return lock(_STOREKIT_LOCK) do
        stmt = SQLite.Stmt(db, """
            SELECT id, name, status, timestamp, vcs_ref, vcs_dirty, rationale, fit_quality, params_hash, result_hash, loss
            FROM annotations WHERE name = ? ORDER BY id DESC
        """)
        result = DBInterface.execute(stmt, (name,))
        return [(id=r[:id], name=r[:name], status=r[:status], timestamp=r[:timestamp],
                 vcs_ref=r[:vcs_ref], vcs_dirty=r[:vcs_dirty], rationale=r[:rationale],
                 fit_quality=r[:fit_quality], params_hash=r[:params_hash],
                 result_hash=r[:result_hash], loss=r[:loss]) for r in result]
    end
end

"""
    distinct_annotation_names(db::SQLite.DB)

Return the set of distinct annotation names in the store (one entry per
booked result name, regardless of how many revisions it has).
"""
function distinct_annotation_names(db::SQLite.DB)
    return lock(_STOREKIT_LOCK) do
        result = DBInterface.execute(db, "SELECT DISTINCT name FROM annotations ORDER BY name")
        return String[r[:name] for r in result]
    end
end

"""
    insert_result_input!(db::SQLite.DB, annotation_id, input_name; input_hash=nothing, label=nothing)

Record that the annotation `annotation_id` consumed the upstream result
`input_name` (a dependency edge). `input_hash` pins the upstream content at
read time; `label` optionally describes what was pulled.
"""
function insert_result_input!(db::SQLite.DB, annotation_id::Integer, input_name::String;
                              input_hash::Union{String,Nothing}=nothing,
                              label::Union{String,Nothing}=nothing)
    lock(_STOREKIT_LOCK) do
        SQLite.execute(db, """
            INSERT INTO result_inputs (annotation_id, input_name, input_hash, label)
            VALUES (?, ?, ?, ?)
        """, (annotation_id, input_name, input_hash, label))
    end
    return nothing
end

"""
    get_result_inputs(db::SQLite.DB, annotation_id::Integer)

Return all recorded consumption edges (upstream inputs) for an annotation.
"""
function get_result_inputs(db::SQLite.DB, annotation_id::Integer)
    return lock(_STOREKIT_LOCK) do
        stmt = SQLite.Stmt(db, "SELECT input_name, input_hash, label FROM result_inputs WHERE annotation_id = ?")
        result = DBInterface.execute(stmt, (annotation_id,))
        return [(input_name=r[:input_name], input_hash=r[:input_hash], label=r[:label]) for r in result]
    end
end

"""
    insert_result_fingerprint!(db::SQLite.DB, annotation_id, key, value)

Record one in-memory dependency fingerprint (e.g. `"params" => <hash>`) for an
annotation.
"""
function insert_result_fingerprint!(db::SQLite.DB, annotation_id::Integer, key::String, value::String)
    lock(_STOREKIT_LOCK) do
        SQLite.execute(db, """
            INSERT INTO result_fingerprints (annotation_id, key, value)
            VALUES (?, ?, ?)
        """, (annotation_id, key, value))
    end
    return nothing
end

"""
    get_result_fingerprints(db::SQLite.DB, annotation_id::Integer)

Return all recorded fingerprint `(key, value)` rows for an annotation.
"""
function get_result_fingerprints(db::SQLite.DB, annotation_id::Integer)
    return lock(_STOREKIT_LOCK) do
        stmt = SQLite.Stmt(db, "SELECT key, value FROM result_fingerprints WHERE annotation_id = ?")
        result = DBInterface.execute(stmt, (annotation_id,))
        return [(key=r[:key], value=r[:value]) for r in result]
    end
end

"""
    insert_metric!(db::SQLite.DB, annotation_id, key, value)

Record one advisory metric (e.g. `"loss" => "0.0042"`) for an annotation.
"""
function insert_metric!(db::SQLite.DB, annotation_id::Integer, key::String, value::String)
    lock(_STOREKIT_LOCK) do
        SQLite.execute(db, """
            INSERT INTO annotation_metrics (annotation_id, key, value)
            VALUES (?, ?, ?)
        """, (annotation_id, key, value))
    end
    return nothing
end

"""
    get_metrics(db::SQLite.DB, annotation_id::Integer)

Return all recorded metric `(key, value)` rows for an annotation.
"""
function get_metrics(db::SQLite.DB, annotation_id::Integer)
    return lock(_STOREKIT_LOCK) do
        stmt = SQLite.Stmt(db, "SELECT key, value FROM annotation_metrics WHERE annotation_id = ?")
        result = DBInterface.execute(stmt, (annotation_id,))
        return [(key=r[:key], value=r[:value]) for r in result]
    end
end
