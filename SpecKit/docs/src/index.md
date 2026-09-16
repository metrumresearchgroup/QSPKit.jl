# SpecKit

SpecKit reads yspec-style YAML metadata with a native Julia backend. It records
column descriptions, labels, units, ranges, decode maps, flags, lookup
provenance, and alternate namespaces.

```julia
using SpecKit

metadata = load_yspec("data-spec.yml"; backend=:native)
arm_labels = decodes(metadata, :ARM)
tex_metadata = namespace(metadata, "tex")
audit = lookup_source(metadata)
```

The supported backend choices are:

- `:native`: always use the Julia YAML parser.
- `:auto`: use an already-loaded CondaR/yspec backend when available, otherwise
  use the native parser.
- `:rcall`: require the R backend and fail clearly when it is unavailable.

SpecKit only detects optional R dependencies. It does not install or update
them during package use. Provision a reviewed yspec version in the isolated R
environment before selecting `:rcall`.

`ColumnSpec` represents one column. `YspecMetadata` stores the complete parsed
specification.
