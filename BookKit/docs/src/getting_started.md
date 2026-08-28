# Getting Started

## Installation

BookKit is part of the QSPKit monorepo. Add it and its dependency StoreKit via:

```julia
using Pkg
Pkg.develop(path="path/to/QSPKit/StoreKit")
Pkg.develop(path="path/to/QSPKit/BookKit")
```

## Basic Workflow

### 1. Book a result

When you have a result you're satisfied with, call `book!()` to record it:

```julia
using BookKit

bundle_result = (files=["index.html", "guide.html"], byte_count=2048)
result = book!("site_bundle", :accepted;
    result = bundle_result,
    rationale = "All pages rendered and links checked",
)
```

The `status` argument is a Symbol --- use `:accepted` or `:rejected`. Any other status throws an error.

### 2. Retrieve a result

In a later session or a downstream script, retrieve the booked result:

```julia
site = lookup("site_bundle")
site.data         # the original result object
site.status       # :accepted
site.rationale    # "All pages rendered and links checked"
```

`BookedResult` forwards property access to the stored data, so fields on a named
tuple or struct remain convenient to access:

```julia
site.files  # delegates to bundle_result.files
```

### 3. Verify staleness

Pass `verify=true` to check whether any files that contributed to the result have been modified:

```julia
site = lookup("site_bundle"; verify=true)
```

If files have changed, you'll see a warning:

```
Warning: site_bundle may be stale - 2 file(s) changed: ["content/guide.md", "workflow/build.jl"]
```

### 4. Review history

See all bookings for a given name:

```julia
history("site_bundle")
```

```
History for 'site_bundle' (3 entries):
------------------------------------------------------------
  #5  [accepted]  2026-01-03 14:32:01  vcs=<revision>
        Navigation and cross-links verified
  #3  [rejected]  2026-01-02 10:15:22  vcs=<revision>
        Broken links remain in the reference pages
  #1  [accepted]  2026-01-01 09:00:05  vcs=<revision>
        Initial preview approved
------------------------------------------------------------
```

### 5. Restore file snapshots

Extract the files that were snapshotted at booking time:

```julia
files = restore("site_bundle"; to="snapshots/site_bundle_v3")
```

This writes each attributed file to its original relative path under the target directory. You can then diff against your current files to see what changed.

## Typical Project Workflow

```julia
using BookKit

# Collect the source pages.
manifest = (pages=["index.md", "guide.md"], count=2)
book!("content_manifest", :accepted;
    result = manifest,
    rationale = "Required pages are present",
)

# Build a site from the approved manifest. The lookup is automatically recorded
# as a dependency of the next booking.
approved_manifest = lookup("content_manifest"; verify=true)
bundle = build_site(approved_manifest.pages)

book!("site_bundle", :accepted;
    result = bundle,
    rationale = "Pages rendered and links checked",
)

# Later, add a page and book a new manifest revision.
updated_manifest = (pages=["index.md", "guide.md", "faq.md"], count=3)
book!("content_manifest", :accepted;
    result = updated_manifest,
    rationale = "FAQ added to the publication set",
)
# The previous booking is still in history() — this one is now the latest
```
