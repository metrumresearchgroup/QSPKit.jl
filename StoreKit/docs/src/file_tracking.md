# File Tracking

StoreKit tracks file I/O globally by adding a `String`-specific method to `Base.open`. This is the mechanism that lets BookKit know which data files contributed to a result — without requiring scientists to declare their inputs.

## How It Works

Julia's `Base.open(f, path, mode)` dispatches on `AbstractString`. StoreKit adds a more specific method for `String`:

```julia
function Base.open(f::Function, path::String, mode::String="r"; kwargs...)
    push!(FILE_READS, (path=abspath(path), expr_id=_CURRENT_EXPR_ID[]))
    return invoke(Base.open, Tuple{Function, AbstractString, AbstractString},
                  f, path, mode; kwargs...)
end
```

Because `String <: AbstractString`, Julia dispatches to StoreKit's method first. It logs the absolute path and the current expression ID, then delegates to the original `AbstractString` method via `invoke`.

## What It Catches

This catches **all** file opens that go through `Base.open`, including:

- `CSV.read("data.csv", DataFrame)`
- `YAML.load_file("params.yml")`
- `JLD2.load("results.jld2")`
- `read("file.txt", String)`
- `include("script.jl")`
- Any library that ultimately calls `open(f, path, mode)`

## Expression Tagging

Each file read is tagged with the expression ID (`expr_id`) that was active when the file was opened. In interactive mode (REPL / VSCode), the `ast_transforms` hook in `session.jl` sets `_CURRENT_EXPR_ID` before each expression evaluates, so file reads can be attributed to specific expressions.

In script mode, `expr_id` is `0` for all reads, and attribution falls back to static analysis.

## The Session Expression Log

In interactive mode, StoreKit registers an `ast_transforms` hook that records every evaluated expression:

```julia
struct SessionEntry
    id::Int              # unique expression ID
    defs::Set{Symbol}    # variables assigned by this expression
    refs::Set{Symbol}    # variables read by this expression
end
```

The hook uses `ExpressionExplorer.jl` to extract definitions and references from each expression's AST before it evaluates.

## Attribution

`files_for_result(:my_variable)` walks the session log backward from the result variable:

1. Start with `needed = {:my_variable}`
2. For each session entry (in reverse), if its `defs` intersect `needed`, add its `refs` to `needed` and mark its `id` as contributing
3. Match contributing expression IDs to file reads

This produces the set of data files that transitively contributed to the result.

## Script Mode Fallback

When no session log is available (script mode), `_script_mode_attribution` parses the calling script with `Meta.parseall`, builds a dependency graph via ExpressionExplorer, and performs the same backward walk. It also includes all `.jl` files from `FILE_READS` (source files loaded via `include()`).
