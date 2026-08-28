# BookKit.jl

*"Book it"* --- Provenance booking and result retrieval for scientific modeling workflows.

## What is BookKit?

BookKit provides a lightweight API for recording modeling results with provenance metadata. When you're happy with a result --- a fitted model, a calibrated parameter set, a simulation output --- call `book!()` to snapshot it along with every file that contributed to it. Later, `lookup()` retrieves the result and can verify whether the underlying files have changed.

BookKit is built on top of StoreKit, which provides the content-addressed blob
store and SQLite annotation database.

## The Kit Family

| Package | Tagline | Purpose |
|---------|---------|---------|
| **ConfigKit** | "Config it" | Parameter management, YAML keyfiles, fast updates |
| **InjecKit** | "Inject it" | Dosing events, event composition |
| **SimKit** | "Simulate it" | Simulation orchestration, pipelines, caching |
| **BookKit** | "Book it" | Result provenance, decision tracking, staleness detection |
| **StoreKit** | "Store it" | Content-addressed blob store, session tracking |

## Quick Example

```julia
using BookKit

# After building a documentation site and checking its links...
bundle = (files=["index.html", "guide.html"], byte_count=2048)
result = book!("site_bundle", :accepted;
    result = bundle,
    rationale = "All pages rendered and links checked",
)

# In a downstream script or later session...
site = lookup("site_bundle")
site.files  # property-forwarded from the stored result

# Check if anything has changed since booking
site = lookup("site_bundle"; verify=true)
# Warning: site_bundle may be stale - 1 file changed: ["content/guide.md"]

# Review the full decision history
history("site_bundle")

# Restore file snapshots to inspect the inputs used at booking time
restore("site_bundle"; to="snapshots/site_bundle_v1")
```

## Key Concepts

- **Booking** --- `book!()` serializes a result to the blob store, snapshots attributed files, records VCS state, and writes a human-readable `.decision.md` file.
- **Lookup** --- `lookup()` retrieves the latest booked result by name, optionally verifying file staleness.
- **History** --- `history()` prints all bookings for a name, ordered newest first.
- **Restore** --- `restore()` extracts the file snapshots from a booking into a directory for inspection or diffing.
- **Decision files** --- Markdown summaries written to `.provenance/decisions/` for human review and version control.
- **Staleness detection** --- `lookup(verify=true)` compares current file hashes against stored snapshots and warns if anything changed.

!!! warning "Process-wide instrumentation"
    BookKit loads StoreKit. StoreKit records `String`-path calls to `Base.open`
    throughout the Julia process and installs an expression transform in an
    interactive REPL. Use a dedicated process when that instrumentation is not
    appropriate for other applications.
