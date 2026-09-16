# Changelog

All notable changes to StoreKit.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`blob_put_file!(store, path)` / `blob_get_file(store, hash)`**: Store and retrieve a file's raw contents as a content-addressed blob. The bytes are written verbatim (no JLD2 envelope), so the key equals the SHA-256 of exactly the stored bytes — the same value `hash_file` returns — which lets it serve as the `file_snapshots.content_hash` referenced by `restore` *and* match re-hashing the live file in `lookup(...; verify=true)`. Both blob writers now obey one rule: the key is the SHA-256 of the bytes actually written to disk (`blob_put!` stores a JLD2-serialized object; `blob_put_file!` stores raw file bytes). The `blobs.type` column (`"file"` vs `"result"`) records how to interpret a blob, so callers choose `blob_get_file` vs `blob_get` by intent.
- **`_is_attributable_file(filepath)`**: Predicate for data-file attribution — accepts any project-local file that exists and is not a package/stdlib/StoreKit-internal/`.provenance` path. Companion to `_is_user_file`, which stays `.jl`-only for IR source-dependency tracing. Used by `BookKit.book!`.
- **`result_inputs` table**: Records consumption edges between booked results — which upstream result(s) each annotation read to produce its output. Managed via `insert_result_input!()` and `get_result_inputs()`. This lets the store encode a project's dependency DAG (consumed by `BookKit.lineage_graph`).
- **`distinct_annotation_names(db)`**: List the distinct booked result names in a store.
- **`blob_verify(store, hash) -> :ok | :corrupt | :missing`**: Check a blob's on-disk integrity by re-hashing its raw bytes against its content-addressed key. Operates on raw bytes only (never deserializes), so it works for object and raw-file blobs alike and sidesteps JLD2 non-determinism. Used by `BookKit`'s staleness check.
- **`annotation_by_id(db, id)`**: Fetch a specific annotation row by id (same shape as `latest_annotation`), enabling verification of a non-head revision.
- **`truncate_file_reads!(n)`**: Drop `FILE_READS` entries beyond the first `n`, so a caller (e.g. `book!`) can record a mark before its own internal file reads and remove them afterward, preventing self-pollution of attribution.
- **`annotation_metrics` table + `insert_metric!`/`get_metrics`**: Per-annotation advisory metrics (key→value rows, e.g. `"loss"`, `"rmse"`), added via `CREATE TABLE IF NOT EXISTS`. Backs BookKit's open `metrics` dict.
- **`result_fingerprints` table + `insert_result_fingerprint!`/`get_result_fingerprints`**: Per-annotation in-memory dependency fingerprints (key→value rows, e.g. `"params"`/`"model"`/`"solver"`/`"source"`), added to the schema via `CREATE TABLE IF NOT EXISTS` (forward-compatible with existing stores). Consumed by BookKit's diff-at-rebook staleness dimension.
- **`source_fingerprint(fn)` / `combined_fingerprint(fn)`**: Per-method lowered-IR source fingerprinting (the supported Route-2 API for code-change staleness). `source_fingerprint` returns a `Dict` from a stable method id (`Module.name(sig)`) to the SHA-256 of that method's normalized lowered AST, walked transitively across the user/dev code `fn` reaches via `GlobalRef`s; `combined_fingerprint` folds it into one order-independent hash. Hashes at **method** granularity (not whole files), so editing an unrelated function in a shared `helper.jl` does not change a result's fingerprint. Includes dev'd sibling-package source (new `_is_traceable_file` predicate), handles `@generated` methods (whose AST is otherwise un-introspectable) by hashing the generator body, and works on REPL-defined methods. Intra-Julia-version only (validated by BookKit's feasibility canary).

### Fixed
- **File-open tracking now records the open mode and distinguishes reads from writes**: each `FILE_READS` entry gains a `:mode` field, and the new `_is_read_mode(mode)` predicate identifies pure-read opens (`"r"`/`"rb"`/default; write/append and any `+` mode are not reads). `files_for_result` and `_script_mode_attribution` now skip non-read opens, so a file the computation *wrote* (an output) is no longer attributed as a data *input*. Previously the `Base.open` specialization was mode-blind, so written outputs were snapshotted as dependencies and would trigger false-positive staleness in `lookup(...; verify=true)` when regenerated.

## [0.1.0] - 2026-03-31

### Added
- **Content-addressed blob store**: `open_store()`, `blob_put!()`, `blob_get()`, `blob_exists()` for storing and deduplicating JLD2/HDF5 payloads via SHA-256 hashing. Storage layout at `.provenance/blobs/`.
- **`hash_content(x)`**: Stable SHA-256 digest of any serializable Julia object.
- **`hash_file(path)`**: SHA-256 digest of raw file contents.
- **SQLite metadata layer**: Schema with three tables — `blobs` (content registry), `annotations` (named bookings with status, rationale, VCS info, loss), and `file_snapshots` (per-annotation file hashes). All managed via `ensure_schema!()`.
- **Annotation API**: `insert_annotation!()`, `latest_annotation()`, `all_annotations()` for named result tracking. `insert_file_snapshot()` and `get_file_snapshots()` for file provenance.
- **File I/O tracking**: `Base.open` method specialization on `String` that automatically logs every file opened during a session (path + expression ID). Catches CSV.read, YAML.load_file, JLD2.load, include(), and any other file access through Base.open.
- **Session expression log**: AST transform hook (via `Base.active_repl_backend.ast_transforms`) that records each REPL expression's defined and referenced variables using ExpressionExplorer.jl. Enables backward dependency walking.
- **Attribution engine**: `files_for_result(result_var)` walks the session log backward from a result variable to find all files that contributed to it. Dual-mode: interactive (session log) and script (static analysis via Meta.parseall).
- **IR-based source tracing**: `_discover_closure_source_deps(closure)` inspects lowered IR to find all source files a closure depends on, including transitive `include()` chains. Ported from TracKit.
