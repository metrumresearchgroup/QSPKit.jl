# SDLC evidence and scorecards

This directory builds external-result artifacts compatible with
[`mpn.scorecard`](https://metrumresearchgroup.github.io/mpn.scorecard/reference/external_scores.html)
for each retained package and for the QSPKit workspace as a whole. Generating
the evidence requires Julia 1.12; R is optional and is only needed to render the
result with `mpn.scorecard`.

The traceability matrices map every exported package entrypoint to existing
source, documentation, and test files. `generate.jl validate` fails when an
export is missing, a matrix contains an extra or duplicate entrypoint, evidence
is empty, a cited test is not reached from canonical `test/runtests.jl`, or an
evidence path is absent or escapes its package.

Packages with metaprogrammed exports may add a reviewed
`exports-<package>.txt` inventory. Their package suite must compare that file to
the module's runtime export set; this lets the shared linter remain deterministic
without initializing optional external runtimes.

## Generate evidence

From this directory:

```sh
make instantiate
make all
```

Or generate one component card and then rebuild the aggregate:

```sh
make package PKG=ConfigKit
make aggregate
```

Results are written beneath `validation/output/` using the external scorecard
directory and filename convention, for example:

```text
output/ConfigKit_0.1.1/ConfigKit_0.1.1.pkg.json
output/ConfigKit_0.1.1/ConfigKit_0.1.1.check.txt
output/ConfigKit_0.1.1/ConfigKit_0.1.1.coverage.json
output/ConfigKit_0.1.1/ConfigKit_0.1.1.scores.json
output/ConfigKit_0.1.1/ConfigKit_0.1.1.matrix.yaml
output/ConfigKit_0.1.1/ConfigKit_0.1.1.tar.gz
output/ConfigKit_0.1.1/ConfigKit_0.1.1.workspace.tar.gz
output/QSPKit_0.1.0-alpha.1/QSPKit_0.1.0-alpha.1.components.json
```

The standard `.pkg.json`, `.check.txt`, `.coverage.json`, `.scores.json`,
`.metadata.json`, and `.matrix.yaml` artifacts are accompanied by test logs,
documentation build status/transcripts, coverage line counts, package and
whole-workspace source archives, the resolved test dependency manifest,
explanatory comments, and—in the
whole-workspace card—a component breakdown plus resolved workspace manifest.
Package check files embed the captured test stdout and stderr, and the aggregate
check file embeds all 12 component check files for a self-contained appendix.
Documentation check files likewise embed their captured stdout and stderr. The
verifier regenerates these records byte for byte and binds each PASS/FAIL line,
exit code, transcript filename and content, `testing.check`, and documentation
score. It also requires metadata coverage counts to exactly equal the copied
coverage-details artifact; the aggregate check is regenerated from the exact
component checks and statuses.
Captured transcripts replace the workspace root, home-directory paths, and the
configured bug-report URL with fixed placeholders before evidence is written.
Raw subprocess streams are captured outside `validation/output`; only fully
scanned, sanitized copies are atomically published there. The release verifier
applies the same identification policy to every text artifact and requires
exact, non-identifying metadata fields.

## Aggregate rules

The QSPKit card is deliberately fail closed:

- `testing.check` is the minimum package check, so every package must pass.
- Coverage is `sum(covered executable lines) / sum(executable lines)`. Package
  percentages are never averaged.
- Documentation, maintenance, and transparency values are arithmetic means of
  the 12 component metrics, preserving partial readiness instead of silently
  rounding it up.
- Any missing or invalid component forces aggregate coverage to exactly zero.

The generated `.components.json` records every component input and the formulas
used. Documentation credit requires a successful build from the package's docs
environment, not merely the presence of Markdown. Release-note currency
requires the exact package name and version together on one root `CHANGELOG.md`
line. Source-control credit requires a committed Git HEAD. Bug-report URL
credit is zero unless `QSPKIT_BUG_REPORTS_URL` is set. Evidence records only
whether it was configured, not the URL itself, so an accidental internal
endpoint cannot be published in a scorecard artifact.

## Qualification boundary

This tooling performs technical qualification, not publication authorization.
Its hard gates cover package test success, documentation-build success,
traceability and evidence integrity, source/manifests bindings, sanitization,
the 12-plus-1 aggregation, PDF rendering, and PDF privacy. Coverage remains a
prominent package and aggregate risk score, but the alpha has no
owner-approved numeric coverage threshold, so the workflow does not silently
invent one.

A technically passing run does not resolve the repository-wide license grant
or configure the private security-reporting channel identified in
`SECURITY.md`. Both require separate owner sign-off before public publication.
The workflow writes this distinction into its GitHub job summary.

The manual/tag workflow also requires a repository Actions secret named
`QSPKIT_PRIVATE_SANITIZATION_MARKERS`. Configure it as newline-delimited,
case-insensitive literal markers (one marker of at least four characters per
line) for identifiers that must not be published but must not be reconstructed
in this public source tree. A dedicated preflight exposes that secret to
`validation/sanitize.jl` and sets
`QSPKIT_REQUIRE_PRIVATE_SANITIZATION_MARKERS=true`; an absent or empty secret
fails before any package job starts. The same secret is subsequently exposed
only to the Julia processes that scan package evidence, aggregate evidence, and
extracted PDF text/metadata. It is not inherited by package tests,
documentation builds, evidence generation, the R renderer, or Poppler tools.
Public CI still runs the generic structural rules without the private marker
set.

Release commands require a clean Git repository with a committed HEAD. Package
and aggregate cards must record that exact HEAD and use
`git-archive:<HEAD>`; aggregation rejects stale, dirty, or mixed component
cards. Generated `validation/output` content is ignored and never needs to be
committed.

Release package matrices must byte-match `validation/matrix-<package>.yaml` at
the recorded full commit. The aggregate matrix must exactly regenerate from
the current package matrices. Source archives are deterministic
`git -c tar.umask=0002 archive --format=tar <full-commit>` streams compressed
with `gzip -n -9`; verification decompresses each archive and compares its
SHA-256 to the canonical Git tar stream. The expected whole-workspace digest is
cached during a verification process, so all 13 copies are checked against one
canonical value without rebuilding it 13 times.

Resolved manifests are deliberately run-resolved evidence rather than
HEAD-locked source files: source `Manifest.toml` files remain ignored and
untracked. Each copied manifest is bound into metadata by its SHA-256 and by
the Pkg `project_hash` recomputed from the current test or workspace
`Project.toml`.

`make sanitize` scans the exact next-commit candidate set reported by Git:
tracked files plus untracked, nonignored files. It fails closed on oversized,
binary, invalid-text, symbolic-link, or special-file inputs unless a path has an
explicit reviewed non-text allowance. `make privacy` separately scans every
public text evidence artifact before upload; source archives are the only
recognized binary evidence type. Rendered PDFs live in the separate ignored
`validation/cards/` directory and never enter that evidence allowlist.

For local experimentation only, `make package-dev PKG=...`, `make all-dev`, and
`make aggregate-dev` permit explicitly labeled filtered working-tree archives.
Development evidence is not accepted by the release aggregate or verifier.

## Rendered cards

After generation, an R environment with `mpn.scorecard` can render each
external result directory with `render_scorecard()`. Render the aggregate
QSPKit directory the same way as a package directory. The aggregate is a real
external result and does not depend on `render_scorecard_summary()`, which is
not used by this workflow.

The renderer covers all 12 package cards and the QSPKit card:

```sh
make render
```

This target first verifies the release evidence and its privacy, then invokes
`Rscript --vanilla`, and finally extracts and scans every rendered PDF. It
requires `mpn.scorecard` 0.5.4 installed from dereferenced source commit
`116cf0d89b952f6fb92f00c4bef261742e819a75`, Pandoc 3.1.11, XeLaTeX, and
Poppler's `pdftotext` and `pdfinfo`. R and these rendering tools are not
required for Julia evidence generation or validation.

The renderer checks its installed package version and `RemoteSha`, stages only
the seven verified external-result inputs needed for rendering in a temporary
directory, and publishes exactly these 13 files beneath `validation/cards/`:
one `<package>_<version>.scorecard.pdf` per package plus the aggregate
`QSPKit_0.1.0-alpha.1.scorecard.pdf`. It rejects missing, extra, empty,
non-PDF, or unexpectedly named outputs. The second privacy gate uses
`pdftotext` and `pdfinfo` in a temporary directory, requires nonempty UTF-8
visible text plus PDF Info/XMP metadata extraction from every PDF, and applies
the same identifying-material rules used for source and text evidence.
Extracted text and metadata are never uploaded.

The release workflow provisions a pinned renderer environment on Ubuntu 24.04:
R 4.5.1, Pandoc 3.1.11, the TinyTeX 2026.01 monthly bundle, and the immutable
`mpn.scorecard` source commit above. Its CRAN dependency graph is resolved
against Posit Package Manager's frozen 2026-01-16 snapshot; Poppler remains a
distro-managed validation utility and does not generate the PDFs. This pins the
content-producing stack for the alpha while still allowing operating-system
security updates.

## Lint without running package suites

```sh
make validate
make test-tooling
```

CI runs these checks and builds every package manual. Full scorecard generation
is intended for release qualification because it reruns all 12 suites with
coverage.

Before copying a working directory, run `make clean`. It removes ignored
scorecard output and PDFs, coverage sidecars (which contain copies of source
lines), generated manifests, manual build trees, and local CondaPkg state.
Release distribution should still be created from the final committed Git
archive rather than from an arbitrary developer working tree.

The GitHub Actions workflow is the canonical source for publishable evidence.
It uses an ephemeral runner and runner-temporary Conda environment. Local full
qualification of CondaR or ShowKit should use disposable Julia-depot and
`JULIA_CONDAPKG_ENV` locations because CondaR may rebuild RCall against its
managed R installation.

## GitHub Actions technical qualification

`.github/workflows/scorecards.yaml` runs the full workflow on manual dispatch
and version-tag pushes. Twelve parallel jobs generate the package cards from
the same commit, upload their result directories, and a dependent job downloads
them, builds the QSPKit aggregate, and verifies all 13 external results. Only
after package, aggregation, verification, and evidence-privacy gates pass does
that job provision the renderer, generate exactly 13 PDFs, extract and scan
their text, and upload the cards. The machine-readable evidence tree and PDFs
are distinct artifacts. Test or aggregation failures can still upload safe
partial evidence for diagnosis; unsafe evidence or PDFs are never uploaded,
and every failed gate fails the job.
