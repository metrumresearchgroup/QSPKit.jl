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
using QSPKit.BookKit

# After fitting a model and inspecting diagnostics...
result = book!("PK_Phase1", :accepted;
    result = fit_result,
    rationale = "CL estimate stable across bootstraps, GOF acceptable",
    fit_quality = Dict("AIC" => 234.5, "condition_number" => 12.3),
)

# In a downstream script or later session...
pk = lookup("PK_Phase1")
pk.fitted_params  # property-forwarded from the stored result

# Check if anything has changed since booking
pk = lookup("PK_Phase1"; verify=true)
# Warning: PK_Phase1 may be stale - 1 file(s) changed: ["data/pk_data.csv"]

# Review the full decision history
history("PK_Phase1")

# Restore file snapshots to inspect what the data looked like at booking time
restore("PK_Phase1"; to="snapshots/pk_v1")
```

When the SimKit extension books a `SimContext` or `PopulationResult`, the stored
payload is a versioned, data-only prediction snapshot. It contains tabular phase
results and simple run metadata, while model, solver, parameter, and dosing
provenance is retained as fingerprints. Executable SciML/ModelingToolkit objects
are deliberately not serialized.

## Key Concepts

- **Booking** --- `book!()` serializes a result to the blob store, snapshots attributed files, records VCS state, and writes a human-readable `.decision.md` file.
- **Lookup** --- `lookup()` retrieves the latest booked result by name, optionally verifying file staleness.
- **History** --- `history()` prints all bookings for a name, ordered newest first.
- **Restore** --- `restore()` extracts the file snapshots from a booking into a directory for inspection or diffing.
- **Decision files** --- Markdown summaries written to `.provenance/decisions/` for human review and version control.
- **Staleness detection** --- `lookup(verify=true)` compares current file hashes against stored snapshots and warns if anything changed.
