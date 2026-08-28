# ==============================================================================
# IR-based source dependency tracing
# ==============================================================================
#
# Analyzes lowered IR of closures to discover source file dependencies.
# These functions walk Julia's code_lowered IR to find
# which user-defined source files contribute to a computation.

# Cached project root for the current working directory
const _storekit_src_dir = @__DIR__
const _current_project_root = Ref{Union{Nothing, String}}(nothing)

function _get_current_project_root()
    return lock(_STOREKIT_LOCK) do
        if _current_project_root[] === nothing
            _current_project_root[] = _find_project_root(pwd())
        end
        return _current_project_root[]
    end
end

"""
    _find_project_root(start_dir) → String or nothing

Walk up from `start_dir` looking for a `Project.toml` file.
Returns the directory containing it, or `nothing` if the filesystem root is reached.
"""
function _find_project_root(start_dir::String)
    d = abspath(start_dir)
    while true
        isfile(joinpath(d, "Project.toml")) && return d
        parent = dirname(d)
        parent == d && return nothing
        d = parent
    end
end

"""
    _is_user_file(filepath) → Bool

Check if a file path belongs to user project code (not packages, stdlib, or
StoreKit internals). Used to filter which functions to trace into.
"""
function _is_user_file(filepath::String)
    isempty(filepath) && return false
    startswith(filepath, ":") && return false   # REPL, eval, etc.
    !endswith(filepath, ".jl") && return false
    abs_path = isabspath(filepath) ? filepath : abspath(filepath)
    !isfile(abs_path) && return false
    startswith(abs_path, _storekit_src_dir) && return false
    occursin(".julia/packages/", abs_path) && return false
    occursin("share/julia/", abs_path) && return false
    # Exclude files from dev'd packages that have a different Project.toml
    file_pkg_root = _find_project_root(dirname(abs_path))
    if file_pkg_root !== nothing
        current_root = _get_current_project_root()
        if current_root !== nothing && file_pkg_root != current_root
            return false
        end
    end
    return true
end

"""
    _is_attributable_file(filepath) → Bool

Check if a file path should be snapshotted as a *data* dependency of a booked
result. Unlike [`_is_user_file`](@ref) — which is `.jl`-only because it drives
IR source-dependency tracing — this accepts any project-local file that exists
and is not a package, stdlib, StoreKit-internal, or `.provenance` store path.
Used by `book!` to attribute data files (`.csv`, `.txt`, …) read during a
computation.
"""
function _is_attributable_file(filepath::String)
    isempty(filepath) && return false
    startswith(filepath, ":") && return false   # REPL, eval, etc.
    abs_path = isabspath(filepath) ? filepath : abspath(filepath)
    !isfile(abs_path) && return false
    startswith(abs_path, _storekit_src_dir) && return false
    occursin(".julia/packages/", abs_path) && return false
    occursin("share/julia/", abs_path) && return false
    occursin("/.provenance/", abs_path) && return false   # the provenance store itself
    # Exclude files from dev'd packages that have a different Project.toml
    file_pkg_root = _find_project_root(dirname(abs_path))
    if file_pkg_root !== nothing
        current_root = _get_current_project_root()
        if current_root !== nothing && file_pkg_root != current_root
            return false
        end
    end
    return true
end

"""
    _collect_globalrefs!(refs::Set{GlobalRef}, expr)

Recursively walk a lowered IR expression and collect all `GlobalRef` nodes.
"""
function _collect_globalrefs!(refs::Set{GlobalRef}, expr)
    if expr isa GlobalRef
        push!(refs, expr)
    elseif expr isa Expr
        for arg in expr.args
            _collect_globalrefs!(refs, arg)
        end
    end
    # SSAValue, SlotNumber, literals, etc. — nothing to collect
end

"""
    _trace_fn_deps!(deps::Dict{String,String}, seen_fns::Set{UInt64}, fn)

Trace source file dependencies from a function by inspecting its lowered IR.
Uses `methods(fn)` to find the source file of each method, then walks
`code_lowered` to discover called functions and recursively traces them.

Only traces into functions with at least one method defined in user code
(skips packages, stdlib, StoreKit internals).
"""
function _trace_fn_deps!(deps::Dict{String,String}, seen_fns::Set{UInt64}, fn)
    id = objectid(fn)
    id in seen_fns && return
    push!(seen_fns, id)

    # Register source files from all methods of this function
    ms = try methods(fn).ms catch; return end
    for m in ms
        file = string(m.file)
        if _is_user_file(file)
            abs_file = isabspath(file) ? file : abspath(file)
            deps[abs_file] = hash_file(abs_file)
        end
    end

    # Walk lowered IR to find called functions, recurse into user-defined ones
    cis = try code_lowered(fn) catch; return end
    for ci in cis
        refs = Set{GlobalRef}()
        for stmt in ci.code
            _collect_globalrefs!(refs, stmt)
        end
        for ref in refs
            ref.mod === Core && continue  # Skip Core builtins (Core.kwcall, etc.)
            val = try getfield(ref.mod, ref.name) catch; continue end
            val isa Function || continue
            # Only recurse if the function has at least one user-file method
            has_user_method = false
            try
                for m in methods(val).ms
                    if _is_user_file(string(m.file))
                        has_user_method = true
                        break
                    end
                end
            catch; end
            has_user_method && _trace_fn_deps!(deps, seen_fns, val)
        end
    end
