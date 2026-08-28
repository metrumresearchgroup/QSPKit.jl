# QSPReports

QSPReports builds compact text summaries and report-ready parameter tables for
QSPKit workflows. It supports ranked follow-up actions, option provenance,
portable YAML parameter updates, metadata overlays, and ConfigKit keyfile or
variant comparisons.

```julia
using ConfigKit, QSPReports

keyfile = load_keyfile("model.yml")
update = parameter_update(parameters=(CL=1.5,), label=:fit)
table = parameter_table(keyfile, update)
```

QSPReports creates Julia `DataFrame`s and plain-text output; rendering them to a
particular document or plotting backend remains a downstream concern. Keyfile
paths inherit ConfigKit's executable-input boundary and must come from trusted
sources.

See the [manual](docs/src/index.md) for examples and the complete API.
