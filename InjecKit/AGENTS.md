# InjecKit Agent Guide

This file is maintained by `tools/generate_agents.jl`.
Edit only the manual section unless you are changing the generator or `tools/agent_overrides.toml`.

<!-- BEGIN GENERATED: agent-context -->
## Package Facts

- Package: `InjecKit`
- Path: `InjecKit`
- UUID: `c459914d-a012-4e13-bbe3-220b8bf26547`
- Purpose: Dosing events, infusions, event composition, and event-aware solve paths.
- Local dependencies: `ConfigKit`, `QSPKitCore`
- Adjacent packages to inspect for shared behavior: `BayesKit`, `ConfigKit`, `SensKit`, `SimKit`
- Files: 13 source, 17 test, 9 docs
- README: `InjecKit/README.md`
- Docs directory: `InjecKit/docs`

## Acceptance

- `JULIA_LOAD_PATH=.:validation:@stdlib julia --project=. --startup-file=no -e 'using QSPKit; include("InjecKit/test/runtests.jl")'`
<!-- END GENERATED: agent-context -->

<!-- BEGIN MANUAL: agent-guidance -->
## Package Rules

- InjecKit owns event construction, dosing schedules, infusions, and event-aware solve integration.
- Preserve ConfigKit prepared-update breadcrumbs when changing event execution paths.
- Prefer package-level event abstractions over hand-coded callback logic in downstream scripts.
<!-- END MANUAL: agent-guidance -->
