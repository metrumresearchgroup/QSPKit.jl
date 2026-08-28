module StoreKit

using Dates
using SQLite
using DBInterface
using JLD2
using SHA

const _STOREKIT_LOCK = ReentrantLock()

include("db.jl")
include("store.jl")
include("file_tracking.jl")
include("session.jl")
include("attribution.jl")
include("tracing.jl")

# Storage
export Store, open_store, reset_store!
export blob_put!, blob_put_file!, blob_get, blob_get_file, blob_exists, blob_verify, hash_content, hash_file

# Attribution (used by BookKit)
export files_for_result, get_session_log, get_file_reads

# IR tracing
export _discover_closure_source_deps, _scan_deps_recursive!, _trace_fn_deps!
export _is_user_file, _find_project_root, _collect_globalrefs!
# Per-method source fingerprinting
export source_fingerprint, combined_fingerprint

function __init__()
    # Register ast_transforms for interactive session recording.
    # The Base.open method specialization (file_tracking.jl) is always active.
    # The ast_transforms hook is only registered when running in an interactive REPL.
    try
        if isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing
            pushfirst!(Base.active_repl_backend.ast_transforms, _recording_transform)
        end
    catch
        # Not in REPL — script mode. File tracking still active,
        # but expression-level attribution uses static analysis fallback.
    end
end

end # module StoreKit
