# ═══ Session Expression Log via ast_transforms ═══
#
# In interactive mode (REPL / VSCode shift+enter), an ast_transforms hook
# records every evaluated expression with its variable definitions and
# references (via ExpressionExplorer.jl). Before each expression evaluates,
# the hook sets _CURRENT_EXPR_ID so file_tracking.jl can tag file reads
# with the correct expression.

using ExpressionExplorer

"""
    SessionEntry

A single expression evaluated in the session, recording which variables
it defined and which it referenced.

# Fields
- `id::Int` — unique expression ID for this session
- `defs::Set{Symbol}` — variables assigned by this expression
- `refs::Set{Symbol}` — variables read by this expression
"""
struct SessionEntry
    id::Int
    defs::Set{Symbol}
    refs::Set{Symbol}
end

"""
    SESSION_LOG

Global log of session expressions. Populated by the ast_transforms hook
in interactive mode. Each entry records the expression's definitions,
references, and a unique ID that links to file reads in `FILE_READS`.
"""
const SESSION_LOG = SessionEntry[]

"""
    _EXPR_COUNTER

Monotonically increasing counter for expression IDs within a session.
"""
const _EXPR_COUNTER = Ref{Int}(0)

function _begin_expr!()
    return lock(_STOREKIT_LOCK) do
        _EXPR_COUNTER[] += 1
        eid = _EXPR_COUNTER[]
        _CURRENT_EXPR_ID[] = eid
        eid
    end
end

function _finish_expr!(eid::Int, defs, refs)
    lock(_STOREKIT_LOCK) do
        _CURRENT_EXPR_ID[] = 0
        push!(SESSION_LOG, SessionEntry(eid, defs, refs))
    end
    return nothing
end

"""
    _recording_transform(ex)

AST transform hook that wraps each REPL expression to:
1. Set `_CURRENT_EXPR_ID` before evaluation (so file reads are tagged)
2. Evaluate the original expression unchanged
3. Clear the ID and log the entry with defs/refs from ExpressionExplorer

Registered via `pushfirst!(Base.active_repl_backend.ast_transforms, ...)`
in `__init__()`.
"""
function _recording_transform(ex)
    node = ExpressionExplorer.compute_reactive_node(ex)

    defs = node.definitions
    refs = node.references

    return quote
        local _storekit_eid = StoreKit._begin_expr!()
        try
            $ex
        finally
            StoreKit._finish_expr!(_storekit_eid, $(defs), $(refs))
        end
    end
end

"""
    get_session_log()

Return a copy of the current session expression log.
"""
get_session_log() = lock(_STOREKIT_LOCK) do
    copy(SESSION_LOG)
end

"""
    clear_session_log!()

Clear the session log and reset the expression counter. Useful for testing.
"""
function clear_session_log!()
    lock(_STOREKIT_LOCK) do
        empty!(SESSION_LOG)
        _EXPR_COUNTER[] = 0
        _CURRENT_EXPR_ID[] = 0
    end
    return nothing
end
