#!/usr/bin/env julia
# Profile ConfigKit.update against standard MTK remake and optimized SciML
# parameter/state update patterns, with equivalence checks before timing.
#
# Run from the QSPKit repo root:
#   julia --project=ConfigKit/test --startup-file=no ConfigKit/test/profile_update_hotpath.jl
#
# Useful knobs:
#   CK_PROFILE_ITERS=250
#   CK_PROFILE_WARMUP=20
#   CK_PROFILE_TARGET=configkit_nested_nt
#   CK_PROFILE_INCLUDE_UNSAFE=false
#   CK_PROFILE_ALLOCS=true
#   CK_PROFILE_OUTDIR=outputs/my_profile

using BenchmarkTools: prettytime, prettymemory
using ConfigKit
using Dates
using ForwardDiff
using ModelingToolkitBase
using ModelingToolkitBase: t_nounits as t, D_nounits as D
using PreallocationTools: DiffCache, get_tmp
using Printf
using Profile
using SciMLBase
using SciMLStructures: Tunable, canonicalize, replace, replace!
using Serialization
using Statistics
using SymbolicIndexingInterface: parameter_values, state_values, setp, setu
import SymbolicIndexingInterface

const SINK = Ref{Any}(0.0)

Base.@kwdef struct ProfileCase
    name::String
    description::String
    runner::Function
    maker::Union{Nothing, Function} = nothing
    score::Union{Nothing, Function} = nothing
    group::String = "scalar"
    reference::Bool = false
    must_match::Bool = true
    fraction::Float64 = 1.0
    contract::String = "contract-preserving"
end

function env_int(name::String, default::Int)
    value = get(ENV, name, "")
    isempty(value) && return default
    return parse(Int, value)
end

env_float(name::String, default::Float64) = isempty(get(ENV, name, "")) ? default : parse(Float64, ENV[name])
function env_bool(name::String, default::Bool)
    value = lowercase(get(ENV, name, ""))
    isempty(value) && return default
    return value in ("1", "true", "yes", "on")
end

function scalar_value(x)
    if x isa AbstractArray || x isa Tuple
        return sum(scalar_value, x)
    end
    return try
        Float64(x)
    catch
        Float64(ForwardDiff.value(x))
    end
end

function as_float(x)
    x === missing && return NaN
    return try
        Float64(x)
    catch
        Float64(ForwardDiff.value(x))
    end
end

# -----------------------------------------------------------------------------
# Model contexts
# -----------------------------------------------------------------------------

function build_param_problem()
    @parameters alpha=1.5 beta=1.0 gamma=3.0 delta=1.0
    @variables x(t)=1.0 y(t)=1.0
    eqs = [
        D(x) ~ (alpha - beta * y) * x,
        D(y) ~ (delta * x - gamma) * y,
    ]
    @mtkcompile sys = System(eqs, t)
    prob = ODEProblem(sys, Dict(), (0.0, 10.0))
    syms = [alpha, beta, gamma, delta]
    states = [x, y]
    ps = parameter_values(prob)
    tunable = copy(canonicalize(Tunable(), ps)[1])
    u0 = copy(state_values(prob))
    return (
        prob = prob,
        syms = syms,
        states = states,
        tracked = Any[alpha, beta, gamma, delta],
        alpha = alpha, beta = beta, gamma = gamma, delta = delta,
        x = x, y = y,
        p_setter = setp(prob, syms),
        u_setter = setu(prob, states),
        base_tunable = tunable,
        param_diffcache = DiffCache(copy(tunable)),
        base_u0 = u0,
        u0_diffcache = DiffCache(copy(u0)),
        pvals = copy(tunable),
        uvals = copy(u0),
        dual_param_x = collect(Float64, tunable),
        param_update_cache = ConfigKit.UpdateCache(prob, (:alpha, :beta, :gamma, :delta); strict=false),
        state_update_cache = ConfigKit.UpdateCache(prob, (:x, :y); strict=false),
    )
end

function build_simple_u0_problem()
    @parameters k=0.1 a=1.0 b=0.2
    @variables x(t)=a y(t)=a+b
    eqs = [D(x) ~ -k * x, D(y) ~ k * x - b * y]
    @mtkcompile sys = System(eqs, t)
    prob = ODEProblem(sys, Dict(k => 0.1, a => 1.0, b => 0.2), (0.0, 1.0))
    syms = [a, b, k]
    ps = parameter_values(prob)
    tunable = copy(canonicalize(Tunable(), ps)[1])
    return (
        prob = prob,
        syms = syms,
        tracked = Any[a, b, k, ModelingToolkitBase.Initial(x), ModelingToolkitBase.Initial(y)],
        a = a, b = b, k = k,
        x = x, y = y,
        x0 = ModelingToolkitBase.Initial(x),
        y0 = ModelingToolkitBase.Initial(y),
        p_setter = setp(prob, syms),
        base_tunable = tunable,
        param_diffcache = DiffCache(copy(tunable)),
        pvals = copy(tunable),
        dual_param_x = collect(Float64, tunable),
        u0dep_update_cache = ConfigKit.UpdateCache(prob, (:a, :b, :k); strict=false),
    )
end

