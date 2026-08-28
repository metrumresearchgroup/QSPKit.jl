# Decision Files

## Overview

Every call to `book!()` generates a `.decision.md` file in the `.provenance/decisions/` directory. These are human-readable Markdown summaries designed to be checked into version control, providing a reviewable audit trail of modeling decisions.

## File Location

Decision files are written to:

```
<store_dir>/.provenance/decisions/<slug>.md
```

The filename slug is derived from the booking name: lowercased, with
non-alphanumeric characters replaced by underscores. For example,
`book!("Site Bundle", ...)` produces `site_bundle.md`.

Subsequent bookings with the same name **overwrite** the decision file, so it always reflects the latest decision. Use `history()` to see all prior bookings stored in the database.

## File Contents

A decision file includes the following sections:

### Header

```markdown
# Decision: Site Bundle

**Status:** accepted
**Timestamp:** 2025-03-15 14:32:01
```

### Rationale

The `rationale` string provided to `book!()`:

```markdown
## Rationale

All pages rendered and links checked
```

### Fit Quality

If `fit_quality` is provided as a Dict, each key-value pair is listed:

```markdown
## Fit Quality

- **broken_links:** 0
- **render_seconds:** 1.8
```

### Fitted Parameters

If the result object has a `fitted_params` property, they are summarized:

```markdown
## Fitted Parameters

- `font_scale` = 1.05
- `line_width` = 72
```

### Score

If the result has a `loss` property:

```markdown
## Score

- **Loss:** 0.02
```

### Attributed Files

The files that were snapshotted as contributors to this result:

```markdown
## Attributed Files

- `content/guide.md`
- `workflow/build.jl`
```

## Version Control

Decision files are plain Markdown and work well with `git diff`. A typical `.gitignore` should **not** ignore `.provenance/decisions/` --- these files are meant to be committed and reviewed in pull requests.

The blob store itself (`.provenance/blobs/` and `.provenance/store.db`) may be `.gitignore`d depending on your project's needs, but decision files provide the human-readable layer that should always be visible.
