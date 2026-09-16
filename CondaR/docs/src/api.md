# API reference

- `prepare!()` provisions and validates the active project's managed R runtime
  and writes project-local RCall preferences without importing RCall. Automated
  launchers can run it before starting a fresh workload process; ordinary
  interactive use provisions automatically on the first R operation.
- `reval(code)` evaluates R code in the managed R process.
- `rcopy([T], value)` copies an R value into Julia, optionally converting it
  to `T`.
- `rcall(function_name, args...)` calls an R function.
- `robject(value)` converts a Julia value to an R object.

These are serialized wrappers around the corresponding RCall operations, so
concurrent callers share the same managed R runtime safely.