function build_nested_problem()
    yaml = """
    Parameters:
      CL:
        value: 10.0
      V1:
        value: 50.0
      V2:
        value: 50.0
      dose:
        value: 100.0
      scale:
        value: 2.0
      Vss:
        value: V1 + V2
      kel:
        value: CL / Vss
      I0:
        value: dose / Vss
      J0:
        value: I0 * scale
    Variables:
      Central:
        initial: J0
      Peripheral:
        initial: I0 + J0
    """
    @parameters CL V1 V2 dose scale Vss kel I0 J0
    @variables Central(t) Peripheral(t)
    eqs = [
        D(Central) ~ -kel * Central,
        D(Peripheral) ~ kel * Central - scale * Peripheral,
    ]
    sys = System(eqs, t; name = :nested_update_profile)
    path = tempname() * ".yml"
    write(path, yaml)
    try
        sys_pop = populate(sys, load_keyfile(path); strict = false)
        sys_simp = mtkcompile(sys_pop)
        prob = ODEProblem(sys_simp, [], (0.0, 1.0))
        syms = [CL, V1, V2, dose, scale]
        ps = parameter_values(prob)
        tunable = copy(canonicalize(Tunable(), ps)[1])
        return (
            prob = prob,
            syms = syms,
            tracked = Any[CL, V1, V2, dose, scale, Vss, kel, I0, J0,
                          ModelingToolkitBase.Initial(Central), ModelingToolkitBase.Initial(Peripheral)],
            CL = CL, V1 = V1, V2 = V2, dose = dose, scale = scale,
            Vss = Vss, kel = kel, I0 = I0, J0 = J0,
            Central = Central, Peripheral = Peripheral,
            Central0 = ModelingToolkitBase.Initial(Central),
            Peripheral0 = ModelingToolkitBase.Initial(Peripheral),
            p_setter = setp(prob, syms),
            base_tunable = tunable,
            param_diffcache = DiffCache(copy(tunable)),
            pvals = copy(tunable),
            dual_param_x = collect(Float64, tunable),
            nested_update_cache = ConfigKit.UpdateCache(prob, (:CL, :V1, :V2, :dose, :scale); strict=false),
        )
    finally
        rm(path; force = true)
    end
end

function build_context()
    return (param = build_param_problem(), u0dep = build_simple_u0_problem(), nested = build_nested_problem())
end

# -----------------------------------------------------------------------------
# Value generators
# -----------------------------------------------------------------------------

function update_param_values!(ctx, i)
    j = mod(i - 1, 100)
    vals = ctx.pvals
    vals[1] = 1.30 + 0.0005 * j
    vals[2] = 0.90 + 0.0003 * j
    vals[3] = 2.80 + 0.0004 * j
    vals[4] = 1.10 + 0.0002 * j
    return vals
end

function update_state_values!(ctx, i)
    j = mod(i - 1, 100)
    vals = ctx.uvals
    vals[1] = 1.00 + 0.0010 * j
    vals[2] = 0.75 + 0.0007 * j
    return vals
end

function update_u0dep_values!(ctx, i)
    j = mod(i - 1, 100)
    vals = ctx.pvals
    vals[1] = 1.00 + 0.0020 * j # a
    vals[2] = 0.20 + 0.0005 * j # b
    vals[3] = 0.10 + 0.0003 * j # k
    return vals
end

function update_nested_values!(ctx, i)
    j = mod(i - 1, 100)
    vals = ctx.pvals
    vals[1] = 20.0 + 0.010 * j # CL
    vals[2] = 60.0 + 0.020 * j # V1
    vals[3] = 40.0 + 0.015 * j # V2
    vals[4] = 200.0 + 0.050 * j # dose
    vals[5] = 3.0 + 0.001 * j # scale
    return vals
end

# -----------------------------------------------------------------------------
# Signatures and scores
# -----------------------------------------------------------------------------

function tracked_value(prob, key)
    try
        return prob.ps[key]
    catch
        try
            return prob[key]
        catch
            return missing
        end
    end
end

function problem_signature(prob, tracked)
    tunable = try
        collect(canonicalize(Tunable(), parameter_values(prob))[1])
    catch
        Float64[]
    end
    return vcat(
        as_float.(collect(state_values(prob))),
        as_float.(tunable),
        as_float.([tracked_value(prob, k) for k in tracked]),
        Float64[prob.tspan[1], prob.tspan[2]],
    )
end

function signatures_close(a, b; atol = 1e-10, rtol = 1e-10)
    length(a) == length(b) || return false
    for (x, y) in zip(a, b)
        if isnan(x) || isnan(y)
            isnan(x) == isnan(y) || return false
        elseif !isapprox(x, y; atol, rtol)
            return false
        end
    end
    return true
end

function sync_initials_from_u0(prob::SciMLBase.ODEProblem)
    sys = prob.f.sys
    keys = Any[]
    vals = Any[]
    for var in ModelingToolkitBase.unknowns(sys)
        initial_key = try
            ModelingToolkitBase.Initial(var)
        catch
            nothing
        end
        initial_key === nothing && continue
        try
            prob.ps[initial_key]
        catch
            continue
        end
        val = try
            prob[var]
        catch
            continue
        end
        push!(keys, initial_key)
        push!(vals, val)
    end
    isempty(keys) && return prob
    ps = SymbolicIndexingInterface.remake_buffer(prob, parameter_values(prob), keys, vals)
    return SciMLBase.remake(prob; p = ps, build_initializeprob = false)
end

