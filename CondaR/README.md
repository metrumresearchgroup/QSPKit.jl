# CondaR

CondaR's alpha support boundary is Linux and macOS. Its R-library layout and
process isolation are Unix-specific; Windows is not currently supported.

CondaPkg-managed R environment and execution support for QSPKit packages.

CondaR starts one isolated R runtime, prevents project or user R profiles from
changing its library paths, and serializes calls through a process-local lock.
ShowKit uses it for plotting and table generation.

```julia
using CondaR

two = rcopy(Int, reval("1L + 1L"))
@assert two == 2
```

The package requires its CondaPkg-managed R installation to initialize. A
failure to start R is an error; CondaR does not silently substitute another
backend. If RCall was built against another R installation, run
`CondaR.configure!()` and restart Julia.

See the [manual](docs/src/index.md) and [API reference](docs/src/api.md).
