# Changelog

## QSPKit 0.1.0-alpha.1 — 2026-08-28

Included package versions:

- BookKit 0.1.0
- CondaR 0.1.0
- ConfigKit 0.1.1
- InjecKit 0.1.0
- QSPKitCore 0.1.0
- QSPKitIO 0.1.0
- QSPReports 0.1.0
- ShowKit 0.1.0
- SimKit 0.1.0
- SpecKit 0.1.0
- StoreKit 0.1.0
- TargKit 0.4.0

- Retained every active QSPKit package except the still-developing DiffKit
  correctness boundary; packages already retired to source history remain out.
- Added explicit Julia and dependency compatibility bounds.
- Made every retained package part of CI.
- Removed research plans, editor configuration, generated artifacts, and
  unsupported package surfaces from the distribution.
- Removed SimKit's nonfunctional `observe` builder and reduced QSPKitCore to
  the symbolic-compilation lock actually used by InjecKit.
- Documented the executable-input boundary for ConfigKit keyfiles.
- Added per-package SDLC evidence cards and a fail-closed aggregate QSPKit
  card with line-weighted coverage.
- Added a manual/version-tag technical-qualification workflow that builds 12
  package cards, combines them into the QSPKit card, verifies the full 13-card set, and
  uploads the complete evidence tree plus a distinct set of 13 rendered PDFs
  after fail-closed PDF text extraction and privacy validation.
- Replaced project-specific examples and fixtures with synthetic material,
  removed a private-path integration test, and added a fail-closed release
  sanitization gate plus privacy-safe scorecard metadata and transcripts.
- Fixed SimKit phase-cache keying and ConfigKit keyfile strictness, path-based
  `solve_for` routing, problem-update strictness, and the narrow
  ModelingToolkit/DynamicQuantities diagnostic workaround. Behavioral fixes
  and regression tests were also applied to the source QSPKit checkout.
- Fixed CondaR first-import RCall configuration, ShowKit provenance assertions,
  QSPReports table/variant handling, StoreKit keyword-only file tracking, and
  TargKit's invalid-prediction error boundary; these regression fixes were also
  mirrored to the source checkout.
- Removed ShowKit and SpecKit's runtime dependency-installation side effects;
  optional R integrations now use read-only availability checks, ShowKit never
  rewrites installed namespaces, and direct Conda dependencies are fixed to
  reviewed versions. The source checkout received the same behavioral changes.