param_score(c, prob) = sum(as_float(tracked_value(prob, k)) for k in c.tracked)
state_score(c, prob) = prob[c.x] + prob[c.y] + prob.ps[ModelingToolkitBase.Initial(c.x)] + prob.ps[ModelingToolkitBase.Initial(c.y)]
u0dep_score(c, prob) = sum(as_float(tracked_value(prob, k)) for k in c.tracked) + prob[c.x] + prob[c.y]
nested_score(c, prob) = sum(as_float(tracked_value(prob, k)) for k in c.tracked) + prob[c.Central] + prob[c.Peripheral]

# -----------------------------------------------------------------------------
# Problem makers: each returns an ODEProblem for equivalence checks.
# -----------------------------------------------------------------------------

function make_configkit_param(ctx, i)
    c = ctx.param; v = update_param_values!(c, i)
    return ConfigKit.update(c.prob, (; alpha = v[1], beta = v[2], gamma = v[3], delta = v[4]);
        strict = false, build_initializeprob = false)
end

function make_update_cache_param(ctx, i)
    c = ctx.param; v = update_param_values!(c, i)
    return ConfigKit.update!(c.param_update_cache,
        (; alpha = v[1], beta = v[2], gamma = v[3], delta = v[4]);
        build_initializeprob = false)
end

function make_naive_remake_param(ctx, i)
    c = ctx.param; v = update_param_values!(c, i)
    return SciMLBase.remake(c.prob;
        p = [c.alpha => v[1], c.beta => v[2], c.gamma => v[3], c.delta => v[4]],
        build_initializeprob = false)
end

function make_remake_setp_param(ctx, i)
    c = ctx.param; v = update_param_values!(c, i)
    prob2 = SciMLBase.remake(c.prob; build_initializeprob = false)
    c.p_setter(prob2, v)
    return prob2
end

function make_replace_copy_param(ctx, i)
    c = ctx.param; v = update_param_values!(c, i)
    buffer = copy(c.base_tunable)
    ps = replace(Tunable(), parameter_values(c.prob), buffer)
    c.p_setter(ps, v)
    return SciMLBase.remake(c.prob; p = ps, build_initializeprob = false)
end

function make_replace_diffcache_param(ctx, i)
    c = ctx.param; v = update_param_values!(c, i)
    buffer = get_tmp(c.param_diffcache, v)
    copyto!(buffer, c.base_tunable)
    ps = replace(Tunable(), parameter_values(c.prob), buffer)
    c.p_setter(ps, v)
    return SciMLBase.remake(c.prob; p = ps, build_initializeprob = false)
end

function make_replace_bang_param(ctx, i)
    c = ctx.param; v = update_param_values!(c, i)
    prob2 = SciMLBase.remake(c.prob; build_initializeprob = false)
    replace!(Tunable(), parameter_values(prob2), v)
    return prob2
end

function make_remake_buffer_param(ctx, i)
    c = ctx.param; v = update_param_values!(c, i)
    ps = SymbolicIndexingInterface.remake_buffer(c.prob, parameter_values(c.prob), c.syms, v)
    return SciMLBase.remake(c.prob; p = ps, build_initializeprob = false)
end

function make_configkit_state(ctx, i)
    c = ctx.param; v = update_state_values!(c, i)
    return ConfigKit.update(c.prob, (; x = v[1], y = v[2]); strict = false)
end

function make_update_cache_state(ctx, i)
    c = ctx.param; v = update_state_values!(c, i)
    return ConfigKit.update!(c.state_update_cache, (; x = v[1], y = v[2]))
end

function make_naive_remake_state(ctx, i)
    c = ctx.param; v = update_state_values!(c, i)
    return sync_initials_from_u0(SciMLBase.remake(c.prob; u0 = [c.x => v[1], c.y => v[2]]))
end

function make_remake_setu_state(ctx, i)
    c = ctx.param; v = update_state_values!(c, i)
    prob2 = SciMLBase.remake(c.prob; build_initializeprob = false)
    c.u_setter(prob2, v)
    return sync_initials_from_u0(prob2)
end

function make_state_diffcache(ctx, i)
    c = ctx.param; v = update_state_values!(c, i)
    u0 = get_tmp(c.u0_diffcache, v)
    copyto!(u0, c.base_u0)
    c.u_setter(u0, v)
    return sync_initials_from_u0(SciMLBase.remake(c.prob; u0 = u0, build_initializeprob = false))
end

function make_configkit_u0dep(ctx, i)
    c = ctx.u0dep; v = update_u0dep_values!(c, i)
    return ConfigKit.update(c.prob, (; a = v[1], b = v[2], k = v[3]); strict = false)
end

function make_update_cache_u0dep(ctx, i)
    c = ctx.u0dep; v = update_u0dep_values!(c, i)
    return ConfigKit.update!(c.u0dep_update_cache, (; a = v[1], b = v[2], k = v[3]))
end

function make_naive_remake_u0dep(ctx, i)
    c = ctx.u0dep; v = update_u0dep_values!(c, i)
    return sync_initials_from_u0(SciMLBase.remake(c.prob; p = [c.a => v[1], c.b => v[2], c.k => v[3]]))
end

function make_remake_buffer_u0dep(ctx, i)
    c = ctx.u0dep; v = update_u0dep_values!(c, i)
    ps = SymbolicIndexingInterface.remake_buffer(c.prob, parameter_values(c.prob), c.syms, v)
    return sync_initials_from_u0(SciMLBase.remake(c.prob; p = ps, build_initializeprob = true))
