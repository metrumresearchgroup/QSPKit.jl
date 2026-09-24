# CondaR

CondaR owns the private R runtime and package libraries used by ShowKit.
It reads project dependency policy without invoking pkgr, activating renv, or
reading or modifying their installed libraries or lockfiles.

## Automatic setup

Start Julia with the consuming project active (`julia --project=.`), then use
ShowKit normally. The first R operation resolves and downloads a compatible
native environment, prepares the selected R packages, verifies their namespaces,
sets the project-local RCall preferences, precompiles RCall for that selection
when needed, and loads RCall. Importing ShowKit or
CondaR does not download anything or start R. No CondaR setup call or shell
environment variable is required.

Automated launchers can perform the provisioning phase separately before a
workload starts:

```sh
julia --project=. -e 'using CondaR; CondaR.prepare!()'
```

`prepare!()` writes the machine-local preferences without importing RCall; the
following workload process can therefore load RCall with that selection already
established. It is optional for interactive use.

Once a project environment has been installed and validated, ordinary startup
reuses that completed environment without launching an R validation worker or
scanning all package namespaces. Restarting Julia does not repeat the validation
pass. Validation runs after installation, when publishing a different library,
and on explicit `ShowKit.configure_r!(...)` refreshes.

After updating an existing Julia path checkout, refresh its Julia manifest with
`using Pkg; Pkg.resolve(); Pkg.instantiate()` and restart Julia. R provisioning
then happens automatically on first use.

CondaR discovers the root from the active Julia project's directory using
ProjectRoot's rules, once per session. This is the consuming project, not the
vendored package directory. Changing `pwd()` does not change it. Restart Julia
when switching the active Julia project.

## Project policy and MPN

**Project mode follows `pkgr.yml` when it exists.** CondaR requests ShowKit's seven
roots (`ggplot2`, `pmplots`, `pmtables`, `mrggsave`, `pdftools`, `vpc`, and `npde`)
and their dependencies. For this required graph, it uses the repositories in
`pkgr.yml`, in their declared order, and honors package `Repo` overrides. An MPN
snapshot therefore controls the selected R package versions. Packages that
overlap with the project's R requirements use that same repository policy.
Unrelated entries in pkgr's `Packages` list are not additional CondaR roots.

