module QSPKitMetaGraphsNextExt

using QSPKit
using QSPKit.BookKit
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
    for node in BookKit.nodes(g)
        mg[node.name] = (
            kind = node.kind,
            description = node.description,
            timestamp = node.timestamp,
            content_hash = node.content_hash,
            vcs_ref = node.vcs_ref,
            results = node.results,
        )
    end
    for edge in BookKit.edges(g)
        mg[edge.src, edge.dst] = (
            label = edge.label,
            pulled = edge.pulled,
            via = edge.via,
            source = edge.source,
        )
    end
    return mg
end

end # module QSPKitMetaGraphsNextExt