end

function make_configkit_nested(ctx, i)
    c = ctx.nested; v = update_nested_values!(c, i)
    return ConfigKit.update(c.prob, (; CL = v[1], V1 = v[2], V2 = v[3], dose = v[4], scale = v[5]); strict = false)
end

function make_update_cache_nested(ctx, i)
    c = ctx.nested; v = update_nested_values!(c, i)
    return ConfigKit.update!(c.nested_update_cache,
        (; CL = v[1], V1 = v[2], V2 = v[3], dose = v[4], scale = v[5]))
end

function make_naive_remake_nested(ctx, i)
    c = ctx.nested; v = update_nested_values!(c, i)
    return sync_initials_from_u0(SciMLBase.remake(c.prob;
        p = [c.CL => v[1], c.V1 => v[2], c.V2 => v[3], c.dose => v[4], c.scale => v[5]]))
end

function make_remake_buffer_nested(ctx, i)
    c = ctx.nested; v = update_nested_values!(c, i)
    ps = SymbolicIndexingInterface.remake_buffer(c.prob, parameter_values(c.prob), c.syms, v)
    return sync_initials_from_u0(SciMLBase.remake(c.prob; p = ps, build_initializeprob = true))
end

function make_replace_diffcache_nested(ctx, i)
    c = ctx.nested; v = update_nested_values!(c, i)
    buffer = get_tmp(c.param_diffcache, v)
    copyto!(buffer, c.base_tunable)
    ps = replace(Tunable(), parameter_values(c.prob), buffer)
    c.p_setter(ps, v)
    return sync_initials_from_u0(SciMLBase.remake(c.prob; p = ps, build_initializeprob = true))
end

function make_replace_diffcache_nested_noinit(ctx, i)
    c = ctx.nested; v = update_nested_values!(c, i)
    buffer = get_tmp(c.param_diffcache, v)
    copyto!(buffer, c.base_tunable)
    ps = replace(Tunable(), parameter_values(c.prob), buffer)
    c.p_setter(ps, v)
    return SciMLBase.remake(c.prob; p = ps, build_initializeprob = false)
end

# -----------------------------------------------------------------------------
# Runners
# -----------------------------------------------------------------------------

run_problem_case(maker, score, ctx, i) = score(ctx, maker(ctx, i))
make_runner(maker, score) = (ctx, i) -> run_problem_case(maker, score, ctx, i)

function configkit_param_dual_objective(c, x)
    prob2 = ConfigKit.update(c.prob, (; alpha = x[1], beta = x[2], gamma = x[3], delta = x[4]);
        strict = false, build_initializeprob = false)
    return param_score(c, prob2)
end

function update_cache_param_dual_objective(c, x)
    prob2 = ConfigKit.update!(c.param_update_cache,
        (; alpha = x[1], beta = x[2], gamma = x[3], delta = x[4]);
        build_initializeprob = false)
    return param_score(c, prob2)
end

function replace_diffcache_param_dual_objective(c, x)
    buffer = get_tmp(c.param_diffcache, x)
    copyto!(buffer, c.base_tunable)
    ps = replace(Tunable(), parameter_values(c.prob), buffer)
    c.p_setter(ps, x)
    prob2 = SciMLBase.remake(c.prob; p = ps, build_initializeprob = false)
    return param_score(c, prob2)
end

function configkit_nested_dual_objective(c, x)
    prob2 = ConfigKit.update(c.prob, (; CL = x[1], V1 = x[2], V2 = x[3], dose = x[4], scale = x[5]); strict = false)
    return nested_score(c, prob2)
end

function update_cache_nested_dual_objective(c, x)
    prob2 = ConfigKit.update!(c.nested_update_cache,
        (; CL = x[1], V1 = x[2], V2 = x[3], dose = x[4], scale = x[5]))
    return nested_score(c, prob2)
end

function remake_buffer_nested_dual_objective(c, x)
    ps = SymbolicIndexingInterface.remake_buffer(c.prob, parameter_values(c.prob), c.syms, x)
    prob2 = SciMLBase.remake(c.prob; p = ps, build_initializeprob = true)
    return nested_score(c, prob2)
end

function configkit_dual_param_gradient(ctx, i)
    c = ctx.param; x = c.dual_param_x; copyto!(x, update_param_values!(c, i))
    return sum(ForwardDiff.gradient(z -> configkit_param_dual_objective(c, z), x))
end

function update_cache_dual_param_gradient(ctx, i)
    c = ctx.param; x = c.dual_param_x; copyto!(x, update_param_values!(c, i))
    return sum(ForwardDiff.gradient(z -> update_cache_param_dual_objective(c, z), x))
end

function replace_diffcache_dual_param_gradient(ctx, i)
    c = ctx.param; x = c.dual_param_x; copyto!(x, update_param_values!(c, i))
    return sum(ForwardDiff.gradient(z -> replace_diffcache_param_dual_objective(c, z), x))
end

function configkit_dual_nested_gradient(ctx, i)
    c = ctx.nested; x = c.dual_param_x; copyto!(x, update_nested_values!(c, i))
    return sum(ForwardDiff.gradient(z -> configkit_nested_dual_objective(c, z), x))
end

function update_cache_dual_nested_gradient(ctx, i)
    c = ctx.nested; x = c.dual_param_x; copyto!(x, update_nested_values!(c, i))
    return sum(ForwardDiff.gradient(z -> update_cache_nested_dual_objective(c, z), x))
