"""
    QSPKit

The unified QSPKit package. Common modeling and simulation entry points are
exported from this module. Each domain keeps a broader, independently curated
API under `QSPKit.<Kit>`.
"""
module QSPKit

# Component order follows the internal dependency graph. Components are
# submodules of QSPKit and refer to one another with relative imports.
include(joinpath(@__DIR__, "..", "QSPKitCore", "src", "QSPKitCore.jl"))
include(joinpath(@__DIR__, "..", "ConfigKit", "src", "ConfigKit.jl"))
include(joinpath(@__DIR__, "..", "CondaR", "src", "CondaR.jl"))
include(joinpath(@__DIR__, "..", "StoreKit", "src", "StoreKit.jl"))
include(joinpath(@__DIR__, "..", "QSPKitIO", "src", "QSPKitIO.jl"))
include(joinpath(@__DIR__, "..", "SpecKit", "src", "SpecKit.jl"))
include(joinpath(@__DIR__, "..", "InjecKit", "src", "InjecKit.jl"))
include(joinpath(@__DIR__, "..", "QSPReports", "src", "QSPReports.jl"))
include(joinpath(@__DIR__, "..", "ShowKit", "src", "ShowKit.jl"))
include(joinpath(@__DIR__, "..", "SimKit", "src", "SimKit.jl"))
include(joinpath(@__DIR__, "..", "TargKit", "src", "TargKit.jl"))
include(joinpath(@__DIR__, "..", "BookKit", "src", "BookKit.jl"))

# Integrations between bundled components are always available in the unified
# package. Optional third-party integrations remain package extensions.
include(joinpath(@__DIR__, "..", "BookKit", "ext", "BookKitTargKitExt.jl"))
include(joinpath(@__DIR__, "..", "BookKit", "ext", "BookKitSimKitExt.jl"))

# Root API: intentionally small, cohesive, and collision-resistant.
using .ConfigKit: load_keyfile, ParameterSet, value, get_values, get_bounds,
    populate, populate!
using .InjecKit: ev, IEvent, seq, combine, QD, BID, Q4W, loading_then
using .SimKit: SimContext, Subject, Population, PopulationResult, with, events,
    keep, observe, simulate, simulate_solution, subjects, to_dataframe,
    weeks, days, hours

export load_keyfile, ParameterSet, value, get_values, get_bounds,
    populate, populate!
export ev, IEvent, seq, combine, QD, BID, Q4W, loading_then
export SimContext, Subject, Population, PopulationResult, with, events,
    keep, observe, simulate, simulate_solution, subjects, to_dataframe,
    weeks, days, hours

# These modules are public namespaces but are deliberately not exported into a
# caller by `using QSPKit`. Use `using QSPKit.InjecKit: ...` for their broader
# APIs.
public BookKit, CondaR, ConfigKit, InjecKit, QSPKitCore, QSPKitIO, QSPReports,
    ShowKit, SimKit, SpecKit, StoreKit, TargKit

end # module QSPKit
