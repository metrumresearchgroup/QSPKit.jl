# ConfigKit

ConfigKit manages QSP model parameters in YAML keyfiles. It provides parameter
metadata and variants, populates ModelingToolkit systems, and updates SciML
problems while preserving symbolic dependencies and initial conditions.

ConfigKit is part of the QSPKit alpha workspace and currently requires Julia
1.12. See the [manual](docs/src/index.md) and [keyfile reference](docs/src/keyfile_format.md)
for examples and supported fields.

To use the local package from a cloned workspace:

```julia
using Pkg
Pkg.activate("path/to/QSPKit")
Pkg.instantiate()
using ConfigKit
```

Keyfile expressions are evaluated as Julia code. Only load keyfiles from
trusted sources.
