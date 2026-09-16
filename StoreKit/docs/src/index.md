# StoreKit.jl

*Internal infrastructure for BookKit and SimKit* — content-addressed storage, file tracking, and session attribution.

## Overview

StoreKit provides the low-level provenance backbone used by higher-level packages like BookKit and SimKit. It is not intended for direct use by scientists — instead, it powers the `book!`, `lookup`, and `history` workflows exposed by BookKit.

### What StoreKit Does

| Component | Purpose |
|-----------|---------|
| **Content-addressed blob store** | Serialize and deduplicate Julia objects via SHA-256 hashing |
| **SQLite metadata** | Track blob types, annotations, and file snapshots |
| **File I/O tracking** | Automatically log every file opened during a session |
| **Session expression log** | Record REPL expressions with their variable definitions and references |
| **Attribution engine** | Walk the session log to find which files contributed to a result |
| **IR tracing** | Discover source file dependencies from lowered Julia IR |

### Architecture

```
StoreKit/
├── store.jl          # Store type, blob_put!, blob_get, blob_exists
├── db.jl             # SQLite schema, annotations, file snapshots
├── file_tracking.jl  # Base.open method specialization for global I/O logging
├── session.jl        # ast_transforms hook for REPL expression recording
├── attribution.jl    # files_for_result — backward dependency walk
└── tracing.jl        # IR-based source dependency discovery
```

### Storage Layout

When `open_store(dir)` is called, StoreKit creates:

```
dir/
└── .provenance/
    ├── provenance.db    # SQLite database (blobs, annotations, file_snapshots)
    └── blobs/
        ├── <sha256>.blob
        ├── <sha256>.blob
        └── ...
```

Blobs are content-addressed: identical data produces the same hash and is stored only once.
