# TargKit Agent Guide

This file is maintained by `tools/generate_agents.jl`.
Edit only the manual section unless you are changing the generator or `tools/agent_overrides.toml`.

<!-- BEGIN GENERATED: agent-context -->
## Package Facts

- Package: `TargKit`
- Path: `TargKit`
- UUID: `a7e3d3f1-8c4b-4e6a-9f2d-1b5c8a0e7d3f`
- Purpose: Calibration target definitions, objective functions, scoring, and fitting helpers.
- Local dependencies: `ConfigKit`, `QSPKitCore`
- Adjacent packages to inspect for shared behavior: `ConfigKit`, `ShowKit`, `SimKit`
- Files: 16 source, 2 test, 15 docs
- README: -
- Docs directory: `TargKit/docs`

## Acceptance

- `JULIA_LOAD_PATH=.:validation:@stdlib julia --project=. --startup-file=no -e 'using QSPKit; include("TargKit/test/runtests.jl")'`
<!-- END GENERATED: agent-context -->

<!-- BEGIN MANUAL: agent-guidance -->
## Package Rules

- TargKit owns targets, objective functions, scoring, and calibration helpers.
- Public objective, fit, and pipeline entry points should agree on evaluation logging defaults.
- Keep progress output opt-in for package APIs unless the caller explicitly requests it.
<!-- END MANUAL: agent-guidance -->
