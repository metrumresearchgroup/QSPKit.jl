# Release sanitization

The alpha snapshot is reviewed as a standalone publication boundary. Source,
tests, documentation, examples, fixtures, package metadata, workflows, and SDLC
evidence tooling are checked for customer or project identifiers, named
interventions, bespoke model terminology, personal filesystem paths, email
addresses, unreviewed network locations, and organization-like names.

The review removed an environment-dependent test against a private local
project and replaced its domain-specific lineage fixture with a synthetic DAG.
Related model-specific labels in other examples and fixtures were generalized,
unused duplicate fixtures were omitted, non-legal package-metadata email
addresses were removed, and scorecard transcripts and metadata were hardened
against local account, filesystem, machine, endpoint, and source-repository
disclosure. Original legal notices are preserved as identified below.

Run the reproducible gate from the repository root:

```sh
julia --startup-file=no --project=validation validation/sanitize.jl
```

The gate covers the release-eligible working tree and is also part of validation
CI. Generated manifests, coverage sidecars, documentation builds, local package
manager state, and scorecard output are excluded from the source commit because
they are removed before publication and regenerated in an ephemeral release
runner. Machine-readable scorecard evidence receives a separate pre-upload text
privacy scan. Rendered scorecard PDFs are kept outside the binary evidence
allowlist; CI extracts every PDF's visible text and PDF Info/XMP metadata to a
temporary directory, scans both with the same policy, and uploads only the 13
expected PDFs after that gate passes.

Sensitive literal markers are not reconstructed in this public tree. The
manual/tag workflow requires them through the newline-delimited
`QSPKIT_PRIVATE_SANITIZATION_MARKERS` Actions secret and fails closed before
package jobs when the secret is absent. It reuses the marker set only in the
Julia privacy gates for generated evidence and extracted PDF text/metadata;
tests, documentation builds, evidence generation, R, and Poppler do not inherit
it. Local and ordinary public CI scans still enforce all generic structural
rules; maintainers performing publication qualification must supply the private
marker set as documented in `validation/README.md`.

The following references are intentional and reviewed:

- package and commit authorship by Tim Knab;
- the original MIT copyright notices in ConfigKit and InjecKit;
- public upstream package, documentation, and source locations needed by
  ShowKit, SpecKit, ConfigKit, and the SDLC renderer;

Coordinates for the private pre-alpha source snapshot are not part of the
publication boundary. The public upstream SDLC renderer's immutable source
commit is intentionally recorded so the rendering tool can be reproduced.
Scorecard evidence also records the history-free alpha commit that it evaluates;
that public release coordinate is intentional and is not a link to the source
checkout.

No customer model or dataset is part of the alpha. Any new URL, email address,
or private home path fails the generic automated gate. The required private
publication scan additionally rejects known project-specific markers; either
kind of finding requires explicit review before release.
