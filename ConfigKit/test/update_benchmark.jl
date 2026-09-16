# Benchmark: ConfigKit.update vs SciML recommended approaches
#
# Run standalone from QSPKit/ConfigKit/test:
#   julia --project .. -e 'include("update_benchmark.jl")'
# Or from QSPKit root:
#   julia --project=ConfigKit/test ConfigKit/test/update_benchmark.jl

using BenchmarkTools
using ModelingToolkitBase
using ModelingToolkitBase: t_nounits as t, D_nounits as D
using OrdinaryDiffEq
using SciMLBase
using SymbolicIndexingInterface: parameter_values, setp, parameter_index
using SciMLStructures: Tunable, canonicalize, replace, replace!

# --- Build a small Lotka-Volterra test model ---

@parameters α=1.5 β=1.0 γ=3.0 δ=1.0
@variables x(t)=1.0 y(t)=1.0

eqs = [
    D(x) ~ α * x - β * x * y,
    D(y) ~ -γ * y + δ * x * y,
]

@named lv = ODESystem(eqs, t)
sys = mtkcompile(lv)
prob = ODEProblem(sys, Dict(), (0.0, 10.0))

# --- Test values ---
new_α, new_β, new_γ, new_δ = 1.3, 0.9, 2.8, 1.1

println("="^70)
println("Benchmark: Parameter update strategies")
println("="^70)
println()

# =====================================================================
# 1) Naive: remake with symbolic map (slowest)
# =====================================================================
println("1) Naive remake with symbolic map [α => val, ...]")
b1 = @benchmark remake($prob; p = [$α => $new_α, $β => $new_β, $γ => $new_γ, $δ => $new_δ])
display(b1)
println("\n")

# =====================================================================
# 2) ConfigKit-style: copy + setp + remake (setter created each call)
# =====================================================================
println("2) ConfigKit-style: copy(prob.p) + setp(...) + remake(prob; p=pnew)")
println("   (setter created on every call, like ConfigKit.update does)")
syms = [α, β, γ, δ]
function configkit_style(prob, syms, vals)
    pnew = copy(prob.p)
    setp(prob, syms)(pnew, vals)
    return SciMLBase.remake(prob; p = pnew)
end
vals = [new_α, new_β, new_γ, new_δ]
b2 = @benchmark configkit_style($prob, $syms, $vals)
display(b2)
println("\n")

# =====================================================================
# 3) Cached setter: setp created once, reused
# =====================================================================
println("3) Cached setter: setp created once + copy + remake")
cached_setter = setp(prob, [α, β, γ, δ])
function cached_setp_update(prob, setter, vals)
    pnew = copy(prob.p)
    setter(pnew, vals)
    return SciMLBase.remake(prob; p = pnew)
end
b3 = @benchmark cached_setp_update($prob, $cached_setter, $vals)
display(b3)
println("\n")

# =====================================================================
# 4) SciMLStructures.replace + canonicalize (no DiffCache)
# =====================================================================
println("4) SciMLStructures.replace + canonicalize + cached setter")
function replace_update(prob, setter, vals)
    ps = parameter_values(prob)
    buffer = copy(canonicalize(Tunable(), ps)[1])
    ps = replace(Tunable(), ps, buffer)
    setter(ps, vals)
    return SciMLBase.remake(prob; p = ps)
end
b4 = @benchmark replace_update($prob, $cached_setter, $vals)
display(b4)
println("\n")

# =====================================================================
# 5) In-place replace! (mutates original — not thread-safe)
# =====================================================================
println("5) In-place replace! + remake (mutates prob.p)")
function replace_bang_update(prob, vals)
    ps = parameter_values(prob)
    replace!(Tunable(), ps, vals)
    return SciMLBase.remake(prob; p = ps)
end
# Need a fresh prob each time since this mutates
b5 = @benchmark replace_bang_update(prob_copy, $vals) setup=(prob_copy = deepcopy($prob))
display(b5)
println("\n")

# =====================================================================
# 6) ConfigKit.update (full pipeline with key resolution)
# =====================================================================
println("6) ConfigKit.update (full pipeline: key resolution + units + setp + remake)")
using ConfigKit
pairs_sym = [α => new_α, β => new_β, γ => new_γ, δ => new_δ]
b6 = @benchmark ConfigKit.update($prob, $pairs_sym; validate_units=false, convert_units=false)
display(b6)
println("\n")

# =====================================================================
# 7) ConfigKit.update with string keys (extra resolution overhead)
# =====================================================================
println("7) ConfigKit.update with string keys")
pairs_str = ["α" => new_α, "β" => new_β, "γ" => new_γ, "δ" => new_δ]
b7 = @benchmark ConfigKit.update($prob, $pairs_str; validate_units=false, convert_units=false)
display(b7)
println("\n")

# =====================================================================
# Summary
# =====================================================================
println("="^70)
println("Summary (median times)")
println("="^70)
results = [
    ("1. Naive symbolic map remake", b1),
    ("2. ConfigKit-style (uncached setter)", b2),
    ("3. Cached setter + copy + remake", b3),
    ("4. SciMLStructures.replace", b4),
    ("5. In-place replace!", b5),
    ("6. ConfigKit.update (symbolic keys)", b6),
    ("7. ConfigKit.update (string keys)", b7),
]

baseline = minimum(median(r[2]).time for r in results)
for (name, bench) in results
    t_ns = median(bench).time
    allocs = median(bench).allocs
    mem = median(bench).memory
    ratio = t_ns / baseline
    println("  $(rpad(name, 42)) $(lpad(BenchmarkTools.prettytime(t_ns), 12))  $(lpad(string(allocs), 4)) allocs  $(lpad(BenchmarkTools.prettymemory(mem), 10))  $(round(ratio, digits=1))x")
end
