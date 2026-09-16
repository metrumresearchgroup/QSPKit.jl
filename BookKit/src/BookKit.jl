module BookKit

using Dates
using SHA
using StoreKit
using LinearAlgebra: BLAS

include("types.jl")
include("vcs.jl")
include("decisions.jl")
include("book.jl")
include("book_extract.jl")
include("lookup.jl")
include("restore.jl")
include("lineage.jl")

export book!, lookup, history, restore, BookedResult, clear_consumption!
export staleness, staleness_sweep, StalenessReport, is_stale
export book_extract, artifact, Artifact
export lineage_graph, LineageGraph, LineageNode, LineageEdge
export to_dot, render_lineage, to_metagraph

end # module BookKit
