# StoreKit.jl

*Internal infrastructure for BookKit* — content-addressed storage, file tracking, and session attribution.

## Overview

StoreKit provides the low-level provenance backbone used by BookKit. Most users
should use BookKit's `book!`, `lookup`, and `history` workflows directly.

!!! warning "Process-wide instrumentation"
    Loading StoreKit adds a `Base.open` specialization for `String` paths. In
    an interactive REPL it also installs an AST transform. These hooks are
    process-wide and are used to attribute file and expression dependencies.

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
