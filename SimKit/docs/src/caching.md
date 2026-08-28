# Transparent Caching

## How It Works

Every `simulate()` result is automatically cached in a global LRU (64 entries). No user action required.

The cache key is a content hash of **all** solve inputs:
- Problem parameter vector (`prob.p`)
- Staged parameter overrides
- Dosing events
- Duration
- Effective phase start time (relative or absolute)
- Initial conditions (`u0` from previous phase)
- Solver algorithm and kwargs

## Safety

Before returning a cache hit, SimKit compares snapshots of the solve inputs in
addition to checking the content hash. A hash collision or changed mutable input
therefore causes a fresh solve instead of returning the cached solution.

## Performance

- Hash computation is normally small relative to an ODE solve
- Solve: milliseconds to seconds
- Cache lookup adds input hashing and comparison overhead

## Debug Escape Hatch

```julia
disable_cache!()  # force fresh solves, clear cache
enable_cache!()   # re-enable (default)
```
