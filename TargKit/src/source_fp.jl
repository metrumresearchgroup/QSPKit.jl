# Vendored, self-contained per-method source fingerprinting (SHA-only).
#
# Mirrors StoreKit.source_fingerprint but with NO provenance-package dependency,
# so TargKit can attach a code fingerprint to FitResult without coupling a fit
# library to the provenance layer. Hashes each reachable method's normalized
# lowered AST (per-method, not whole files, so editing an unrelated function in a
# shared helper.jl does not change the fingerprint). Intra-Julia-version only.

module _SourceFP

using SHA

const _targkit_src_dir = @__DIR__

# Reachability predicate: skip Base/stdlib/registered packages and TargKit's own
# source; include user/project and dev'd-package code. Does not require the file
# to exist (the AST, not the file, is hashed).
function _is_traceable_file(fp::String)
    isempty(fp) && return false
    startswith(fp, ":") && return false
    fp == "none" && return false
    abs = isabspath(fp) ? fp : abspath(fp)
    startswith(abs, _targkit_src_dir) && return false
    occursin(".julia/packages/", abs) && return false
    occursin("share/julia/", abs) && return false
    return true
end

function _is_traceable_method(m::Method)
    f = string(m.file)
    (f == "none" || startswith(f, ":")) && return true
    return _is_traceable_file(f)
end

_method_id(m::Method) = string(m.module) * "." * string(m.name) * "(" * string(m.sig) * ")"

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

function _method_fingerprint(m::Method)
    ci = _method_codeinfo(m)
    ci === nothing && return bytes2hex(sha256("sig:" * _method_id(m)))
    stmts = filter(s -> !(s isa LineNumberNode), ci.code)
    payload = join(string.(stmts), "\n") * "\n#slots#" * string(ci.slotnames)
    return bytes2hex(sha256(payload))
end

function _collect_globalrefs!(refs::Set{GlobalRef}, expr)
    if expr isa GlobalRef
        push!(refs, expr)
    elseif expr isa Expr
        for a in expr.args
            _collect_globalrefs!(refs, a)
        end
    end
end

function _trace!(fps::Dict{String,String}, seen::Set{UInt64}, fn)
    id = objectid(fn)
    id in seen && return
    push!(seen, id)

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
            tr = false
            try
                for m in methods(val).ms
                    if _is_traceable_method(m)
                        tr = true
                        break
                    end
                end
            catch; end
            tr && _trace!(fps, seen, val)
        end
    end
end

"""
    source_fingerprint(fn) -> Dict{String,String}

Per-method source fingerprint of `fn` and the user/dev code it transitively
reaches via `GlobalRef`s. Keyed by `Module.name(sig)` → normalized-AST SHA-256.
"""
function source_fingerprint(fn)
    fps = Dict{String,String}()
    seen = Set{UInt64}()
    for fname in fieldnames(typeof(fn))
        val = try getfield(fn, fname) catch; continue end
        val isa Function && _trace!(fps, seen, val)
    end
    _trace!(fps, seen, fn)
    return fps
end

"""
    combined_fingerprint(fn) -> String

Order-independent SHA-256 fold of [`source_fingerprint`](@ref)`(fn)`.
"""
function combined_fingerprint(fn)
    d = source_fingerprint(fn)
    payload = join(sort([k * "=>" * v for (k, v) in d]), "\n")
    return bytes2hex(sha256(payload))
end

end # module _SourceFP
