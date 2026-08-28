# SpecKit

Parse yspec-style YAML data specifications into Julia metadata.

SpecKit's native backend handles column labels, units, ranges, decode maps,
lookup files, flags, glue interpolation, and namespaces without requiring R.

```julia
using SpecKit

spec = load_yspec("data-spec.yml"; backend=:native)
labels = decodes(spec, :ARM)
tex_spec = namespace(spec, "tex")
```

`backend=:auto` uses an already-loaded CondaR/yspec backend when available and
otherwise uses the native parser. `backend=:rcall` is strict and errors when
that optional backend is unavailable. SpecKit does not install R packages at
runtime; applications that select `:rcall` must provision a reviewed yspec
version in their isolated R environment.

See the [manual](docs/src/index.md) and [API reference](docs/src/api.md).
