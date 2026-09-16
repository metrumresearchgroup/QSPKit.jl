# Archive format

Every archive contains a primary `payload` plus a `__manifest__` with the
format name, archive version, package/Julia versions, creation time, and named
field schemas. Callers can add domain metadata through `manifest_extra`.

`ArchiveSpec` controls what is portable:

- `archivable_modules` permits concrete structs from selected modules.
- `skip_fields` removes runtime-only fields.
- `ref_fields` stores the value inside a `Ref` and rebuilds the wrapper.
- `archive_handlers` and `restore_handlers` handle selected concrete types.
- `default_fields` supplies values for fields introduced after an older
  archive was written.

```julia
spec = ArchiveSpec(
    "ModelResult";
    archive_version=2,
    archivable_modules=[:MyModel],
    skip_fields=Dict(MyModel.Result => (:runtime_cache,)),
    default_fields=Dict((MyModel.Result, :diagnostics) => Dict()),
)
```

Native payloads are an explicit escape hatch for values that JLD2 already
supports and that a consumer wants to retrieve separately. They are not used
as an opaque fallback: unsupported values in the primary payload fail with a
clear error.

Version checks are one-way. A reader accepts archives at or below its declared
maximum version, but rejects a newer archive. Schema compatibility remains the
caller's responsibility through constructors, handlers, and defaults.
