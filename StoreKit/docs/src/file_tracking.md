# File Tracking

StoreKit tracks file I/O globally by adding a `String`-specific method to
`Base.open`. This lets BookKit determine which files contributed to an artifact
without requiring callers to declare every input manually.

## How It Works

Julia's functional `Base.open` accepts either a mode string or keyword-only
I/O flags. StoreKit adds more-specific `String` methods for both forms:

```julia
function Base.open(f::Function, path::String, mode::String; kwargs...)
    _record_file_open(path, mode)
    return invoke(Base.open, Tuple{Function, AbstractString, AbstractString},
                  f, path, mode; kwargs...)
end

function Base.open(f::Function, path::String; kwargs...)
    _record_file_open(path, _keyword_open_mode(kwargs))
    return invoke(Base.open, Tuple{Function, AbstractString}, f, path; kwargs...)
end
```

Because `String <: AbstractString`, Julia dispatches to StoreKit's method
first. It logs the absolute path, current expression ID, and effective mode,
then delegates via `invoke`. Keyword-only flags such as `write=true` stay on
the keyword-based path instead of being combined with a mode string.

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

For example, after a documentation build compiles pages and navigation, packages
them with style tokens, and later combines that bundle with a separately built
asset manifest, `files_for_result(:release_package)` walks the session log
backward from the final artifact variable:

1. Start with `needed = {:release_package}`.
2. For each session entry (in reverse), if its `defs` intersect `needed`, add its `refs` to `needed` and mark its `id` as contributing
3. Match contributing expression IDs to file reads

This produces the set of data files that transitively contributed to the result.

## Script Mode Fallback

When no session log is available (script mode), `_script_mode_attribution` parses the calling script with `Meta.parseall`, builds a dependency graph via ExpressionExplorer, and performs the same backward walk. It also includes all `.jl` files from `FILE_READS` (source files loaded via `include()`).
