# Accessors.jl Integration for ConfigKit
# Provides composable lenses for MTK parameter access via Accessors.jl.

using Accessors
using SymbolicIndexingInterface: getp

# ------------------------------------------------------------------
# MTKParamLens — a lens wrapping ConfigKit.update
# ------------------------------------------------------------------

"""
    MTKParamLens

An Accessors.jl-compatible lens for ModelingToolkit parameters.

Wraps `ConfigKit.update` so that `set(prob, lens, val)` returns a new
`ODEProblem` with the parameter updated.

# Example
```julia
lens = @param(CL)
prob2 = set(prob, lens, 0.5)       # returns updated ODEProblem
val  = get(prob, lens)             # reads current value
prob3 = modify(v -> v*2, prob, lens)  # double CL
```
"""
struct MTKParamLens
    key::Any
end

# Callable interface: lens(prob) returns the parameter value.
# Required by Accessors.jl's SetBased modify path.
(l::MTKParamLens)(prob::SciMLBase.ODEProblem) = getp(prob, l.key)(prob)

function Accessors.set(prob::SciMLBase.ODEProblem, l::MTKParamLens, val)
    return update(prob, [l.key => val])
end

# ------------------------------------------------------------------
# @param macro — convenience for creating MTKParamLens
# ------------------------------------------------------------------

"""
    @param(key)

Create an `MTKParamLens` for the given parameter name (as a Symbol).

# Example
```julia
lens = @param(CL)
prob2 = set(prob, lens, 0.5)
```
"""
macro param(key)
    :(MTKParamLens($(QuoteNode(key))))
end

# ------------------------------------------------------------------
# bounds_from — extract bounds from a KeyfileAccessor
# ------------------------------------------------------------------

"""
    bounds_from(kf::KeyfileAccessor, param::Symbol) -> Tuple{Float64, Float64}

Extract the (lower, upper) bounds for a single parameter from a keyfile.

# Example
```julia
kf = load_keyfile("keyfile.yml")
lb, ub = bounds_from(kf, :CL)
```
"""
function bounds_from(kf::KeyfileAccessor, param::Symbol)
    entry = kf.Parameters[param]
    if !haskey(entry.metadata, :bounds)
        error("Parameter :$param has no bounds defined in keyfile")
    end
    bounds = entry.metadata[:bounds]
    return (Float64(bounds[1]), Float64(bounds[2]))
end
