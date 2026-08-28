# StoreKit

StoreKit provides the persistence and provenance layer used by BookKit. It
stores deduplicated JLD2 payloads by SHA-256 hash, records annotations in
SQLite, tracks file inputs, and fingerprints Julia source methods.

```julia
using StoreKit

store = open_store("analysis")
hash = blob_put!(store, (estimate=1.2,); type="result")
blob_verify(store, hash)
result = blob_get(store, hash)
```

## Important process-wide behavior

Loading StoreKit installs a `Base.open` specialization for `String` paths so
file reads can be attributed to results. In an interactive REPL it also adds an
AST transform that records expression dependencies. These hooks affect the
whole Julia process; use a dedicated analysis process when that instrumentation
is not appropriate for other loaded applications.

See the [manual](docs/src/index.md) for storage, tracking, and API details.

## Development

```sh
julia --startup-file=no --project=StoreKit/test -e 'using Pkg; Pkg.instantiate(); include("StoreKit/test/runtests.jl")'
julia --startup-file=no --project=StoreKit/docs -e 'using Pkg; Pkg.instantiate(); include("StoreKit/docs/make.jl")'
```
