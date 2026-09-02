# QSPKit alpha

QSPKit is a Julia 1.12 workspace for building and running quantitative systems
pharmacology models with ModelingToolkit and SciML.

This alpha retains every active QSPKit package except DiffKit:

| Package | Role |
| --- | --- |
| [BookKit](BookKit/) | Result provenance, lookup, restoration, staleness, and lineage |
| [CondaR](CondaR/) | Isolated CondaPkg-managed R runtime and RCall bridge |
| [ConfigKit](ConfigKit/) | YAML keyfiles, parameter metadata, model population, and fast problem updates |
| [InjecKit](InjecKit/) | Bolus doses, infusions, parameter events, and event-aware ODE solves |
| [QSPKitCore](QSPKitCore/) | Shared symbolic-compilation synchronization |
| [QSPKitIO](QSPKitIO/) | Versioned native Julia result archives |
| [QSPReports](QSPReports/) | Actions, option provenance, parameter updates, and report tables |
| [ShowKit](ShowKit/) | R-backed plotting, tables, diagnostics, and display integration |
| [SimKit](SimKit/) | Composable single-subject and population simulation pipelines |
| [SpecKit](SpecKit/) | Data-specification parsing and lookup helpers |
| [StoreKit](StoreKit/) | Content-addressed storage, session tracing, and file provenance |
| [TargKit](TargKit/) | Targets, objectives, scoring, and fitting pipelines |

DiffKit is excluded because its v1 correctness boundary is still under active
development. Retired Bayesian, population, sensitivity, solver, and sampler
implementations are not part of this release.

## Status

This is an alpha source workspace. APIs may change before a stable release.
The repository is not itself an importable `QSPKit` package; activate the root
workspace and import the component packages you need.

## Requirements

- Julia 1.12
- Linux or macOS. The alpha's CondaR boundary assumes a Unix R layout; Windows
  is not supported for the complete workspace.
- A C/C++ toolchain supported by the SciML dependencies on your platform
- CondaPkg network access while provisioning the isolated CondaR/ShowKit
  environment; some ShowKit operations invoke separately provisioned R packages
  and external rendering tools

CondaR may repair RCall against the selected CondaPkg R installation. ShowKit
and SpecKit perform read-only R dependency checks and never install or rewrite
R packages during ordinary use. Run the full CondaR/ShowKit test suites with a
disposable Julia depot and `JULIA_CONDAPKG_ENV`; the supplied CI uses a
runner-temporary Conda environment.

Package `compat` entries are supported version ranges, as expected for Julia
libraries; the source tree does not commit consumer lockfiles. Direct Conda
dependencies use reviewed exact versions. Optional pmplots, pmtables, mrggsave,
npde, and yspec integrations remain caller-provisioned and must be
version-controlled by the consuming application when used.

## Getting started

From the repository root:

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()

using ConfigKit, InjecKit, SimKit
using TargKit, BookKit, StoreKit
```

The package manuals contain focused examples:

- [ConfigKit manual](ConfigKit/docs/src/index.md)
- [InjecKit manual](InjecKit/docs/src/index.md)
- [SimKit manual](SimKit/docs/src/index.md)
- [QSPKitCore manual](QSPKitCore/docs/src/index.md)
- Every other retained package has a package-local manual under `docs/src/`.

## Security boundary

ConfigKit keyfiles may contain Julia expression strings that are evaluated when
values and symbolic bindings are resolved. Treat keyfiles as executable input:
only load files from sources you trust. Sandboxing untrusted keyfiles is not part
of this alpha.

## Testing

Each package has an isolated test environment. For example:

```sh
julia --startup-file=no --project=ConfigKit/test -e 'using Pkg; Pkg.instantiate(); include("ConfigKit/test/runtests.jl")'
```

CI runs the corresponding suite for every package in this alpha.

## Licensing

ConfigKit and InjecKit retain their package-specific MIT license files. A
repository-wide license has not yet been assigned to the remaining packages.
Resolve that ownership decision before publishing this workspace publicly.

See [Contributing](CONTRIBUTING.md), [Security](SECURITY.md), and
[Source provenance](PROVENANCE.md) for release and maintenance policy.
