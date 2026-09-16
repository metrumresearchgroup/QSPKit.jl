# Transparent Caching

## How It Works

Every `simulate()` result is automatically cached in a global LRU (64 entries). No user action required.

The cache key is a content hash of **all** solve inputs:
- Problem parameter vector (`prob.p`)
- Staged parameter overrides
- Dosing events
- Duration
- Initial conditions (`u0` from previous phase)
- Solver algorithm and kwargs

## Safety

Content-addressed lookup makes it **impossible** to return wrong results. If any input differs by even one bit, the hash changes and the cache misses. The only failure mode is a cache miss (fresh solve), never a stale result.

## Performance

- Hash computation: microseconds
- Solve: milliseconds to seconds
- Overhead: negligible

**Example:** When fitting 2 IC50 parameters with 17 upstream params frozen, the 5-second baseline solve is cached every iteration. Over 5000 evals, this saves ~7 hours.

## Debug Escape Hatch

```julia
disable_cache!()  # force fresh solves, clear cache
enable_cache!()   # re-enable (default)
```
