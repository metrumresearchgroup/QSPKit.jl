# SimKit

SimKit provides composable simulation pipelines on top of ConfigKit and
InjecKit. Pipelines can stage parameter changes and events, chain simulation
phases, branch into treatment arms, scan parameter grids, and simulate
NONMEM-style subject populations.

SimKit is part of the QSPKit alpha workspace and currently requires Julia 1.12.
See the [manual](docs/src/index.md) and [getting-started guide](docs/src/getting_started.md).

```julia
using Pkg
Pkg.activate("path/to/QSPKit")
Pkg.instantiate()
using SimKit
```
