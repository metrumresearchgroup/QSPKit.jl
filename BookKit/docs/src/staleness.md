# Staleness Detection

## Overview

When you call `lookup("name"; verify=true)`, BookKit checks whether the files that contributed to the booked result have changed since booking time. If any file has been modified or deleted, a warning is emitted.

This is the core safety mechanism: it tells you when a previously-accepted result may no longer be valid because its inputs have drifted.

## How It Works

### At booking time (`book!()`)

1. BookKit identifies **attributed files** --- the files that contributed to the result. In interactive mode (StoreKit session logging active), attribution is determined by tracing which files were read during the computation. In script mode, all files recorded in `StoreKit.FILE_READS` are used as a best-effort attribution.

2. Each attributed file is read, content-hashed (SHA-256), and stored as a **file snapshot** in the blob store. The hash and relative path are recorded in the SQLite database alongside the annotation.

### At lookup time (`lookup(verify=true)`)

1. BookKit retrieves the file snapshots for the latest annotation matching the given name.

2. For each snapshot, it resolves the relative path back to an absolute path, reads the current file, and computes its hash.

3. If the current hash differs from the stored hash --- or if the file has been deleted --- the file is flagged as changed.

4. If any files are flagged, a `@warn` is emitted:

```
Warning: site_bundle may be stale - 2 file(s) changed: ["content/guide.md", "workflow/build.jl"]
```

## What Gets Tracked

File attribution depends on how BookKit discovers which files contributed to a result:

| Mode | How files are discovered | Typical use |
|------|-------------------------|-------------|
| **Interactive** (session log active) | StoreKit's session log traces variable definitions and file reads, then `files_for_result()` walks the dependency graph backward from the result variable | VSCode shift+enter workflow |
| **Script** (no session log) | All entries in `StoreKit.FILE_READS` are attributed | Running `.jl` scripts end-to-end |

Common file types that get tracked:

- **Data files** --- CSVs, XLSX, JLD2 files read during the workflow
- **Keyfiles** --- YAML parameter files loaded via ConfigKit
- **Source files** --- Julia scripts that were `include()`d

## Limitations

- Staleness detection only checks files that were **attributed at booking time**. If a new dependency is added after booking, it won't be tracked until the next `book!()` call.
- File snapshots store content hashes, not the files themselves (those are in the blob store). Use `restore()` to extract the actual file contents.
- VCS state (git commit, dirty flag) is recorded but not used for staleness checks --- it's metadata for human review.

## Best Practices

- Always use `verify=true` when consuming a booked result in downstream work. This catches silent data drift early.
- If staleness is detected, review what changed (use `restore()` to get the original files and diff), then either re-run the analysis and `book!()` again, or confirm the change is benign.
- Keep data files under version control or in a stable location to minimize spurious staleness warnings from file moves.