end

function remake_buffer_dual_nested_gradient(ctx, i)
    c = ctx.nested; x = c.dual_param_x; copyto!(x, update_nested_values!(c, i))
    return sum(ForwardDiff.gradient(z -> remake_buffer_nested_dual_objective(c, z), x))
end

# -----------------------------------------------------------------------------
# Case catalog and equivalence checks
# -----------------------------------------------------------------------------

function build_cases(; include_unsafe::Bool = false)
    cases = ProfileCase[
        ProfileCase(name = "configkit_param_nt", group = "param", reference = true,
            description = "ConfigKit.update NamedTuple parameter update; no init rebuild needed",
            maker = make_configkit_param, score = (ctx, prob) -> param_score(ctx.param, prob),
            runner = make_runner(make_configkit_param, (ctx, prob) -> param_score(ctx.param, prob))),
        ProfileCase(name = "update_cache_param_nt", group = "param",
            description = "ConfigKit.UpdateCache + update! parameter workspace; returned problem is cache-borrowed",
            maker = make_update_cache_param, score = (ctx, prob) -> param_score(ctx.param, prob),
            runner = make_runner(make_update_cache_param, (ctx, prob) -> param_score(ctx.param, prob))),
        ProfileCase(name = "naive_remake_param_map", group = "param", fraction = 0.25,
            description = "Slow symbolic remake(prob; p = [sym => value, ...]) baseline",
            maker = make_naive_remake_param, score = (ctx, prob) -> param_score(ctx.param, prob),
            runner = make_runner(make_naive_remake_param, (ctx, prob) -> param_score(ctx.param, prob))),
        ProfileCase(name = "remake_setp_param", group = "param",
            description = "SciML remake(prob) then cached setp on the copied problem",
            maker = make_remake_setp_param, score = (ctx, prob) -> param_score(ctx.param, prob),
            runner = make_runner(make_remake_setp_param, (ctx, prob) -> param_score(ctx.param, prob))),
        ProfileCase(name = "replace_copy_param", group = "param",
            description = "SciMLStructures.replace with a fresh copied Tunable buffer",
            maker = make_replace_copy_param, score = (ctx, prob) -> param_score(ctx.param, prob),
            runner = make_runner(make_replace_copy_param, (ctx, prob) -> param_score(ctx.param, prob))),
        ProfileCase(name = "replace_diffcache_param", group = "param",
            description = "SciMLStructures.replace with a PreallocationTools.DiffCache buffer",
            maker = make_replace_diffcache_param, score = (ctx, prob) -> param_score(ctx.param, prob),
            runner = make_runner(make_replace_diffcache_param, (ctx, prob) -> param_score(ctx.param, prob))),
        ProfileCase(name = "replace_bang_after_remake_param", group = "param",
            description = "remake(prob) then replace!(Tunable(), ...) on the copied problem",
            maker = make_replace_bang_param, score = (ctx, prob) -> param_score(ctx.param, prob),
            runner = make_runner(make_replace_bang_param, (ctx, prob) -> param_score(ctx.param, prob))),
        ProfileCase(name = "remake_buffer_param", group = "param",
            description = "SymbolicIndexingInterface.remake_buffer then remake",
            maker = make_remake_buffer_param, score = (ctx, prob) -> param_score(ctx.param, prob),
            runner = make_runner(make_remake_buffer_param, (ctx, prob) -> param_score(ctx.param, prob))),
        ProfileCase(name = "configkit_state_nt", group = "state", reference = true,
            description = "ConfigKit.update NamedTuple state/u0 update with Initial sync",
            maker = make_configkit_state, score = (ctx, prob) -> state_score(ctx.param, prob),
            runner = make_runner(make_configkit_state, (ctx, prob) -> state_score(ctx.param, prob))),
        ProfileCase(name = "update_cache_state_nt", group = "state",
            description = "ConfigKit.UpdateCache + update! direct state/u0 workspace with Initial sync",
            maker = make_update_cache_state, score = (ctx, prob) -> state_score(ctx.param, prob),
            runner = make_runner(make_update_cache_state, (ctx, prob) -> state_score(ctx.param, prob))),
        ProfileCase(name = "naive_remake_state_map", group = "state", fraction = 0.25,
            description = "Slow symbolic remake(prob; u0 = [state => value, ...]) baseline",
            maker = make_naive_remake_state, score = (ctx, prob) -> state_score(ctx.param, prob),
            runner = make_runner(make_naive_remake_state, (ctx, prob) -> state_score(ctx.param, prob))),
        ProfileCase(name = "remake_setu_state", group = "state",
            description = "SciML remake(prob) then cached setu plus explicit Initial sync",
            maker = make_remake_setu_state, score = (ctx, prob) -> state_score(ctx.param, prob),
            runner = make_runner(make_remake_setu_state, (ctx, prob) -> state_score(ctx.param, prob))),
        ProfileCase(name = "state_diffcache_setu_remake", group = "state",
            description = "cached setu into DiffCache u0 buffer then remake plus Initial sync",
            maker = make_state_diffcache, score = (ctx, prob) -> state_score(ctx.param, prob),
            runner = make_runner(make_state_diffcache, (ctx, prob) -> state_score(ctx.param, prob))),
        ProfileCase(name = "configkit_u0dep_nt", group = "u0dep", reference = true,
            description = "ConfigKit.update for parameter-dependent initial conditions",
            maker = make_configkit_u0dep, score = (ctx, prob) -> u0dep_score(ctx.u0dep, prob),
            runner = make_runner(make_configkit_u0dep, (ctx, prob) -> u0dep_score(ctx.u0dep, prob))),
        ProfileCase(name = "update_cache_u0dep_nt", group = "u0dep",
            description = "ConfigKit.UpdateCache + update! for parameter-dependent initial conditions",
            maker = make_update_cache_u0dep, score = (ctx, prob) -> u0dep_score(ctx.u0dep, prob),
            runner = make_runner(make_update_cache_u0dep, (ctx, prob) -> u0dep_score(ctx.u0dep, prob))),
        ProfileCase(name = "naive_remake_u0dep_map", group = "u0dep", fraction = 0.25,
            description = "Slow symbolic remake with parameter-dependent IC rebuild plus Initial sync",
            maker = make_naive_remake_u0dep, score = (ctx, prob) -> u0dep_score(ctx.u0dep, prob),
            runner = make_runner(make_naive_remake_u0dep, (ctx, prob) -> u0dep_score(ctx.u0dep, prob))),
        ProfileCase(name = "remake_buffer_u0dep", group = "u0dep",
            description = "remake_buffer with MTK init rebuild plus Initial sync",
            maker = make_remake_buffer_u0dep, score = (ctx, prob) -> u0dep_score(ctx.u0dep, prob),
            runner = make_runner(make_remake_buffer_u0dep, (ctx, prob) -> u0dep_score(ctx.u0dep, prob))),
        ProfileCase(name = "configkit_nested_nt", group = "nested", reference = true,
            description = "ConfigKit.update with nested binding parameters and nested dependent ICs",
            maker = make_configkit_nested, score = (ctx, prob) -> nested_score(ctx.nested, prob),
            runner = make_runner(make_configkit_nested, (ctx, prob) -> nested_score(ctx.nested, prob))),
        ProfileCase(name = "update_cache_nested_nt", group = "nested",
            description = "ConfigKit.UpdateCache + update! with nested binding parameters and nested dependent ICs",
            maker = make_update_cache_nested, score = (ctx, prob) -> nested_score(ctx.nested, prob),
            runner = make_runner(make_update_cache_nested, (ctx, prob) -> nested_score(ctx.nested, prob))),
        ProfileCase(name = "naive_remake_nested_map", group = "nested", fraction = 0.10, must_match = true,
            contract = "contract-preserving with explicit Initial sync",
            description = "Slow symbolic remake on nested bindings/dependent ICs plus Initial sync",
            maker = make_naive_remake_nested, score = (ctx, prob) -> nested_score(ctx.nested, prob),
            runner = make_runner(make_naive_remake_nested, (ctx, prob) -> nested_score(ctx.nested, prob))),
        ProfileCase(name = "remake_buffer_nested", group = "nested", must_match = true,
            contract = "contract-preserving with explicit Initial sync",
            description = "remake_buffer on nested bindings/dependent ICs with MTK init rebuild plus Initial sync",
            maker = make_remake_buffer_nested, score = (ctx, prob) -> nested_score(ctx.nested, prob),
            runner = make_runner(make_remake_buffer_nested, (ctx, prob) -> nested_score(ctx.nested, prob))),
        ProfileCase(name = "replace_diffcache_nested", group = "nested", must_match = true,
            contract = "contract-preserving with explicit Initial sync",
            description = "DiffCache+replace on nested bindings/dependent ICs with MTK init rebuild plus Initial sync",
            maker = make_replace_diffcache_nested, score = (ctx, prob) -> nested_score(ctx.nested, prob),
            runner = make_runner(make_replace_diffcache_nested, (ctx, prob) -> nested_score(ctx.nested, prob))),
        ProfileCase(name = "configkit_dual_param_gradient", group = "dual_param", reference = true, fraction = 0.10,
            description = "ForwardDiff gradient through ConfigKit parameter update",
            runner = configkit_dual_param_gradient),
        ProfileCase(name = "update_cache_dual_param_gradient", group = "dual_param", fraction = 0.10,
            description = "ForwardDiff gradient through ConfigKit.UpdateCache + update! parameter update",
            runner = update_cache_dual_param_gradient),
        ProfileCase(name = "replace_diffcache_dual_param_gradient", group = "dual_param", fraction = 0.10,
            description = "ForwardDiff gradient through DiffCache+replace parameter update",
            runner = replace_diffcache_dual_param_gradient),
        ProfileCase(name = "configkit_dual_nested_gradient", group = "dual_nested", reference = true, fraction = 0.05,
            description = "ForwardDiff gradient through ConfigKit nested binding/dependent-IC update",
            runner = configkit_dual_nested_gradient),
        ProfileCase(name = "update_cache_dual_nested_gradient", group = "dual_nested", reference = false, fraction = 0.05,
            description = "ForwardDiff gradient through ConfigKit.UpdateCache + update! nested binding/dependent-IC update",
            runner = update_cache_dual_nested_gradient),
        ProfileCase(name = "remake_buffer_dual_nested_gradient", group = "dual_nested", fraction = 0.05, must_match = false,
            contract = "diagnostic: direct remake path may leave Initial(...) params stale",
            description = "ForwardDiff gradient through remake_buffer nested update",
            runner = remake_buffer_dual_nested_gradient),
    ]
    if include_unsafe
        push!(cases, ProfileCase(name = "replace_diffcache_nested_noinit_unsafe", group = "nested", must_match = false,
            contract = "unsafe: skips nested binding/dependent initial-condition rebuild",
            description = "DiffCache+replace nested lower bound with init rebuild disabled",
            maker = make_replace_diffcache_nested_noinit, score = (ctx, prob) -> nested_score(ctx.nested, prob),
            runner = make_runner(make_replace_diffcache_nested_noinit, (ctx, prob) -> nested_score(ctx.nested, prob))))
    end
    return cases
