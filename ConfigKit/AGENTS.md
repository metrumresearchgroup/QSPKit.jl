# ConfigKit Agent Guide

This file is maintained by `tools/generate_agents.jl`.
Edit only the manual section unless you are changing the generator or `tools/agent_overrides.toml`.

<!-- BEGIN GENERATED: agent-context -->
## Package Facts

- Package: `ConfigKit`
- Path: `ConfigKit`
- UUID: `83bc0fb5-991d-4d5f-b655-cf5b37f0dc9f`
- Purpose: Parameter keyfiles, model configuration, and fast ModelingToolkit problem updates.
- Local dependencies: -
- Adjacent packages to inspect for shared behavior: `BayesKit`, `InjecKit`, `PopKit`, `SimKit`
- Files: 11 source, 23 test, 8 docs
- README: `ConfigKit/README.md`
- Docs directory: `ConfigKit/docs`

## Acceptance

- `julia --project=ConfigKit/test --startup-file=no -e 'include("ConfigKit/test/runtests.jl")'`
<!-- END GENERATED: agent-context -->

<!-- BEGIN MANUAL: agent-guidance -->
## Package Rules

- ConfigKit owns keyfile parsing, parameter metadata, and update semantics.
- Keep solver-facing `u0` and symbolic `Initial(var)` parameters synchronized when updates touch initial conditions.
- `InjecKit` consumes ConfigKit update metadata for prepared event execution; inspect both packages for update-policy changes.
- Prefer one shared update policy over package-local special cases.
<!-- END MANUAL: agent-guidance -->