end

"""
    _scan_deps_recursive!(deps, file, seen)

Recursively scan `file` for `include()` patterns and add discovered files to `deps`.

Recognized patterns:
- `include("relative/path.jl")`
- `include(@projectroot("dir", "file.jl"))`
"""
function _scan_deps_recursive!(deps::Dict{String,String}, file::String, seen::Set{String})
    file in seen && return
    push!(seen, file)
    isfile(file) || return

    deps[file] = hash_file(file)

    base_dir = dirname(file)
    content = try read(file, String) catch; return end

    # Pattern 1: include("literal_path.jl")
    for m in eachmatch(r"include\(\s*\"([^\"]+)\"\s*\)", content)
        inc_path = normpath(joinpath(base_dir, m.captures[1]))
        _scan_deps_recursive!(deps, inc_path, seen)
    end

    # Pattern 2: include(@projectroot("dir", "file.jl"))
    for m in eachmatch(r"include\(\s*@projectroot\(([^)]+)\)\s*\)", content)
        parts = [c.captures[1] for c in eachmatch(r"\"([^\"]+)\"", m.captures[1])]
        if !isempty(parts)
            proj_root = _find_project_root(base_dir)
            if proj_root !== nothing
                inc_path = normpath(joinpath(proj_root, parts...))
                _scan_deps_recursive!(deps, inc_path, seen)
            end
        end
    end
end

"""
    _discover_closure_source_deps(closure) → Dict{String,String}

Trace all source file dependencies of a closure by:
1. Inspecting captured function fields
2. Walking lowered IR for GlobalRef nodes
3. Transitively scanning discovered files for `include()` patterns

Returns a Dict mapping absolute file paths to their SHA-256 hashes.
"""
function _discover_closure_source_deps(closure)
    deps = Dict{String, String}()
    seen_fns = Set{UInt64}()

    # Trace captured function values (closure fields accessed via fields, not GlobalRefs)
    for fname in fieldnames(typeof(closure))
        val = try getfield(closure, fname) catch; continue end
        val isa Function && _trace_fn_deps!(deps, seen_fns, val)
    end

    cis = try code_lowered(closure) catch; return deps end
    for ci in cis
        refs = Set{GlobalRef}()
        for stmt in ci.code
            _collect_globalrefs!(refs, stmt)
        end
        for ref in refs
            ref.mod === Core && continue
            val = try getfield(ref.mod, ref.name) catch; continue end
            val isa Function || continue
            has_user_method = false
            try
                for m in methods(val).ms
                    if _is_user_file(string(m.file))
                        has_user_method = true
                        break
                    end
                end
            catch; end
            has_user_method && _trace_fn_deps!(deps, seen_fns, val)
        end
    end

    # Transitive include scanning
    if !isempty(deps)
        ir_files = collect(keys(deps))
        seen_files = Set{String}()
        for file in ir_files
            _scan_deps_recursive!(deps, file, seen_files)
        end
    end

    return deps
end

# ==============================================================================
# Per-method lowered-IR source fingerprinting
# ==============================================================================
#
# Unlike the file-hashing tracer above, this hashes each reachable method's
# *lowered AST* rather than its whole source file. Shared source files often hold
# unrelated functions, so whole-file hashing would mark an artifact stale after
# an edit to an unused sibling function. Per-method hashing is deterministic,
# insensitive to unused sibling edits, change-sensitive for reachable methods,
# and works on REPL-defined methods. It is valid only within a Julia version
# because lowered-IR layout can change; the producing Julia version is therefore
# captured separately.

"""
    _is_traceable_file(filepath) → Bool

Reachability predicate for source fingerprinting. Unlike [`_is_user_file`](@ref),
this does NOT reject files under a *different* project root — a dev'd sibling
package's source is a genuine code dependency and must be fingerprinted. It still
skips Base/stdlib, registered packages, StoreKit internals, and the provenance
store. It does not require the file to exist on disk (the AST, not the file, is
hashed) nor to end in `.jl`.
"""
function _is_traceable_file(filepath::String)
    isempty(filepath) && return false
    startswith(filepath, ":") && return false   # REPL / eval sentinel
    filepath == "none" && return false
    abs_path = isabspath(filepath) ? filepath : abspath(filepath)
    startswith(abs_path, _storekit_src_dir) && return false
    occursin(".julia/packages/", abs_path) && return false
    occursin("share/julia/", abs_path) && return false
    occursin("/.provenance/", abs_path) && return false
    return true