end

function group_tracked(ctx, group::String)
    group == "param" && return ctx.param.tracked
    group == "state" && return Any[ctx.param.x, ctx.param.y, ModelingToolkitBase.Initial(ctx.param.x), ModelingToolkitBase.Initial(ctx.param.y)]
    group == "u0dep" && return ctx.u0dep.tracked
    group == "nested" && return ctx.nested.tracked
    return Any[]
end

function check_equivalence(cases, ctx; sample_i = 17)
    refs = Dict{String, ProfileCase}()
    for case in cases
        case.reference && (refs[case.group] = case)
    end
    rows = NamedTuple[]
    for case in cases
        if case.maker !== nothing
            ref = refs[case.group]
            tracked = group_tracked(ctx, case.group)
            ref_sig = problem_signature(ref.maker(ctx, sample_i), tracked)
            case_sig = problem_signature(case.maker(ctx, sample_i), tracked)
            ok = signatures_close(ref_sig, case_sig)
            max_abs = length(ref_sig) == length(case_sig) ? maximum(abs.(ref_sig .- case_sig)) : Inf
            push!(rows, (name = case.name, group = case.group, equivalent = ok,
                max_abs_diff = max_abs, contract = case.contract))
            if case.must_match && !ok
                error("Equivalence check failed for $(case.name) against $(ref.name) in group $(case.group); max_abs_diff=$max_abs")
            end
        elseif haskey(refs, case.group)
            ref = refs[case.group]
            ref_val = scalar_value(ref.runner(ctx, sample_i))
            case_val = scalar_value(case.runner(ctx, sample_i))
            ok = isapprox(ref_val, case_val; atol = 1e-8, rtol = 1e-8)
            push!(rows, (name = case.name, group = case.group, equivalent = ok,
                max_abs_diff = abs(ref_val - case_val), contract = case.contract))
            if case.must_match && !ok
                error("Scalar equivalence check failed for $(case.name) against $(ref.name) in group $(case.group)")
            end
        end
    end
    return rows
