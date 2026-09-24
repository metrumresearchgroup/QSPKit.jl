# QSPKit

QSPKit is one Julia package for quantitative systems pharmacology workflows
built on ModelingToolkit and SciML. Its domain APIs are organized as public
submodules; they are not independently versioned packages.

## Install

QSPKit requires Julia 1.13 or later. Install the validated `v0.1.0` release
directly from the public repository:

```julia
using Pkg
Pkg.add(url="https://github.com/metrumresearchgroup/QSPKit.jl.git", rev="v0.1.0") # For release 0.1.0
# Pkg.add(url="https://github.com/metrumresearchgroup/QSPKit.jl.git#main") # For main 
```


## Use

`using QSPKit` exports the common configuration, dosing, and simulation API:

```julia
using QSPKit

dose = ev(time=0.0, cmt=:Central, amt=100.0)
```

Use a submodule when you need its broader API without adding all of its names
to the caller's namespace:

```julia
using QSPKit.InjecKit: ev, combine
using QSPKit.TargKit: fit
using QSPKit.ShowKit: ggplot, aes, geom_point
```

Available public submodules are `BookKit`, `CondaR`, `ConfigKit`, `InjecKit`,
`QSPKitCore`, `QSPKitIO`, `QSPReports`, `ShowKit`, `SimKit`, `SpecKit`,
`StoreKit`, and `TargKit`. Their manuals remain in the corresponding source
directories under `docs/src/`.

## Test

From a checkout:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test("QSPKit")'
```

That one command runs the root API checks and every bundled submodule's test
suite.


## License

QSPKit is covered by the
[Metrum Research Group Free License, Version 1.0](LICENSE.md). See the license
text for the controlling terms and licensing contact information.
