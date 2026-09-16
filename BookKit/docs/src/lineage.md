# Lineage Graphs

A QSPKit project is organized into **modeling units** — folders like
`mu/01_baseline`, `mu/02_drug_response`, `mu/03_trajectory`, … . Each unit's
run/plot script writes a named, content-addressed result and reads the results
it builds on by name:

```julia
upstream = latest(name="MU2_AsthmaDrugResponse", output_dir=@projectroot("data", "sims"))

result = cached("MU3_AsthmaTrajectory"; output_dir=@projectroot("data", "sims")) do
    # … fit / simulate, using upstream …
end
```

Those `latest(name=…)` ⟶ `cached(…)` pairs **are** the dependency edges: the
result a script pulls feeds the result it produces. `lineage_graph` recovers the
whole DAG from them — no hand-maintained diagram.

## Discovering the graph

```julia
using BookKit

g = lineage_graph("~/Projects/Julia/svn-proj-pfz01501")
```

```
LineageGraph — unit-level, discovered from …/svn-proj-pfz01501
  6 nodes, 6 edges
  ● MU1
  ● MU2  ← MU1
  ● MU3  ← MU2
  ● MU4  ← MU3
  ○ MU5  ← MU3
  ○ MU6  ← MU3, MU4
```

`●` marks units **calibrated on data** (they fit parameters); `○` marks
**prediction-only** units. By default nodes are modeling units (`MU1`, `MU2`,
…); pass `granularity=:result` to keep every booked result (`MU3_AsthmaTrajectory`,
`MU3_Plots`, …) as its own node.

How the graph is reconstructed:

1. **Edges** — the project's scripts are statically scanned for
   `cached`/`book!` producers and `latest`/`lookup` consumers.
2. **Nodes** — each booked result is enriched with metadata read from the
   provenance store: timestamp, content hash, and whether the step fit
   parameters (teal) or was prediction-only (amber). Both a TracKit-style JLD2
   store (`data/sims/*.jld2`) and a BookKit/StoreKit `.provenance/` store are
   recognized.

## Rendering

```julia
print(to_dot(g))                          # Graphviz dot string
render_lineage(g, "doc/lineage.svg")      # render via the `dot` binary
render_lineage(g, "doc/lineage.dot")      # or just write the source
```

## Recording edges in the store

So that a BookKit-native store encodes the DAG on its own, `lookup` records each
upstream result it reads and `book!` persists those reads as dependency edges.
You can also pass them explicitly, optionally labeling what was pulled:

```julia
mu2 = lookup("MU2")                        # recorded as a consumed input
book!("MU3", :accepted; result=fit_result, loss=0.21)   # edge MU2 → MU3

book!("MU6", :accepted; result=prediction,
      inputs = ["MU3" => "frozen platform", "MU4" => "IL-4 / IL-13 IC50s"])

g = lineage_graph(open_store(pwd()))       # build straight from the store
```

## Interop with Graphs.jl

The returned [`LineageGraph`](@ref) already carries all node and edge metadata.
For interoperability with the Graphs.jl ecosystem, load a metagraph backend and
convert:

```julia
using Graphs, MetaGraphsNext
mg = to_metagraph(g)
```
