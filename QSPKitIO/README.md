# QSPKitIO

QSPKitIO writes versioned, named-field JLD2 archives for QSPKit result objects.
It preserves a portable primary payload, format/version metadata, recorded type
schemas, and optional native payloads while rejecting unsupported runtime
objects instead of silently serializing them.

```julia
using QSPKitIO

spec = ArchiveSpec("MyResult"; archive_version=1)
save_archive("result.qio", (loss=1.2, params=Dict(:k => 3.0)); spec)
result = load_archive("result.qio"; expected_format="MyResult")
```

Restoration resolves loaded Julia types and can invoke constructors or custom
handlers. Treat archives as trusted executable-adjacent input; do not restore
files from untrusted sources.

See the [manual](docs/src/index.md) for format policies, schema evolution, and
the complete API.
