# Update engine

ConfigKit updates parameters and initial states on ModelingToolkit-backed
`ODEProblem`s. The ordinary [`update`](@ref) API returns an independently usable
problem and internally reuses symbolic lookup plans.

```julia
updated = update(prob, (CL=3.0, V=20.0))
sol = solve(updated)
```

Keys may be symbolic values, symbols, or strings. In strict mode, ConfigKit
rejects unknown keys and direct updates to bound parameters. Update the inputs
of a binding instead so ModelingToolkit can recompute its value.

## Caller-owned cache

Use [`UpdateCache`](@ref) when one fixed key layout is evaluated repeatedly:

```julia
cache = UpdateCache(prob, (:CL, :V))

with_update_cache(cache, (3.0, 20.0)) do updated
    solve(updated)
end
```

An `UpdateCache` owns mutable buffers. A problem returned by [`update!`](@ref)
may borrow those buffers and is valid only until the next update on the same
cache. `with_update_cache` holds the cache's borrow lock while the callback
uses the problem, so it is the safe form when a cache may be shared.

For task-local use, [`thread_update_cache`](@ref) returns a cache for the current
Julia thread and [`with_thread_update_cache`](@ref) combines lookup, locking,
and callback lifetime management.

## Prepared-update metadata

[`prepared_update_source`](@ref) returns a [`PreparedUpdateSource`](@ref) for a
tracked updated problem, or `nothing` for an unrelated problem. This metadata
lets other QSPKit packages compose parameter updates with prepared event solves
without changing `update`'s return type.

The metadata is an optimization hint, not serialized provenance. It is stored
in a bounded process-local cache and is tied to the exact updated problem
object.

## Choosing an API

| Need | API |
| --- | --- |
| Occasional or independently retained updates | `update` |
| Tight single-owner loop | `UpdateCache` + `update!` |
| Shared cache with immediate consumption | `with_update_cache` |
| Per-thread repeated layout | `with_thread_update_cache` |

Always benchmark the complete application workload before choosing the
borrowed-buffer APIs; their main benefit is reducing repeated setup and
allocation, not changing solve semantics.
