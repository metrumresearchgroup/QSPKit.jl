# API

## Configuration and context

- `ArchiveSpec` describes the format name, version, package, and optional
  schema handlers for an archive.
- `ArchiveContext` carries archive and schema metadata during conversion.
- `TYPE_KEY` is the reserved payload key used to identify encoded types.
- `archive_type_name`, `record_schema!`, `coerce_field`, and `default_field`
  customize schema-aware encoding and restoration.

## In-memory conversion

- `archive_payload(value, context)` converts a value to portable containers.
- `restore_payload(value, context)` restores a converted payload.

## Files

- `save_archive` and `load_archive` write and restore complete archives.
- `read_archive_manifest` reads metadata without restoring the payload.
- `has_archive_native_payload` and `read_archive_native_payload` inspect an
  optional native Julia payload.
