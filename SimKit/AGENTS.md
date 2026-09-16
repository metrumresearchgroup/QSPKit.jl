# SimKit Agent Guide

This file is maintained by `tools/generate_agents.jl`.
Edit only the manual section unless you are changing the generator or `tools/agent_overrides.toml`.

<!-- BEGIN GENERATED: agent-context -->
## Package Facts

- Package: `SimKit`
- Path: `SimKit`
- UUID: `116085dc-8549-443f-9770-efb2c1db145b`
- Purpose: Composable simulation pipelines over configured problems, dosing, subjects, and target workflows.
- Local dependencies: `ConfigKit`, `InjecKit`
- Adjacent packages to inspect for shared behavior: `BayesKit`, `ConfigKit`, `InjecKit`, `PopCore`, `PopKit`, `TargKit`
- Files: 11 source, 1 test, 9 docs
- README: `SimKit/README.md`
- Docs directory: `SimKit/docs`

## Acceptance

- `julia --project=SimKit/test --startup-file=no -e 'include("SimKit/test/runtests.jl")'`
<!-- END GENERATED: agent-context -->

<!-- BEGIN MANUAL: agent-guidance -->
## Package Rules

- SimKit owns the pipeline surface: `SimContext`, `with`, `dose`, `simulate`, `subjects`, and scans.
- Prefer pipeline verbs over direct low-level `remake` or callback construction in user workflows.
- Keep behavior aligned with ConfigKit updates and InjecKit events.
<!-- END MANUAL: agent-guidance -->
