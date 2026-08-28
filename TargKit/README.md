# TargKit

TargKit defines calibration targets, scores simulation results, builds
optimization objectives, and runs staged parameter fitting. Targets are plain
DataFrames or `TargetSet` wrappers, so the package remains independent of any
particular model or simulation engine.

```julia
using TargKit

observed = targets(response=(2.0, 1.5, 2.5))
predict = (simulation, row) -> simulation[row.name]

report = score(observed => predict; ctx=Dict(:response => 2.1))
report.total_loss
```

`objective` and `fit` accept a caller-provided simulation function. `setup`,
curried `fit` steps, and `finish` provide the same work as a composable fitting
pipeline. ConfigKit integration can supply parameter values and bounds, while
QSPKitCore serializes symbolic compilation.

Scoring rejects non-finite or otherwise invalid target values and unresolved
prediction mappings with contextual errors. Optimization penalties are used
only when `simulate` explicitly returns `nothing`, or when `bounds_penalty` is
enabled.

See the [manual](docs/src/index.md) for the supported DataFrame schema,
objective construction, fitting, and exported API.

## Development

```sh
julia --startup-file=no --project=TargKit/test -e 'using Pkg; Pkg.instantiate(); include("TargKit/test/runtests.jl")'
julia --startup-file=no --project=TargKit/docs -e 'using Pkg; Pkg.instantiate(); include("TargKit/docs/make.jl")'
```
