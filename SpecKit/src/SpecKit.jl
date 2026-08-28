"""
    SpecKit

*"Spec it"* — yspec data specification for Julia.

Provides dual-backend parsing (native Julia YAML parser + optional R yspec package via CondaR/RCall),
column metadata, namespace switching, decode maps, and lookup file resolution.
"""
module SpecKit

using OrderedCollections: OrderedDict
using YAML

include("types.jl")
include("native_parser.jl")
include("rcall_backend.jl")
include("backend.jl")
include("helpers.jl")

function __init__()
    _check_rcall()
end

# Public API
export ColumnSpec, YspecMetadata
export load_yspec, r_available
export namespace, decodes, lookup_source

end # module
