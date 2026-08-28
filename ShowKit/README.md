# ShowKit

R-backed plotting, diagnostics, tables, and figure export for QSP workflows.

ShowKit provides Julia wrappers around ggplot2, pmplots, pmtables, mrggsave,
vpc, and npde. Plot and table objects remain real R objects while Julia
`DataFrame`s and keyword arguments form the public boundary.

```julia
using DataFrames, ShowKit

data = DataFrame(TIME=0:3, DV=[0.0, 1.0, 0.7, 0.3])
plot = ggplot(data, aes(x=:TIME, y=:DV)) + geom_point() + theme_bw()
```

ShowKit uses CondaR's managed R installation. `r_available()` reports whether R
and ggplot2 are usable. R-backed operations fail clearly when their required R
package is unavailable; there is no substitute plotting backend.

See the [manual](docs/src/index.md), [getting-started guide](docs/src/getting_started.md),
and [API reference](docs/src/api_reference.md).