end

function write_time_dependent_notes(outdir)
    notes = """
    Time-dependent parameter handling notes
    ======================================

    SimKit Population covariates are per-subject values: event-level construction
    extracts covariates from the first row per subject, and idata construction uses
    one idata row per subject. Ordinary covariates are not turned into time-varying
    MTK parameters.

    InjecKit EVID=2 parameter-change events are the time-varying path. Event rows
    collect non-reserved columns into IEvent.param_changes, resolve those keys as
    parameters, and validate require_time_dependent=true. That validation requires
    MTK discrete time-dependent parameters, with the current error text telling
    users to declare them as @discretes name(t). Those callbacks update discrete
    parameters at event times via SymbolicDiscreteCallback.

    Consequence: a NONMEM-style column like BW that changes over TIME is only
    history-correct if it is represented as EVID=2 parameter-change events for a
    model variable declared as @discretes BW(t). If BW is only passed through
    Population(...; parameters=:auto) as a covariate, SimKit/PopCore use the first
    per-subject BW value for the whole solve.
    """
    write(joinpath(outdir, "time_dependent_parameter_notes.txt"), notes)
end

# -----------------------------------------------------------------------------
# Timing and profile output
# -----------------------------------------------------------------------------

function run_case(case::ProfileCase, ctx, n::Int; score::Bool = false)
    if score || case.maker === nothing
        acc = 0.0
        for i in 1:n
            acc += scalar_value(case.runner(ctx, i))
        end
        SINK[] = acc
        return acc
    end

    last = nothing
    maker = case.maker
    for i in 1:n
        last = maker(ctx, i)
    end
    SINK[] = last
    return n
end

measured_iterations(case::ProfileCase, base_iters::Int) = max(1, round(Int, base_iters * case.fraction))

function time_case(case::ProfileCase, ctx, warmup::Int, base_iters::Int; score::Bool = false)
    nwarm = measured_iterations(case, warmup)
    n = measured_iterations(case, base_iters)
    run_case(case, ctx, nwarm; score)
    GC.gc()
    elapsed_ref = Ref(0.0)
    bytes = @allocated begin
        elapsed_ref[] = @elapsed run_case(case, ctx, n; score)
    end
    return (
        name = case.name,
        group = case.group,
        calls = n,
        seconds = elapsed_ref[],
        seconds_per_call = elapsed_ref[] / n,
        allocated = bytes,
        allocated_per_call = bytes / n,
        contract = case.contract,
        description = case.description,
    )
end

function print_summary(io, results)
    println(io, "case,group,calls,total_time,per_call,allocated,allocated_per_call,contract,description")
    for r in results
        println(io, join((
            r.name, r.group, string(r.calls), @sprintf("%.6g", r.seconds),
            prettytime(r.seconds_per_call * 1e9), prettymemory(r.allocated),
            prettymemory(r.allocated_per_call), Base.replace(r.contract, ',' => ';'),
            Base.replace(r.description, ',' => ';'),
        ), ','))
    end
