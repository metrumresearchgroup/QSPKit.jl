# QSPKitCore

QSPKitCore is the dependency-light internal support package used by InjecKit.
Application code should normally use ConfigKit, InjecKit, or SimKit instead.

```@docs
QSPKitCore
```

## Symbolic compilation

```@docs
with_symbolic_compilation_lock
```

The lock is process-local and reentrant. It serializes known ModelingToolkit
and SymbolicUtils code-generation paths that can mutate shared scratch state.
It does not coordinate separate Julia processes or make arbitrary model code
thread-safe.

## Configuration and worker utilities

The remaining public API consists of `config_values`, `public_config_values`,
`replace_config`, `is_auto_provenance_field`, `resolve_worker_layout`, and
`run_worker_queue!`.
