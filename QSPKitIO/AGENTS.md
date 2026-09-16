# QSPKitIO Agent Guide

This file is maintained by `tools/generate_agents.jl`.
Edit only the manual section unless you are changing the generator or `tools/agent_overrides.toml`.

<!-- BEGIN GENERATED: agent-context -->
## Package Facts

- Package: `QSPKitIO`
- Path: `QSPKitIO`
- UUID: `cfd30ea6-aeba-4209-96cc-558e5e111311`
- Purpose: Archive IO, portable result payloads, and low-level persistence helpers.
- Local dependencies: -
- Adjacent packages to inspect for shared behavior: `BayesKit`, `StoreKit`
- Files: 1 source, 1 test, 4 docs
- README: -
- Docs directory: `QSPKitIO/docs`

## Acceptance

- `julia --project=QSPKitIO/test --startup-file=no -e 'include("QSPKitIO/test/runtests.jl")'`
<!-- END GENERATED: agent-context -->

<!-- BEGIN MANUAL: agent-guidance -->
## Package Rules

- QSPKitIO owns archive format behavior and portable native payload channels.
- Fix file-handle and archive-boundary issues here before adding downstream workarounds.
- Keep archive changes backwards tolerant unless the task explicitly removes compatibility.
<!-- END MANUAL: agent-guidance -->
