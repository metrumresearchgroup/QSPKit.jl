# API Reference

## Store

```@docs
Store
reset_store!
```

`open_store(path)` opens or creates the StoreKit database and blob directory at
`path`.

## Blob Operations

```@docs
blob_put!
blob_put_file!
blob_get
blob_get_file
blob_exists
blob_verify
hash_content
hash_file
```

## Attribution

```@docs
files_for_result
get_session_log
get_file_reads
```

## IR Tracing

```@docs
_discover_closure_source_deps
_scan_deps_recursive!
_trace_fn_deps!
_is_user_file
_find_project_root
_collect_globalrefs!
source_fingerprint
combined_fingerprint
```
