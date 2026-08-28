# QSPKitIO

QSPKitIO stores QSPKit results as versioned JLD2 archives. The primary payload
uses explicit container markers and named struct fields, making schema changes
visible and allowing readers to supply defaults for newly added fields.

```@docs
QSPKitIO
```

## Basic use

```julia
using QSPKitIO

spec = ArchiveSpec(
    "CalibrationResult";
    archive_version=1,
    package_name="MyModel",
)

save_archive(
    "fit.qio",
    (parameters=Dict(:CL => 1.5), loss=2.1);
    spec,
    manifest_extra=Dict("model" => "pk-v2"),
)

manifest = read_archive_manifest("fit.qio")
fit = load_archive("fit.qio"; expected_format="CalibrationResult")
```

Callers should reject unexpected formats and versions. Pass the same
`ArchiveSpec` to `load_archive` when a payload uses custom handlers, reference
fields, or schema-evolution defaults.

## Trust boundary

Restoration resolves type names in loaded Julia modules and can invoke type
constructors or registered restore handlers. An archive is therefore not a
sandboxed data format. Only restore files created by a trusted workflow.
