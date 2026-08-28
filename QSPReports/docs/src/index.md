# QSPReports

QSPReports provides small reporting boundaries shared by QSP workflows. It
keeps computation and rendering separate: the package returns named tuples,
text, `ParameterUpdate` values, `ParameterOverlay` values, and DataFrames that
other tools can print or render.

```@docs
QSPReports
```

## Parameter workflow

```julia
using ConfigKit, QSPReports

kf = load_keyfile("model.yml")
fit = parameter_update(
    parameters=(CL=1.5, V=20.0),
    label=:fit,
    source="fit.yml",
)

table = parameter_table(kf, fit)
save_parameter_update("fit.yml", fit)
```

For keyfiles with two or more variants, pass a path to compare them:

```julia
comparison = parameter_table(
    "synthetic-profiles.yml";
    variants=[:compact, :expanded],
    wide=true,
)
```

ConfigKit keyfiles can contain Julia expression strings. Only load keyfile
paths from trusted sources.