Repository selection happens **before** binary reuse. The managed runtime brings
current compatible conda-forge binaries for ShowKit's core graph. A binary is
eligible for the private project library only when its version and upstream
source SHA256 match the source selected from the project's repository. CondaR
reads this provenance from the binary's embedded build recipe, verifies the
selected source download (including the repository's MD5 when supplied), and
records the result and any conda-forge patches locally. Missing provenance,
different versions, or different upstream source bytes select a source build.
An explicit `Type: source` or `Env` customization also forces source installation.

Thus MPN still controls R package selection. Conda-forge's newer R packages do
not override an older MPN snapshot. The number of reusable binaries varies with
that snapshot and the available conda solution; CondaR does not search historical
conda builds for every MPN version. All remaining packages use the selected
repository's source and the managed build tools. A repository checksum mismatch
is an error, never a reason to silently substitute another source.

Supported policy:

- `Version: 1`, ordered `Repos`, and global `Suggests`.
- `Customizations.Packages`: `Repo`, `Type: source`, `Suggests`, and `Env`.
- `Customizations.Repos`: `Type: source`, `Suggests`, and `Env`.
- Package options override repository defaults; environment mappings merge.

`Type: binary` refers to system-R repository binaries and is not supported for
the managed runtime; it produces an explicit error. Unknown installation
directives also fail explicitly. `Rpath`, `Library`, `Libpaths`, `Lockfile`,
`Cache`, `Logging`, `Loglevel`, `Threads`, `Update`, and `Strict` govern pkgr's own
execution and are not used by CondaR. CondaR does not modify `pkgr.yml`, `.Rprofile`,
or `renv/`, and does not use `renv.lock` as another version authority.

Changes to repository order/URLs, source options, native requirements, or host
ABI select a separate configuration in a new Julia session. This permits
upgrades, downgrades, and removals. An unchanged project configuration reuses its
recorded native and R resolutions without refreshing indices. Explicit refresh
resolves both again; use immutable repository snapshots for reproducible R
source selection. Without `pkgr.yml`, project mode uses the latest policy below.
Adding `pkgr.yml` is recognized in the next session.

## Select a mode

```julia
using QSPKit.ShowKit
ShowKit.configure_r!(mode=:latest)   # ignore pkgr.yml
ShowKit.configure_r!(mode=:project)  # follow pkgr.yml and refresh; default mode
```

This optional function saves the choice in the consuming project's
`LocalPreferences.toml` (`JuliaLocalPreferences.toml` is also recognized) and
refreshes both native and R package resolutions. It returns paths and
`restart_required`. Identical resolutions reuse the existing environment. If R
has not started, the next R operation uses the prepared environment. If R is already
loaded and its environment differs, restart Julia. Installation never replaces
files in the currently loaded library. A failed attempt leaves the selection
saved for the next retry but never publishes an incomplete library.

A personal preference can also be written directly:

```toml
# LocalPreferences.toml
[CondaR]
mode = "latest"
```

A team default can be committed in `Project.toml`:

```toml
[preferences.CondaR]
mode = "project"
```

Local preferences take precedence. Environment variables do not select the mode.
Files are read before first R use; after R starts, restart Julia or call the
function to prepare the next session. Calling the function again checks upstream
for newer compatible native packages even when `pkgr.yml` has not changed. The
MPN snapshot continues to control R package versions.

## Latest policy

Latest mode ignores `pkgr.yml` completely. It selects ShowKit's required graph
from CRAN (`https://cloud.r-project.org`), with `pmplots`, `pmtables`, and `mrggsave`
from the current upstream `metrumresearchgroup` GitHub branches. Each GitHub
resolution records an exact commit SHA and fetches DESCRIPTION and source from
that commit. Selected packages must support the managed R version.

The same source checks govern binary reuse; a newer CRAN package is installed
from CRAN source when the native solution does not contain its matching binary.
Native and R metadata refresh on first R use in each Julia session and on explicit
`configure_r!` calls. An unchanged resolution reuses its library without repeating
namespace validation unless the refresh was explicitly requested. If an index
cannot be downloaded, an existing complete library may be used after validation,
with a warning that freshness could not be checked. Dependency conflicts,
malformed metadata, checksum mismatches, and build failures remain errors.

## Native requirements and project resolutions

[`Runtime.toml`](Runtime.toml) declares native requirements: compatible R
(`>=4.5,<5`), native libraries, development headers, build tools, and reusable R
binary roots. QSPKit does not ship a frozen collection of binary versions and
does not need a release just to adopt new conda-forge builds.

On first creation or refresh, MicroMamba solves those requirements against
conda-forge using the actual host OS and architecture. CondaR records the complete
solution as exact artifact URLs, versions, builds, and SHA256 checksums in the
project's managed cache. MicroMamba then installs that exact solution. The record
makes an installation identifiable and retryable; it does not permanently pin
all QSPKit users to those versions. An unchanged solution reuses its runtime.
A changed solution creates and validates a separate runtime and private library
before publishing the new project selection. The currently loaded environment
is never upgraded in place.

There is no additional artifact server, maintainer-generated binary catalog, or
requirement to install conda/Python yourself. MicroMamba and upstream conda
artifacts supply the resolver and platform binaries. These cache records are
local project state, not a committed cross-machine lockfile. A fresh machine
resolves its own compatible native environment, even with the same `pkgr.yml`.

Source versions without matching binaries use managed build tools. Before the
first compiled source install, CondaR checks development files and compiles,
links, and loads C, C++, and Fortran probes against managed XML, curl, OpenSSL,
zlib, and expat, plus Poppler on Unix. `libxml2-devel` supplies the headers,
pkg-config metadata, and linker library needed by R's `xml2`. pkg-config searches
the managed prefix instead of host `/usr` or Homebrew metadata. Windows uses
MinGW tools and package `Makevars.win` rules; the generic C++ probe avoids mixing
MinGW with MSVC's Poppler ABI.

macOS source compilation requires Apple's Command Line Tools/SDK. Binary-only
plans skip this check. Package/repository `Env` overrides are applied explicitly
during source installation. Custom repositories or an expanded `Suggests` graph
can require additional native libraries beyond ShowKit's declared requirements;
those requirements must be added to `Runtime.toml`. CondaR does not guess or
install host system tools. TeX remains an external requirement for LaTeX table
rendering.

## Progress and logs

Default output shows native package linking, resolved binary/source counts,
`[package/total]` status, and namespace validation. Binary reuse is labeled
`Using prebuilt ... (source verified against MPN)` (or the selected repository).
Completed packages reused after interruption are labeled `Reusing`. During long
steps, a heartbeat reports elapsed time every 15 seconds without visible output.
Counts are package progress, not estimated time remaining.

Every installer process saves full stdout and stderr at the printed log path.
Native install/check logs are under the cache's `runtimes/logs/`; native solver
and R worker logs are under the configuration's `logs/`. Failures show the last
40 lines, the full log path, and a concise exception retaining the original cause. Native critical/error messages
remain visible; critical micromamba output prevents publication even on exit 0.
CondaR passes micromamba's root prefix to child/post-install scripts internally.

For full live output, use the optional persistent setting:

```julia
ShowKit.configure_r!(mode=:project, verbose=true)
ShowKit.configure_r!(mode=:project, verbose=false)
```

Omitting `verbose` preserves the previous setting. It can also be saved under
`[CondaR]` in local preferences or `[preferences.CondaR]` in `Project.toml`.
Verbosity is excluded from environment identity. These function calls still
refresh both resolutions; changing only the verbosity preference does not.

## Platforms and storage

The running Julia process selects the matching R architecture, including Julia
under emulation:

| Julia platform | Managed target |
|---|---|
| Linux x86_64, glibc | `linux-64` |
| Linux ARM64, glibc | `linux-aarch64` |
| macOS Intel | `osx-64` |
| macOS Apple Silicon | `osx-arm64` |
| Windows x64 | `win-64` |

MicroMamba selects compatible packages using the host's virtual system packages,
including glibc/macOS constraints. An unsupported host or unsatisfiable native
solution fails explicitly. CondaR does not spoof a newer OS to obtain binaries.
Native Windows ARM, 32-bit Julia, musl Linux, and other targets are rejected before
installation. Windows ARM running x86_64 Julia uses `win-64`. Windows has separate
executable/DLL/PATH handling and shorter cache names. Native integration must run
on a target host before treating that target as tested.

Environments live under `DEPOT_PATH[1]/condar/<project-path-hash>/`. Their records
include:

- `<mode>/<configuration>/native.toml`: the most recently resolved native candidate.
- `runtimes/<solution>/condar-native.toml`: the installed runtime's exact artifacts
  and host identity; `condar-binaries.toml` records available binary provenance.
- `<mode>/<configuration>/current.toml`: the published runtime and private library.
- Each library's `condar-plan.rds` and `.tsv`/`.json` companions: selected R
  versions, repositories, source URLs/checksums, and binary/source decisions.

The published pointer changes only after validation succeeds. A failed candidate
may leave logs and an unpublished environment but cannot replace the working
selection. Native solution and R package plan jointly identify each library;
source builds are never copied into a different native runtime. MicroMamba's
download cache is shared; installed runtimes remain project-owned.

PID locks serialize provisioning. Libraries are published only after complete
namespace validation. Interrupted installs resume valid packages within that
unpublished generation. Previous complete generations are retained for running
sessions and switching back; automatic garbage collection is not implemented.

RCall's documented `Rhome`/`libR` preferences are written to the consuming
project's local preferences before import. Julia only applies preferences for a
package whose UUID is named by the active project, so CondaR adds RCall to that
project's `[extras]` once when it is not already declared. QSPKit's ShowKit
qualification environment predeclares this entry and remains unchanged during
provisioning.
CondaR does not rebuild RCall or rewrite its shared `deps.jl`. Load ShowKit
before importing RCall directly.

## Maintainer checks and diagnostics

The [five-target CI workflow](../.github/workflows/condar-environments.yaml) tests
project policy, transactional refresh, source provenance, real installation, and
native source builds. `Runtime.toml` is the only native requirements declaration;
there are no release lock-generation tools to run.

```sh
# From QSPKit; maintainer checks, not required user setup:
julia --project=CondaR/test --startup-file=no -e 'using Pkg; Pkg.instantiate()'
julia --project=CondaR/test --startup-file=no CondaR/test/runtests.jl
julia --project=CondaR/test --startup-file=no CondaR/test/project_integration.jl
julia --project=CondaR/test --startup-file=no CondaR/test/latest_integration.jl
```

The integration check creates a fresh consumer, follows a dated MPN snapshot,
loads RCall, saves a plot, exercises repository policy fixtures, and forces
`xml2`/`pdftools` source builds against the managed SDK. It does not change an
existing project's mode. The latest integration check exercises CRAN/GitHub
selection and explicit refresh with an intentionally invalid, ignored `pkgr.yml`.
`test/integration.jl` exercises the active project's policy; `test/native_builds.jl` is the standalone source-build regression.

After ordinary R initialization:

```julia
R = ShowKit.CondaR
R.reval("R.home()")
R.reval(".libPaths()")
R.reval("packageVersion('mrggsave')")
```

For table rendering, CondaR preserves `pdflatex` on PATH or discovers native
TinyTeX installations. `ensure_tex_path!(; roots=[...])` supports custom locations.
Restart the VS Code Julia REPL after a mode switch that requests it.

References: [pkgr configuration](https://kb.metworx.com/Users/Managing_R_Packages/pkgr-configuration/),
[RCall preferences](https://juliainterop.github.io/RCall.jl/stable/installation/),
[MicroMamba explicit specifications](https://mamba.readthedocs.io/en/stable/user_guide/micromamba.html).
