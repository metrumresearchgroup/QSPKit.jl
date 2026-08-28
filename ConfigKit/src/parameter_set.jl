# ParameterSet — bundled parameter names, values, and bounds

"""
    ParameterSet

A container for parameter names, values, and bounds extracted from a keyfile.
Useful for passing parameter vectors to optimization or fitting routines.

# Fields
- `names::Vector{Symbol}` — parameter identifiers
- `values::Vector{Float64}` — current parameter values
- `bounds::NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}}` — lower/upper bounds
"""
struct ParameterSet
    names::Vector{Symbol}
    values::Vector{Float64}
    bounds::NamedTuple{(:lb, :ub), Tuple{Vector{Float64}, Vector{Float64}}}
end

"""
    ParameterSet(keyfile::KeyfileAccessor, params::Vector{Symbol})

Construct a `ParameterSet` by extracting values and bounds for the given
parameter names from a loaded keyfile.

# Example
```julia
kf = load_keyfile("keyfile.yml")
ps = ParameterSet(kf, [:CL, :V1, :ka])
ps.names   # [:CL, :V1, :ka]
ps.values  # [5.0, 50.0, 0.5]
ps.bounds  # (lb = [...], ub = [...])
```
"""
function ParameterSet(keyfile::KeyfileAccessor, params::Vector{Symbol})
    values = get_values(keyfile, params)
    bounds = get_bounds(keyfile, params)
    ParameterSet(params, Float64.(values), bounds)
end

function Base.show(io::IO, ps::ParameterSet)
    print(io, "ParameterSet($(length(ps.names)) params: $(join(ps.names, ", ")))")
end
