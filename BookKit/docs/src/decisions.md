# Decision Files

## Overview

Every call to `book!()` generates a `.decision.md` file in the `.provenance/decisions/` directory. These are human-readable Markdown summaries designed to be checked into version control, providing a reviewable audit trail of modeling decisions.

## File Location

Decision files are written to:

```
<store_dir>/.provenance/decisions/<slug>.md
```

The filename slug is derived from the booking name: lowercased, with non-alphanumeric characters replaced by underscores. For example, `book!("PK_Phase1", ...)` produces `pk_phase1.md`.

Subsequent bookings with the same name **overwrite** the decision file, so it always reflects the latest decision. Use `history()` to see all prior bookings stored in the database.

## File Contents

A decision file includes the following sections:

### Header

```markdown
# Decision: PK_Phase1

**Status:** accepted
**Timestamp:** 2025-03-15 14:32:01
```

### Rationale

The `rationale` string provided to `book!()`:

```markdown
## Rationale

CL estimate stable across bootstraps, GOF acceptable
```

### Fit Quality

If `fit_quality` is provided as a Dict, each key-value pair is listed:

```markdown
## Fit Quality

- **AIC:** 234.5
- **condition_number:** 12.3
```

### Fitted Parameters

If the result object has a `fitted_params` property, they are summarized:

```markdown
## Fitted Parameters

- `CL` = 1.23
- `V1` = 45.6
```

### Score

If the result has a `loss` property:

```markdown
## Score

- **Loss:** 0.0234
```

### Attributed Files

The files that were snapshotted as contributors to this result:

```markdown
## Attributed Files

- `data/pk_data.csv`
- `scripts/fit_pk.jl`
```

## Version Control

Decision files are plain Markdown and work well with `git diff`. A typical `.gitignore` should **not** ignore `.provenance/decisions/` --- these files are meant to be committed and reviewed in pull requests.

The blob store itself (`.provenance/blobs/` and `.provenance/store.db`) may be `.gitignore`d depending on your project's needs, but decision files provide the human-readable layer that should always be visible.
