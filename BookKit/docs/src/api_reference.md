# API Reference

## Core Functions

```@docs
book!
lookup
history
restore
clear_consumption!
book_extract
staleness
staleness_sweep
is_stale
```

Use `artifact(path)` to mark a filesystem artifact that should be tracked as
an input to a booking.

## Lineage

```@docs
lineage_graph
to_dot
render_lineage
to_metagraph
```

## Types

```@docs
BookedResult
Artifact
StalenessReport
LineageGraph
LineageNode
LineageEdge
```