end

function print_human_summary(io, results)
    println(io, "ConfigKit.update isolated profile summary")
    println(io, "="^88)
    for r in results
        @printf(io, "%38s  %-11s  %7d calls  %12s/call  %12s/call  %s\n",
            r.name, r.group, r.calls, prettytime(r.seconds_per_call * 1e9),
            prettymemory(r.allocated_per_call), r.contract)
    end
end

function print_equivalence(io, rows)
    println(io, "case,group,equivalent,max_abs_diff,contract")
    for r in rows
        println(io, join((r.name, r.group, string(r.equivalent), @sprintf("%.6g", r.max_abs_diff), Base.replace(r.contract, ',' => ';')), ','))
    end
end

function print_equivalence_human(io, rows)
    println(io, "Equivalence checks against each group reference")
    println(io, "="^88)
    for r in rows
        status = r.equivalent ? "OK" : "DIFF"
        @printf(io, "%38s  %-11s  %-4s  max_abs_diff=%s  %s\n",
            r.name, r.group, status, @sprintf("%.6g", r.max_abs_diff), r.contract)
    end
end

function write_profile(outdir::String, case::ProfileCase, ctx, n::Int; allocs::Bool, alloc_sample_rate::Float64, score::Bool = false)
    run_case(case, ctx, max(1, min(n, 5)); score)
    GC.gc()
    Profile.clear()
    Profile.init(; n = 10_000_000, delay = 0.001)
    Profile.@profile run_case(case, ctx, n; score)

    open(joinpath(outdir, "cpu_tree.txt"), "w") do io
        try
            Profile.print(io; format = :tree, combine = true)
        catch
            Profile.print(io; format = :tree)
        end
    end
    open(joinpath(outdir, "cpu_flat.txt"), "w") do io
        try
            Profile.print(io; format = :flat, sortedby = :count, combine = true)
        catch
            Profile.print(io; format = :flat)
        end
    end
    open(joinpath(outdir, "profile_retrieve.jls"), "w") do io
        serialize(io, Profile.retrieve())
    end

    if allocs && isdefined(Profile, :Allocs)
        try
            Profile.Allocs.clear()
            Profile.Allocs.@profile sample_rate=alloc_sample_rate run_case(case, ctx, n; score)
            open(joinpath(outdir, "allocs.txt"), "w") do io
                Profile.Allocs.print(io)
            end
        catch err
            open(joinpath(outdir, "allocs_error.txt"), "w") do io
                showerror(io, err, catch_backtrace())
            end
            @warn "Profile.Allocs failed; wrote allocs_error.txt" exception=(err, catch_backtrace())
        end
    end
end

function main()
    include_unsafe = env_bool("CK_PROFILE_INCLUDE_UNSAFE", false)
    warmup = env_int("CK_PROFILE_WARMUP", 20)
    iters = env_int("CK_PROFILE_ITERS", 250)
    target = get(ENV, "CK_PROFILE_TARGET", "configkit_nested_nt")
    run_allocs = env_bool("CK_PROFILE_ALLOCS", true)
    alloc_sample_rate = env_float("CK_PROFILE_ALLOC_SAMPLE_RATE", 0.10)
    score_timing = env_bool("CK_PROFILE_SCORE", false)
    timestamp = Dates.format(now(), "yyyymmdd-HHMMSS")
    outdir = abspath(get(ENV, "CK_PROFILE_OUTDIR", joinpath(pwd(), "outputs", "configkit_update_profile_" * timestamp)))
    mkpath(outdir)

    println("Building ConfigKit.update profile models...")
    ctx = build_context()
    cases = build_cases(; include_unsafe)
    target_idx = findfirst(c -> c.name == target, cases)
    target_idx === nothing && error("Unknown CK_PROFILE_TARGET=$target. Available: " * join(getfield.(cases, :name), ", "))

    println("Checking ODEProblem equivalence before timing...")
    equiv = check_equivalence(cases, ctx)
    print_equivalence_human(stdout, equiv)

    println("Profile settings:")
    println("  warmup=$warmup iters=$iters target=$target")
    println("  include_unsafe=$include_unsafe allocs=$run_allocs alloc_sample_rate=$alloc_sample_rate score_timing=$score_timing")
    println("  outdir=$outdir")

    results = [time_case(case, ctx, warmup, iters; score = score_timing) for case in cases]
    print_human_summary(stdout, results)

    open(joinpath(outdir, "summary.csv"), "w") do io
        print_summary(io, results)
    end
    open(joinpath(outdir, "summary.txt"), "w") do io
        print_human_summary(io, results)
    end
    open(joinpath(outdir, "equivalence.csv"), "w") do io
        print_equivalence(io, equiv)
    end
    open(joinpath(outdir, "equivalence.txt"), "w") do io
        print_equivalence_human(io, equiv)
    end
    write_time_dependent_notes(outdir)

    profile_n = measured_iterations(cases[target_idx], iters)
    println("Writing CPU profile for target '$target' with $profile_n calls...")
    write_profile(outdir, cases[target_idx], ctx, profile_n; allocs = run_allocs,
        alloc_sample_rate = alloc_sample_rate, score = score_timing)
    println("Wrote ConfigKit.update profile artifacts to $outdir")
end

main()
