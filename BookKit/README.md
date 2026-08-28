# BookKit

BookKit records scientific results, decisions, provenance, and staleness
evidence. A booking stores the result through StoreKit, snapshots attributed
inputs, records source and version-control fingerprints, and writes a readable
decision record.

```julia
using BookKit

book!("baseline-fit", :accepted;
    result=(CL=4.8, V=52.0),
    rationale="Diagnostics and parameter estimates accepted",
    metrics=Dict("loss" => 0.013),
)

saved = lookup("baseline-fit"; verify=true)
report = staleness("baseline-fit")
```

Optional extensions know how to extract provenance from TargKit `FitResult`
objects and SimKit `SimContext` objects. Lineage export to MetaGraphsNext is
also optional.

BookKit loads StoreKit, whose file and interactive-expression instrumentation
is process-wide. See the [StoreKit tracking documentation](../StoreKit/docs/src/file_tracking.md)
before embedding BookKit in a long-lived Julia process.

See the [manual](docs/src/index.md) for booking, lookup, restoration, lineage,
and staleness workflows.

## Development

```sh
julia --startup-file=no --project=BookKit/test -e 'using Pkg; Pkg.instantiate(); include("BookKit/test/runtests.jl")'
julia --startup-file=no --project=BookKit/docs -e 'using Pkg; Pkg.instantiate(); include("BookKit/docs/make.jl")'
```
