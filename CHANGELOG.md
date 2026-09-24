# Changelog

## Unreleased

- Added a keyword form of `scan` that needs no pipeline body:
  `scan(prob, :dose => doses; events = p -> ev(cmt=:Depot, amt=p.dose), duration=72.0)`.
  Swept model parameters and states are staged with `with`; other swept values
  are passed only to the `events` function. Remaining keywords go to `simulate`.
- Exported `scan` from the root `QSPKit` module.

## QSPKit 0.1.0 — 2026-09-17

- Introduced QSPKit as one installable and versioned Julia package.
- Organized the retained domain APIs as public `QSPKit.<Component>` submodules.
- Added a curated root export surface for common configuration, dosing, and
  simulation workflows.
- Unified package testing under `Pkg.test("QSPKit")`.
- Retained component-level validation, coverage, documentation, and differential
  execution caching as internal qualification details.
- Published one aggregate QSPKit scorecard and one deterministic source tarball.
