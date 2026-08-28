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
