# Phase-2 feasibility canary: per-method lowered-IR fingerprinting.
#
# Validates the assumption the staleness redesign relies on
# (BookKit/docs/staleness_redesign_plan.md §3): hashing ONE method's normalized lowered
# AST is
#   (a) deterministic across redefinition of identical source,
#   (b) INSENSITIVE to edits of UNUSED sibling functions in the same file
#       — the `helper.jl` requirement: shared helper files must not blanket-false-stale,
#   (c) sensitive to real edits of a used function,
#   (d) exposes callees as GlobalRefs so the transitive reachability walk works,
#   (e) works on methods with no on-disk source (REPL/eval-defined).
#
# This is NOT testing shipped BookKit code yet. It is a CANARY: if a Julia upgrade or
# environment change breaks the determinism/granularity assumptions, this fails loudly
# BEFORE Phase 2 builds the real per-method fingerprinter on top of the (currently dead)
# StoreKit `_trace_fn_deps!` reachability walk.
#
# Isolated in its own module so the throwaway foo/bar/baz/replfn definitions don't leak
# into the rest of the test suite, and so the `module` sits at top level (it cannot be
# nested inside a @testset begin/end block).

module MethodFPFeasibility

using Test
using SHA

# Hash a single Method's lowered AST, normalized to drop volatile line info.
function method_fp(m::Method)
    ci = Base.uncompressed_ast(m)
    stmts = filter(s -> !(s isa LineNumberNode), ci.code)
    payload = join(string.(stmts), "\n") * "\n#slots#" * string(ci.slotnames)
    return bytes2hex(sha256(payload))
end
fp(f) = method_fp(first(methods(f)))

function collect_globalrefs(x, acc)
    if x isa GlobalRef
        push!(acc, x)
    elseif x isa Expr
        for a in x.args
            collect_globalrefs(a, acc)
        end
    end
    return acc
end

@testset "per-method lowered-IR fingerprint feasibility (Phase 2 canary)" begin
    # A "helpers.jl" with a USED (bar) and an UNUSED (baz) sibling; foo calls bar, not baz.
    # @eval so the (re)definitions land in this module even from inside the testset block.
    @eval bar(x) = 2x + 1
    @eval baz(x) = x^2 + 99
    @eval foo(x) = bar(x) + 7

    h_foo1 = fp(foo)
    h_bar1 = fp(bar)
    h_baz1 = fp(baz)

    # (a) determinism — recompute, and redefine identical source
    @test fp(foo) == h_foo1
    @eval bar(x) = 2x + 1
    @test fp(bar) == h_bar1

    # (b) THE helper-file requirement — edit the UNUSED baz; foo & bar must NOT move
    @eval baz(x) = x^3 - 12345
    @test fp(foo) == h_foo1
    @test fp(bar) == h_bar1
    @test fp(baz) != h_baz1

    # (c) real change detection — edit the USED bar
    @eval bar(x) = 5x - 2
    @test fp(bar) != h_bar1

    # (d) reachability — callee `bar` recoverable as a GlobalRef from foo's lowered IR
    ci = Base.uncompressed_ast(first(methods(foo)))
    gr = GlobalRef[]
    for s in ci.code
        collect_globalrefs(s, gr)
    end
    @test any(g -> g.name === :bar, gr)

    # (e) works on a method with no on-disk source (eval-defined, REPL-style)
    @eval replfn(x) = bar(x) - 1
    @test method_fp(first(methods(replfn))) isa String
end

end # module MethodFPFeasibility
