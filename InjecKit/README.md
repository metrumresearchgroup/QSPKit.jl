# InjecKit

InjecKit adds discrete dosing and parameter events to ModelingToolkit-backed ODE
problems. It supports bolus doses, continuous infusions, repeated regimens,
NONMEM-style event tables, and composable event schedules.

InjecKit is part of the QSPKit alpha workspace and currently requires Julia
1.12. Start with the [manual](docs/src/index.md) or the
[getting-started guide](docs/src/getting_started.md).

```julia
using Pkg
Pkg.activate("path/to/QSPKit")
Pkg.instantiate()
using InjecKit
```
