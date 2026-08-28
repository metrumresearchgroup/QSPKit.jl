# Lineage Graphs

A project can organize independent scripts into workflow folders such as
`workflow/collect`, `workflow/build`, and `workflow/publish`. Each script writes
a named, content-addressed artifact and reads the artifacts it builds on by name:

```julia
manifest = latest(
    name="Job10_ContentManifest",
    output_dir=@projectroot("artifacts", "cache"),
)

bundle = cached(
    "Job20_SiteBundle";
    output_dir=@projectroot("artifacts", "cache"),
) do
    build_site(manifest)
end
```

Those `latest(name=…)` ⟶ `cached(…)` pairs **are** the dependency edges: the
result a script pulls feeds the result it produces. `lineage_graph` recovers the
whole DAG from them — no hand-maintained diagram.

## Discovering the graph

```julia
using BookKit

g = lineage_graph("path/to/site-project")
```

```
LineageGraph — unit-level, discovered from …/site-project
  3 nodes, 2 edges
  ○ Job10
  ● Job20  ← Job10
  ○ Job30  ← Job20
```

`●` marks stages whose scripts call `fit` or `tracked_fit`; `○` marks other
producing stages. In this deliberately generic example, the build step fits page
content into a layout template. By default, result names that share an initial
alphabetic-and-number prefix are collapsed into one stage (`Job20_SiteBundle`
and `Job20_BundleIndex` become `Job20`). Pass `granularity=:result` to retain
every booked result separately.

How the graph is reconstructed:

1. **Edges** — the project's scripts are statically scanned for
   `cached`/`book!` producers and `latest`/`lookup` consumers.
2. **Nodes** — each booked result is enriched with metadata read from the
   provenance store: timestamp, content hash, and whether its script performed a
   fit. BookKit recognizes its `.provenance/` store and retains support for an
   older JLD2 cache layout. Other file-cache locations can be supplied with
   `store_dirs`.

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
manifest = lookup("Job10_ContentManifest")
book!("Job20_SiteBundle", :accepted; result=site_bundle)

book!("Job30_PublishedSite", :accepted; result=publish_receipt,
      inputs = ["Job20_SiteBundle" => "site files",
                "Job20_BundleIndex" => "asset index"])

g = lineage_graph(open_store(pwd()))       # build straight from the store
```

## Interop with Graphs.jl

The returned [`LineageGraph`](@ref) already carries all node and edge metadata.
For interoperability with the Graphs.jl ecosystem, load a metagraph backend and
convert:

```julia
using MetaGraphsNext
mg = to_metagraph(g)
```
