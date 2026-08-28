module BookKitMetaGraphsNextExt

# Optional conversion of a `LineageGraph` into a `MetaGraphsNext.MetaGraph`,
# carrying node and edge metadata as vertex/edge data. Loaded automatically when
# the user has both `Graphs` and `MetaGraphsNext` available.

using BookKit
using Graphs: DiGraph
using MetaGraphsNext: MetaGraph

function BookKit.to_metagraph(g::BookKit.LineageGraph)
    mg = MetaGraph(
        DiGraph();
        label_type = String,
        vertex_data_type = NamedTuple,
        edge_data_type = NamedTuple,
        graph_data = (project = g.project, granularity = g.granularity),
    )
    for n in BookKit.nodes(g)
        mg[n.name] = (
            kind = n.kind,
            description = n.description,
            timestamp = n.timestamp,
            content_hash = n.content_hash,
            vcs_ref = n.vcs_ref,
            results = n.results,
        )
    end
    for e in BookKit.edges(g)
        # Endpoints are guaranteed to be present as vertices.
        mg[e.src, e.dst] = (
            label = e.label,
            pulled = e.pulled,
            via = e.via,
            source = e.source,
        )
    end
    return mg
end

end # module
