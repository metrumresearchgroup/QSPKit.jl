# Parameter tables

`ParameterRowKey` distinguishes the same symbol across parameters, initial
conditions, and constants. Use `parameter_key`, `initial_key`, and
`constant_key` when applying metadata to an exact row.

`ParameterUpdate` is the portable value-change format. `model_update` and
`parameter_update` accept pair-like inputs; `optimization_update` also extracts
values from dictionaries, named tuples, vectors with explicit names, and
objects with common estimate fields such as `params` or `minimizer`.

```julia
update = optimization_update(
    [1.2, 4.5];
    names=[:CL, :V],
    label=:estimate,
    source="optimization",
)
```

Save and load updates as YAML with `save_parameter_update` and
`load_parameter_update`.

Metadata overlays add descriptions, units, groups, or other columns without
changing the keyfile:

```julia
metadata = parameter_metadata_overlay(Dict(
    parameter_key(:CL) => (description="Clearance", group="PK"),
    initial_key(:Depot) => (description="Initial depot amount",),
))

table = parameter_table(kf; metadata)
```

Metadata policies are `:prefer_overlay`, `:fill_missing`, and
`:error_on_conflict`. Value overlays use `parameter_overlay`; unmatched values
can be appended, dropped, warned about, or rejected.

Derived parameter expressions are rendered as simple math-mode LaTeX by
default while the original expression remains in the `expression` column. Set
`latex=false` to retain plain text.
