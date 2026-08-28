# CondaR

CondaR owns the isolated R runtime used by QSPKit's R-backed packages. It uses
CondaPkg for the R installation, disables user and project R startup files, and
keeps RCall operations behind a reentrant lock.

```julia
using CondaR

r_value = reval("sqrt(81)")
@assert rcopy(Float64, r_value) == 9.0
```

Initialization is intentionally strict: if the managed R runtime cannot start,
loading CondaR fails instead of pretending that R-backed functionality is
available. `CondaR.configure!()` can rebuild RCall against the managed R
installation; restart Julia afterward.

The exported wrappers are `reval`, `rcopy`, `rcall`, and `robject`.
