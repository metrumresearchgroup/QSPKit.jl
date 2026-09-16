# ═══ Attribution Engine ═══
#
# Determines which files contributed to a given result variable by walking
# the session log backward from the result, finding all contributing
# expression IDs, and matching them to file reads.
#
# Two modes:
# - Interactive (REPL): precise per-expression attribution via SESSION_LOG
# - Script mode: static analysis via ExpressionExplorer on parsed source

"""
    files_for_result(result_var::Symbol; session_log=SESSION_LOG, file_reads=FILE_READS)

Walk the session log backward from `result_var` to find all files that
contributed to its value.

Returns a named tuple `(data_files, expr_ids)` where:
- `data_files::Set{String}` — absolute paths of files opened during contributing expressions
- `expr_ids::Set{Int}` — the expression IDs in the dependency chain

# Algorithm
1. Start with `needed = {result_var}`
2. Walk session log in reverse. For each entry whose `defs` intersect `needed`,
   add its `id` to contributing set and its `refs` to `needed`.
3. Match contributing expression IDs to file reads from `FILE_READS`.
"""
function files_for_result(result_var::Symbol; session_log=SESSION_LOG, file_reads=FILE_READS)
    needed = Set{Symbol}([result_var])
    contributing_ids = Set{Int}()

    for entry in reverse(session_log)
        if !isempty(intersect(entry.defs, needed))
            push!(contributing_ids, entry.id)
            union!(needed, entry.refs)
        end
    end

    data_files = Set{String}()
    for fr in file_reads
        _is_read_mode(fr.mode) || continue   # skip files opened for writing (outputs)
        if fr.expr_id in contributing_ids
            push!(data_files, fr.path)
        end
    end

    return (data_files=data_files, expr_ids=contributing_ids)
end

"""
    _script_mode_attribution(calling_file::String, result_var::Symbol; file_reads=FILE_READS)

Fallback attribution for script mode (no session log). Parses the calling
script with `Meta.parseall`, builds a dependency graph via ExpressionExplorer,
walks it backward from `result_var`, and matches file reads by basename.

Also includes all `.jl` files from `FILE_READS` (source files loaded via
`include()` — caught by the `Base.open` method specialization).

Returns a named tuple `(data_files, expr_ids)`.
"""
function _script_mode_attribution(calling_file::String, result_var::Symbol; file_reads=FILE_READS)
    source = read(calling_file, String)
    exprs = Meta.parseall(source).args

    # Build expression log from static parsing
    script_log = SessionEntry[]
    idx = 0
    for ex in exprs
        ex isa LineNumberNode && continue
        node = ExpressionExplorer.compute_reactive_node(ex)
        idx += 1
        push!(script_log, SessionEntry(idx, node.definitions, node.references))
    end

    # Walk dependency chain from result_var
    needed = Set{Symbol}([result_var])
    contributing_ids = Set{Int}()
    for entry in reverse(script_log)
        if !isempty(intersect(entry.defs, needed))
            push!(contributing_ids, entry.id)
            union!(needed, entry.refs)
        end
    end

    # Collect non-LineNumberNode expressions for string matching
    real_exprs = [ex for ex in exprs if !(ex isa LineNumberNode)]

    # Match file reads against string literals in contributing expressions
    attributed_files = Set{String}()
    for fr in file_reads
        _is_read_mode(fr.mode) || continue   # skip files opened for writing (outputs)
        for entry in script_log
            entry.id in contributing_ids || continue
            expr_str = string(real_exprs[entry.id])
            if occursin(basename(fr.path), expr_str)
                push!(attributed_files, fr.path)
            end
        end
    end

    # All include()-triggered source file reads are already in FILE_READS
    # because include() goes through Base.open. Add .jl files from the chain.
    for fr in file_reads
        _is_read_mode(fr.mode) || continue   # skip written .jl outputs
        if endswith(fr.path, ".jl") && fr.path != abspath(calling_file)
            push!(attributed_files, fr.path)
        end
    end

    return (data_files=attributed_files, expr_ids=contributing_ids)
end