end

"""
    _is_traceable_method(m::Method) → Bool

True if method `m` should be fingerprinted/recursed into. REPL/eval-defined
methods (`m.file == "none"` or a `:`-sentinel) have no on-disk anchor but their
AST is still fingerprintable, so they are traced.
"""
function _is_traceable_method(m::Method)
    f = string(m.file)
    (f == "none" || startswith(f, ":")) && return true
    return _is_traceable_file(f)
end

"""
    _method_id(m::Method) → String

A stable per-method key: `Module.name(signature)`. Stable across redefinition and
file relocation (excludes file:line); a signature change is a real dependency
change.
"""
_method_id(m::Method) = string(m.module) * "." * string(m.name) * "(" * string(m.sig) * ")"

"""
    _method_codeinfo(m::Method) → Core.CodeInfo or nothing

The method's lowered AST. `Base.uncompressed_ast` THROWS on `@generated` methods,
so for those we fall back to the generator's own method body (the source that
produces bodies). Returns `nothing` if the method is not introspectable.
"""
function _method_codeinfo(m::Method)
    try
        if isdefined(m, :generator)
            gm = first(methods(m.generator.gen))
            return Base.uncompressed_ast(gm)
        end
        return Base.uncompressed_ast(m)
    catch
        return nothing
    end
end

"""
    _method_fingerprint(m::Method) → String

SHA-256 of the method's normalized lowered AST (LineNumberNodes dropped and slot
names included). Falls back to a signature-based hash for methods whose AST
cannot be introspected.
"""
function _method_fingerprint(m::Method)
    ci = _method_codeinfo(m)
    ci === nothing && return bytes2hex(SHA.sha256("sig:" * _method_id(m)))
    stmts = filter(s -> !(s isa LineNumberNode), ci.code)
    payload = join(string.(stmts), "\n") * "\n#slots#" * string(ci.slotnames)
    return bytes2hex(SHA.sha256(payload))
end

"""
    _trace_fn_fingerprints!(fps, seen_fns, fn)

Reachability walk (same shape as [`_trace_fn_deps!`](@ref)) with a per-method
AST-hash leaf: fingerprint each traceable method of `fn`, then follow `GlobalRef`
callees and recurse into the user/dev-defined ones.
"""
function _trace_fn_fingerprints!(fps::Dict{String,String}, seen_fns::Set{UInt64}, fn)
    id = objectid(fn)
    id in seen_fns && return
    push!(seen_fns, id)

    ms = try methods(fn).ms catch; return end
    for m in ms
        _is_traceable_method(m) || continue
        fps[_method_id(m)] = _method_fingerprint(m)
    end

    cis = try code_lowered(fn) catch; return end
    for ci in cis
        refs = Set{GlobalRef}()
        for stmt in ci.code
            _collect_globalrefs!(refs, stmt)
        end
        for ref in refs
            ref.mod === Core && continue
            val = try getfield(ref.mod, ref.name) catch; continue end
            val isa Function || continue
            traceable = false
            try
                for m in methods(val).ms
                    if _is_traceable_method(m)
                        traceable = true
                        break
                    end
                end
            catch; end
            traceable && _trace_fn_fingerprints!(fps, seen_fns, val)
        end
    end
end

"""
    source_fingerprint(fn) → Dict{String,String}

Per-method source fingerprint of `fn` and the user/dev code it transitively
reaches: a map from a stable method id (`Module.name(sig)`) to the SHA-256 of
that method's normalized lowered AST. Seeds from `fn`'s captured closure fields
and its lowered IR. Base/stdlib/registered-package code is excluded; dev'd
sibling-package source is included.

Reachability is static (via `GlobalRef`s), so a callee reached only through a
variable / higher-order argument / dynamic dispatch is not followed.
"""
function source_fingerprint(fn)
    fps = Dict{String,String}()
    seen = Set{UInt64}()
    for fname in fieldnames(typeof(fn))
        val = try getfield(fn, fname) catch; continue end
        val isa Function && _trace_fn_fingerprints!(fps, seen, val)
    end
    _trace_fn_fingerprints!(fps, seen, fn)
    return fps
end

"""
    combined_fingerprint(fn) → String

An order-independent SHA-256 fold of [`source_fingerprint`](@ref)`(fn)`, suitable
as a single `"source"` value in a booking's fingerprint map. Returns the hash of
the empty set when nothing user/dev-defined is reachable.
"""
function combined_fingerprint(fn)
    d = source_fingerprint(fn)
    payload = join(sort([k * "=>" * v for (k, v) in d]), "\n")
    return bytes2hex(SHA.sha256(payload))
end
