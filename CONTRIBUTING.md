# Contributing

QSPKit alpha is a 12-package Julia workspace. DiffKit and packages retired to
the source repository's history are outside the alpha scope.

## Local checks

Run a package suite from the repository root with its isolated test project:

```sh
julia --startup-file=no --project=ConfigKit/test -e 'using Pkg; Pkg.instantiate(); include("ConfigKit/test/runtests.jl")'
```

Replace `ConfigKit` with the package being changed. Build its manual with:

```sh
julia --startup-file=no --project=ConfigKit/docs -e 'using Pkg; Pkg.instantiate(); include("ConfigKit/docs/make.jl")'
```

Run `make -C validation validate test-tooling` after changing exports, source
paths, documentation, tests, examples, fixtures, or scorecard tooling. The
validation target includes the release-sanitization scan.

## Evidence expectations

Every supported public entry point needs implementation, documentation, and an
executed test referenced by its package matrix. A deliberate exception must be
explicit in the matrix; absence is not evidence.

Behavioral bugfixes discovered in this alpha must also be applied to the source
QSPKit repository with the same regression test. Record the synchronization in
[BACKPORTS.md](BACKPORTS.md). Alpha-only scope, release, documentation, and
validation changes do not need to be backported.

Do not commit generated manifests, coverage files, documentation builds, or
scorecard result directories.
