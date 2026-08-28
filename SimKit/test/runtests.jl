using Test
using SimKit
using DifferentialEquations: Tsit5
using ModelingToolkit
using InjecKit: ev, IEvent
using DataFrames

# ============================================================
# Test model: simple 2-compartment PK
#   depot → central with first-order absorption
#   dDepot/dt = -ka * Depot
#   dCentral/dt = ka * Depot - (CL/V) * Central
# ============================================================

@independent_variables t
D = Differential(t)

@parameters ka=0.5 CL=1.0 V=10.0
@variables Depot(t)=0.0 Central(t)=0.0

eqs = [
    D(Depot) ~ -ka * Depot,
    D(Central) ~ ka * Depot - (CL / V) * Central,
]

@named pk_model = System(eqs, t)
sys = mtkcompile(pk_model)
base_prob = ODEProblem(sys, [], (0.0, 100.0))

# ============================================================
# Tests
# ============================================================

@testset verbose=true "SimKit" begin

    # ============================================================
    # 1. SimContext + run — basic solve
    # ============================================================
    @testset "SimContext + run" begin
        ctx = SimContext(base_prob; solver=Tsit5()) |> simulate(10.0; name=:test)
        @test ctx isa SimContext
        @test length(phases(ctx)) == 1
        @test phases(ctx)[1].name == :test
        @test phases(ctx)[1].duration == 10.0
        @test ctx.sol !== nothing
    end

    @testset "SimContext defaults to problem system" begin
        @named pk_model = System(eqs, t)
        sibling_sys = mtkcompile(pk_model)
        SimKit.ConfigKit.cache_populated_system!(sibling_sys)

        ctx = SimContext(base_prob; solver=Tsit5())
        @test ctx.sys === base_prob.f.sys
        @test ctx.sys !== sibling_sys

        dosed = ctx |>
            events([ev(time=0.0, cmt=ctx.sys.Depot, amt=100.0)]) |>
            simulate(10.0; name=:dosed_from_context_sys, saveat=[0.0, 10.0])
        @test dosed.sol(0.0; idxs=ctx.sys.Depot) ≈ 100.0
    end

    # ============================================================
    # 2. with — parameter updates
    # ============================================================
    @testset "with + simulate" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        ctx1 = SimContext(base_prob; solver=Tsit5()) |>
            with([:ka => 1.0]) |> events(evs) |> simulate(10.0; name=:fast)

        ctx2 = SimContext(base_prob; solver=Tsit5()) |>
            with([:ka => 0.1]) |> events(evs) |> simulate(10.0; name=:slow)

        # Different ka should give different solutions (with drug in depot)
        @test ctx1.sol(ctx1.sol.t[end]) != ctx2.sol(ctx2.sol.t[end])

        ctx3 = SimContext(base_prob; solver=Tsit5()) |>
            with(:ka => 1.0) |> events(evs) |> simulate(10.0; name=:single_pair)
        @test ctx3.sol.retcode == ctx1.sol.retcode
    end

    @testset "start-time state events apply after dependent IC updates" begin
        @parameters a=1.0 k=0.1
        @variables X(t)=a
        @named dep_ic_model = System([D(X) ~ -k * X], t)
        dep_sys = mtkcompile(dep_ic_model)
        dep_prob = ODEProblem(dep_sys, Dict(a => 1.0, k => 0.1), (0.0, 1.0))
        evs = [ev(time=0.0, cmt=X, amt=100.0)]
        ctx = SimContext(dep_prob; solver=Tsit5()) |> events(evs)

        runner = SimRunner(ctx, 1.0; params=(:a, :k))
        sol_runner = runner((a=2.0, k=0.1); saveat=[0.0], abstol=1e-10, reltol=1e-10)
        @test sol_runner(0.0; idxs=X) ≈ 102.0

        sol_direct = simulate_solution(SimKit.with(ctx, (; a=3.0, k=0.1)), 1.0;
            saveat=[0.0], abstol=1e-10, reltol=1e-10)
        @test sol_direct(0.0; idxs=X) ≈ 103.0
    end

    # ============================================================
    # 3. events — event injection
    # ============================================================
    @testset "events + run" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        ctx = SimContext(base_prob; solver=Tsit5()) |>
            events(evs) |> simulate(50.0; name=:dosed)

        @test ctx.sol !== nothing
        @test length(phases(ctx)) == 1
        # Central should have nonzero concentration after dosing
        # (may be near zero if ka is fast and CL/V clears it)
    end

    # ============================================================
    # 4. Phase chaining with u0 transfer
    # ============================================================
    @testset "phase chaining" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        ctx = SimContext(base_prob; solver=Tsit5()) |>
            events(evs) |> simulate(10.0; name=:phase1) |>
            simulate(10.0; name=:phase2)

        @test length(phases(ctx)) == 2
        @test phases(ctx)[1].name == :phase1
        @test phases(ctx)[2].name == :phase2
        # Phase 2 should start from phase 1's end state
        # Central in phase 2 should be decaying (no new dose)
    end

    # ============================================================
    # 5. keep() — param persistence
    # ============================================================
    @testset "keep()" begin
        # Without keep: params cleared after run
        ctx1 = SimContext(base_prob; solver=Tsit5()) |>
            with([:ka => 2.0]) |> simulate(5.0; name=:p1) |>
            simulate(5.0; name=:p2)
        @test isempty(ctx1.params)

        # With keep: params persist
        ctx2 = SimContext(base_prob; solver=Tsit5()) |>
            with([:ka => 2.0]) |> keep() |> simulate(5.0; name=:p1)
        @test !isempty(ctx2.params)
        @test ctx2.params[:ka] == 2.0

        # After one more run without keep, persist resets
        ctx3 = ctx2 |> simulate(5.0; name=:p2)
        @test isempty(ctx3.params)
        @test ctx3.persist == false
    end

    @testset "to_dataframe includes MTK observed variables" begin
        @parameters k_obs=0.1
        @variables X(t)=1.0 X_twice(t) X_shifted(t)

        obs_eqs = [
            X_twice ~ 2 * X,
            X_shifted ~ X_twice + 1,
        ]
        @named observed_model = System([D(X) ~ -k_obs * X], t; observed=obs_eqs)
        sys_obs = mtkcompile(observed_model)
        prob_obs = ODEProblem(sys_obs, [], (0.0, 1.0))

        ctx = SimContext(prob_obs; solver=Tsit5()) |>
              simulate(1.0; name=:observed_df, saveat=[0.0, 1.0])

        df = to_dataframe(ctx)
        df_names = Symbol.(names(df))
        @test :X in df_names
        @test :X_twice in df_names
        @test :X_shifted in df_names
        @test df.X_twice ≈ 2 .* df.X
        @test df.X_shifted ≈ df.X_twice .+ 1

        df_exact = to_dataframe(ctx; vars=[sys_obs.X_shifted])
        @test Symbol.(names(df_exact)) == [:TIME, :X_shifted]
        @test df_exact.X_shifted ≈ df.X_shifted

        df_at = SimKit._sol_to_df_at(ctx.sol, [0.0, 1.0], nothing)
        @test :X_twice in Symbol.(names(df_at))
        @test df_at.X_twice ≈ df.X_twice
    end

    # ============================================================
    # 7. simulate(absolute=true) — cumulative timing
    # ============================================================
    @testset "absolute timing" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        ctx = SimContext(base_prob; solver=Tsit5()) |>
            events(evs) |> simulate(10.0; name=:p1) |>
            simulate(5.0; name=:p2, absolute=true)

        @test phases(ctx)[1].sol.t[end] ≈ 10.0
        @test phases(ctx)[2].sol.t[end] ≈ 15.0  # continues from 10
    end

    @testset "phase cache distinguishes relative and absolute time" begin
        @variables CacheClockState(t)=0.0
        @named cache_clock_model = System([D(CacheClockState) ~ t], t)
        cache_clock_sys = mtkcompile(cache_clock_model)
        cache_clock_prob = ODEProblem(cache_clock_sys, [], (0.0, 2.0))

        disable_cache!()
        enable_cache!()
        seeded = SimContext(cache_clock_prob; solver=Tsit5()) |>
            simulate(1.0; name=:seed)

        # Keep every other solve input identical so only the effective start
        # time can distinguish these cache entries.
        relative_sol = simulate_solution(seeded, 1.0; absolute=false)
        absolute_sol = simulate_solution(seeded, 1.0; absolute=true)

        @test relative_sol.t[[1, end]] == [0.0, 1.0]
        @test absolute_sol.t[[1, end]] == [1.0, 2.0]
        @test relative_sol(1.0; idxs=CacheClockState) ≈ 1.0 atol=1e-8
        @test absolute_sol(2.0; idxs=CacheClockState) ≈ 2.0 atol=1e-8

        disable_cache!()
        enable_cache!()
    end

    # ============================================================
    # 8. branch + result
    # ============================================================
    @testset "branch + result" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        baseline = SimContext(base_prob; solver=Tsit5()) |>
            events(evs) |> simulate(10.0; name=:baseline)

        arms = branch(baseline,
            :fast => with([:ka => 2.0]) >> simulate(10.0),
            :slow => with([:ka => 0.1]) >> simulate(10.0),
        )

        @test arms isa Dict{Symbol, SimContext}
        @test haskey(arms, :fast)
        @test haskey(arms, :slow)
        @test length(phases(arms[:fast])) == 2  # baseline + fast
        @test length(phases(arms[:slow])) == 2  # baseline + slow

        # result on branched arms
        sols = result(arms)
        @test haskey(sols, :fast)
        @test haskey(sols, :slow)
    end

    # ============================================================
    # 9. branch from DataFrame
    # ============================================================
    @testset "branch from DataFrame" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        baseline = SimContext(base_prob; solver=Tsit5()) |>
            events(evs) |> simulate(10.0; name=:baseline)

        conditions = DataFrame(
            arm = [:fast, :slow],
            ka = [2.0, 0.1],
        )
        arms = branch(baseline, conditions; name=:arm, params=[:ka])
        @test haskey(arms, :fast)
        @test haskey(arms, :slow)
    end

    # ============================================================
    # 10. branch_lazy
    # ============================================================
    @testset "branch_lazy" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        baseline = SimContext(base_prob; solver=Tsit5()) |>
            events(evs) |> simulate(10.0; name=:baseline)

        lazy = branch_lazy(baseline,
            :fast => with([:ka => 2.0]) >> simulate(10.0),
            :slow => with([:ka => 0.1]) >> simulate(10.0),
        )

        @test lazy isa LazyBranch
        @test haskey(lazy, :fast)
        @test length(lazy) == 2

        # Access triggers execution
        fast_ctx = lazy[:fast]
        @test fast_ctx isa SimContext
        @test length(phases(fast_ctx)) == 2
    end

    # ============================================================
    # 11. scan — parameter sweeps
    # ============================================================
    @testset "scan" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        baseline = SimContext(base_prob; solver=Tsit5()) |>
            events(evs) |> simulate(10.0; name=:baseline)

        results = scan(baseline, :ka => [0.1, 0.5, 1.0]) do ctx, params
            ctx |> with(params) |> simulate(10.0; name=:scan)
        end

        @test length(results) == 3
        @test results[1].params[:ka] == 0.1
        @test results[2].params[:ka] == 0.5
        @test results[3].params[:ka] == 1.0
        @test all(r -> r.result isa SimContext, results)
    end

    @testset "scan — 2D grid" begin
        baseline = SimContext(base_prob; solver=Tsit5()) |> simulate(10.0; name=:baseline)

        results = scan(baseline, :ka => [0.1, 1.0], :CL => [0.5, 2.0]) do ctx, params
            ctx |> with(params) |> simulate(10.0; name=:scan)
        end

        @test length(results) == 4  # 2 × 2 Cartesian product
    end

    @testset "result — scan phase map" begin
        baseline = SimContext(base_prob; solver=Tsit5())

        results = scan(baseline, :dose => [10.0, 20.0]) do ctx, params
            evs = [ev(time=0.0, cmt=:Depot, amt=params[:dose])]
            ctx |> events(evs) |> simulate(10.0; name=:pk)
        end

        sols = result(results)
        @test Set(keys(sols)) == Set([10.0, 20.0])
        @test sols[10.0] === result(results[1].result, :pk)
        @test sols[20.0] === result(results[2].result, :pk)
    end

    @testset "result — scan inference requires one key" begin
        baseline = SimContext(base_prob; solver=Tsit5())

        results = scan(baseline, :ka => [0.1, 1.0], :CL => [0.5, 2.0]) do ctx, params
            ctx |> with(params) |> simulate(10.0; name=:scan)
        end

        @test_throws ArgumentError result(results)
    end

    # ============================================================
    # 12. result — specific phase access
    # ============================================================
    @testset "result — phase access" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        ctx = SimContext(base_prob; solver=Tsit5()) |>
            events(evs) |> simulate(10.0; name=:phase1) |>
            simulate(5.0; name=:phase2) |>
            simulate(5.0; name=:phase1)  # duplicate name

        r = result(ctx)
        @test haskey(r, :phase1)  # last phase1
        @test haskey(r, :phase2)

        # Specific phase by name
        sol = result(ctx, :phase2)
        @test sol !== nothing

        # Specific phase by index
        sol1 = result(ctx, :phase1, 1)  # first :phase1
        sol2 = result(ctx, :phase1, 2)  # second :phase1
        @test sol1 !== sol2
    end

    @testset "to_dataframe accepts ODESolution and result dictionaries" begin
        ctx = SimContext(base_prob; solver=Tsit5()) |>
            simulate(10.0; name=:baseline, saveat=[0.0, 10.0]) |>
            simulate(5.0; name=:followup, absolute=true, saveat=[10.0, 15.0])

        df_sol = to_dataframe(ctx.sol)
        @test df_sol isa DataFrame
        @test Symbol.(names(df_sol)) == [:TIME, :Depot, :Central]
        @test df_sol.TIME == ctx.sol.t

        df_result = to_dataframe(result(ctx))
        @test df_result isa DataFrame
        @test :SIM_NAME in Symbol.(names(df_result))
        @test Set(df_result.SIM_NAME) == Set(["baseline", "followup"])
    end

    # ============================================================
    # 13. simulate — normal operation
    # ============================================================
    @testset "simulate basic" begin
        ctx = SimContext(base_prob; solver=Tsit5()) |> simulate(10.0; name=:ok)
        @test ctx isa SimContext

        # Curried form
        ctx2 = SimContext(base_prob; solver=Tsit5()) |> simulate(10.0)
        @test ctx2 isa SimContext
    end

    # ============================================================
    # 14. SimulationError context
    # ============================================================
    @testset "SimulationError" begin
        err = SimulationError(:test_phase, Dict(:k => 1.0), IEvent[], ErrorException("boom"))
        @test err.phase_name == :test_phase
        @test err.params[:k] == 1.0
        buf = IOBuffer()
        showerror(buf, err)
        s = String(take!(buf))
        @test occursin("test_phase", s)
        @test occursin("boom", s)
    end

    # ============================================================
    # 15-18. Cache tests
    # ============================================================
    @testset "cache" begin
        enable_cache!()

        @testset "identical inputs hit cache" begin
            evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
            ctx1 = SimContext(base_prob; solver=Tsit5()) |>
                events(evs) |> simulate(10.0; name=:cached)
            ctx2 = SimContext(base_prob; solver=Tsit5()) |>
                events(evs) |> simulate(10.0; name=:cached)
            # Solutions should be identical (same object from cache)
            @test ctx1.sol === ctx2.sol
        end

        @testset "different inputs miss cache" begin
            evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
            ctx1 = SimContext(base_prob; solver=Tsit5()) |>
                with([:ka => 1.0]) |> events(evs) |> simulate(10.0; name=:a)
            ctx2 = SimContext(base_prob; solver=Tsit5()) |>
                with([:ka => 2.0]) |> events(evs) |> simulate(10.0; name=:b)
            @test ctx1.sol !== ctx2.sol
        end

        @testset "different problem misses cache" begin
            evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
            prob2 = ODEProblem(sys, [Depot => 10.0, Central => 0.0], (0.0, 100.0))
            ctx1 = SimContext(base_prob; solver=Tsit5()) |>
                events(evs) |> simulate(10.0; name=:base_problem)
            ctx2 = SimContext(prob2; solver=Tsit5()) |>
                events(evs) |> simulate(10.0; name=:changed_problem)
            @test ctx1.sol !== ctx2.sol
        end

        @testset "disable_cache!" begin
            evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
            disable_cache!()
            ctx1 = SimContext(base_prob; solver=Tsit5()) |>
                events(evs) |> simulate(10.0; name=:no_cache)
            ctx2 = SimContext(base_prob; solver=Tsit5()) |>
                events(evs) |> simulate(10.0; name=:no_cache)
            # With cache disabled, solutions are different objects
            @test ctx1.sol !== ctx2.sol
            enable_cache!()
        end
    end

    # ============================================================
    # 19. Pipeline inspection
    # ============================================================
    @testset "Pipeline" begin
        p = with([:ka => 1.0]) >> events([ev(cmt=:Depot, amt=100.0)]) >> simulate(10.0)
        @test p isa Pipeline
        @test length(p.stages) == 3

        # show
        buf = IOBuffer()
        show(buf, p)
        @test occursin("Pipeline", String(take!(buf)))

        # callable
        ctx = SimContext(base_prob; solver=Tsit5())
        result_ctx = p(ctx)
        @test result_ctx isa SimContext
        @test length(phases(result_ctx)) == 1
    end

    # ============================================================
    # 20. Display
    # ============================================================
    @testset "display" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        ctx = SimContext(base_prob; solver=Tsit5()) |>
            events(evs) |> simulate(10.0; name=:p1) |>
            simulate(5.0; name=:p2)

        # Compact show
        buf = IOBuffer()
        show(buf, ctx)
        s = String(take!(buf))
        @test occursin("2 phases", s)

        # Detailed show
        buf = IOBuffer()
        show(buf, MIME"text/plain"(), ctx)
        s = String(take!(buf))
        @test occursin("p1", s)
        @test occursin("p2", s)
    end

    # ============================================================
    # 21. Time helpers
    # ============================================================
    @testset "time helpers" begin
        @test weeks(2) == 14.0
        @test days(3) == 3.0
        @test hours(24) == 1.0
        @test weeks(1) == 7.0
        @test hours(12) ≈ 0.5
    end

    # ============================================================
    # 22. inspect
    # ============================================================
    @testset "inspect" begin
        evs = [ev(time=0.0, cmt=:Depot, amt=100.0)]
        ctx = SimContext(base_prob; solver=Tsit5()) |>
            events(evs) |> simulate(10.0; name=:p1)

        # inspect shouldn't error — just verify it runs without throwing
        inspect(ctx)
        @test true  # if we get here, inspect didn't throw
    end

    # ============================================================
    # 23. Complex pipeline — multi-phase
    # ============================================================
    @testset "complex pipeline" begin
        initial = [ev(time=0.0, cmt=:Depot, amt=2.75)]
        repeating = [ev(time=0.0, cmt=:Depot, amt=0.8)]
        final_probe = [ev(time=0.0, cmt=:Depot, amt=0.35)]

        ctx = SimContext(base_prob; solver=Tsit5()) |>
            with([:ka => 0.5]) |> events(initial) |> keep() |>
            simulate(3.0; name=:initialize) |>
            events(repeating) |> keep() |> simulate(5.0; name=:repeat) |>
            simulate(2.5; name=:observe) |>
            events(final_probe) |> simulate(4.0; name=:final_probe)

        @test length(phases(ctx)) == 4
        @test phases(ctx)[1].name == :initialize
        @test phases(ctx)[2].name == :repeat
        @test phases(ctx)[3].name == :observe
        @test phases(ctx)[4].name == :final_probe
        @test phases(ctx)[1].duration == 3.0
        @test phases(ctx)[2].duration == 5.0
        @test phases(ctx)[3].duration == 2.5
        @test phases(ctx)[4].duration == 4.0

        # After the non-persistent final phase, staged parameters are cleared.
        @test isempty(ctx.params)
    end

    # ============================================================
    # Subject/Population — multi-subject data
    # ============================================================

    @testset "Subject/Population" begin

        # --------------------------------------------------
        # Path 1: NONMEM event-level data
        # --------------------------------------------------
        @testset "Population from NONMEM data" begin
            df = DataFrame(
                ID   = [1, 1, 1, 1, 2, 2, 2, 2],
                TIME = [0.0, 1.0, 4.0, 12.0, 0.0, 2.0, 6.0, 24.0],
                EVID = [1, 0, 0, 0, 1, 0, 0, 0],
                AMT  = [100.0, 0.0, 0.0, 0.0, 200.0, 0.0, 0.0, 0.0],
                CMT  = [:Depot, :Depot, :Depot, :Depot, :Depot, :Depot, :Depot, :Depot],
                DV   = [0.0, 5.1, 8.2, 3.1, 0.0, 9.8, 12.1, 2.0],
            )

            pop = Population(df; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT)

            @test pop isa Population
            @test length(pop) == 2

            # Subject 1
            s1 = pop[1]
            @test s1.id == 1
            @test length(s1.events) == 1
            @test s1.events[1].amt == 100.0
            @test s1.obs_times == [1.0, 4.0, 12.0]
            @test s1.obs_values == [5.1, 8.2, 3.1]
            @test isempty(keys(s1.covariates))

            # Subject 2
            s2 = pop[2]
            @test s2.id == 2
            @test length(s2.events) == 1
            @test s2.events[1].amt == 200.0
            @test s2.obs_times == [2.0, 6.0, 24.0]
            @test s2.obs_values == [9.8, 12.1, 2.0]
        end

        @testset "Population from NONMEM data — BLQ censoring" begin
            df = DataFrame(
                ID   = [1, 1, 1, 1],
                TIME = [0.0, 1.0, 2.0, 3.0],
                EVID = [1, 0, 0, 0],
                AMT  = [100.0, 0.0, 0.0, 0.0],
                CMT  = [:Depot, :Depot, :Depot, :Depot],
                DV   = Union{Missing, Float64}[missing, 4.2, missing, 8.0],
                BLQ  = [0, 0, 1, 0],
                LLOQ = [0.5, 0.5, 0.5, 0.5],
                WT   = [70.0, 70.0, 70.0, 70.0],
            )

            pop = Population(df; id=:ID, time=:TIME, dv=:DV, amt=:AMT,
                             evid=:EVID, cmt=:CMT, censoring=(:BLQ => :left),
                             loq=:LLOQ)
            s = only(pop)
            @test s.obs_times == [1.0, 2.0, 3.0]
            @test s.obs_values == [4.2, 0.5, 8.0]
            @test s.obs_censors == [:none, :left, :none]
            @test isnan(s.obs_limits[1])
            @test s.obs_limits[2] == 0.5
            @test isnan(s.obs_limits[3])
            @test !haskey(s.covariates, :BLQ)
            @test !haskey(s.covariates, :LLOQ)
            @test haskey(s.covariates, :WT)
        end

        @testset "Population from NONMEM — simulation-only (no DV)" begin
            df = DataFrame(
                ID   = [1, 1, 2, 2],
                TIME = [0.0, 24.0, 0.0, 24.0],
                EVID = [1, 1, 1, 1],
                AMT  = [100.0, 100.0, 200.0, 200.0],
                CMT  = [:Depot, :Depot, :Depot, :Depot],
            )

            pop = Population(df; id=:ID, time=:TIME, amt=:AMT, evid=:EVID, cmt=:CMT)

            @test length(pop) == 2
            @test pop[1].obs_values === nothing
            @test length(pop[1].events) == 2
            @test isempty(pop[1].obs_times)
        end

        @testset "Population from NONMEM — with parameters" begin
            df = DataFrame(
                ID   = [1, 1, 2, 2],
                TIME = [0.0, 12.0, 0.0, 12.0],
                EVID = [1, 0, 1, 0],
                AMT  = [100.0, 0.0, 100.0, 0.0],
                CMT  = [:Depot, :Depot, :Depot, :Depot],
                DV   = [0.0, 5.0, 0.0, 8.0],
                WT   = [70.0, 70.0, 85.0, 85.0],
                AGE  = [40, 40, 55, 55],
            )

            pop = Population(df; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                             parameters=[:WT, :AGE])

            @test pop[1].covariates.WT == 70.0
            @test pop[1].covariates.AGE == 40
            @test pop[2].covariates.WT == 85.0
            @test pop[2].covariates.AGE == 55
        end

        @testset "Population preserves EVID=2 parameter changes" begin
            df = DataFrame(
                ID = [1, 1, 1],
                TIME = [0.0, 5.0, 6.0],
                EVID = [1, 2, 0],
                AMT = Union{Missing, Float64}[100.0, missing, 0.0],
                CMT = Union{Missing, Symbol}[:Depot, missing, :Depot],
                DV = Union{Missing, Float64}[missing, missing, 2.5],
                BW = [70.0, 80.0, 80.0],
            )

            pop = Population(df; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT)
            s = only(pop)
            ev2 = only(filter(e -> e.evid == 2, s.events))

            @test haskey(ev2.param_changes, :BW)
            @test ev2.param_changes[:BW] ≈ 80.0
            @test !haskey(ev2.param_changes, :DV)
            @test !haskey(ev2.param_changes, :AMT)
            @test s.obs_times == [6.0]
            @test s.obs_values == [2.5]
        end

        @testset "Population — parameters=:auto" begin
            df = DataFrame(
                ID   = [1, 2],
                TIME = [0.0, 0.0],
                EVID = [1, 1],
                AMT  = [100.0, 100.0],
                CMT  = [:Depot, :Depot],
                WT   = [70.0, 85.0],
                SEX  = [0, 1],
            )

            pop = Population(df; id=:ID, time=:TIME, amt=:AMT, evid=:EVID, cmt=:CMT,
                             parameters=:auto)

            # WT and SEX should be detected (not ID, TIME, EVID, AMT, CMT)
            @test haskey(pop[1].covariates, :WT)
            @test haskey(pop[1].covariates, :SEX)
            @test pop[1].covariates.WT == 70.0
            @test pop[2].covariates.SEX == 1
        end

        # --------------------------------------------------
        # Path 2: idata-style (shared events)
        # --------------------------------------------------
        @testset "Population from idata + shared events" begin
            idata_df = DataFrame(
                ID  = [1, 2, 3],
                WT  = [70.0, 85.0, 60.0],
                AGE = [40, 55, 30],
            )

            shared_events = [ev(time=0.0, cmt=:Depot, amt=100.0)]

            pop = Population(idata_df; id=:ID, parameters=[:WT, :AGE], events=shared_events)

            @test length(pop) == 3
            @test pop[1].id == 1
            @test pop[2].id == 2
            @test pop[3].id == 3

            # Each subject gets a copy of the shared events
            @test length(pop[1].events) == 1
            @test pop[1].events[1].amt == 100.0
            @test length(pop[2].events) == 1

            # Covariates from idata
            @test pop[1].covariates.WT == 70.0
            @test pop[3].covariates.AGE == 30

            # No observations for idata-style
            @test pop[1].obs_values === nothing
            @test isempty(pop[1].obs_times)
        end

        # --------------------------------------------------
        # Path 3: Combined (data + idata)
        # --------------------------------------------------
        @testset "Population from data + idata combined" begin
            data_df = DataFrame(
                ID   = [1, 1, 2, 2],
                TIME = [0.0, 12.0, 0.0, 12.0],
                EVID = [1, 0, 1, 0],
                AMT  = [100.0, 0.0, 200.0, 0.0],
                CMT  = [:Depot, :Depot, :Depot, :Depot],
                DV   = [0.0, 5.0, 0.0, 8.0],
            )

            idata_df = DataFrame(
                ID  = [1, 2],
                WT  = [70.0, 85.0],
                AGE = [40, 55],
            )

            pop = Population(data_df; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                             idata=idata_df, parameters=[:WT, :AGE])

            @test length(pop) == 2

            # Events from data
            @test length(pop[1].events) == 1
            @test pop[1].events[1].amt == 100.0

            # Observations from data
            @test pop[1].obs_times == [12.0]
            @test pop[1].obs_values == [5.0]

            # Covariates from idata
            @test pop[1].covariates.WT == 70.0
            @test pop[2].covariates.AGE == 55
        end

        @testset "Population — idata missing subject errors" begin
            data_df = DataFrame(
                ID   = [1, 1, 2, 2],
                TIME = [0.0, 12.0, 0.0, 12.0],
                EVID = [1, 0, 1, 0],
                AMT  = [100.0, 0.0, 200.0, 0.0],
                CMT  = [:Depot, :Depot, :Depot, :Depot],
                DV   = [0.0, 5.0, 0.0, 8.0],
            )

            # idata missing subject 2
            idata_df = DataFrame(ID=[1], WT=[70.0])

            @test_throws ErrorException Population(data_df;
                id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                idata=idata_df, parameters=[:WT])
        end

        # --------------------------------------------------
        # Validation errors
        # --------------------------------------------------
        @testset "Population — validation" begin
            # Missing ID column
            df = DataFrame(TIME=[0.0], EVID=[1], AMT=[100.0], CMT=[:Depot])
            @test_throws ErrorException Population(df; id=:ID, time=:TIME, evid=:EVID)

            # Must provide time+evid or events
            df = DataFrame(ID=[1], WT=[70.0])
            @test_throws ErrorException Population(df; id=:ID)

            # Missing covariate column
            df = DataFrame(ID=[1], TIME=[0.0], EVID=[1], AMT=[100.0], CMT=[:Depot])
            @test_throws ErrorException Population(df; id=:ID, time=:TIME, evid=:EVID,
                                                    amt=:AMT, cmt=:CMT, parameters=[:WT])
        end

        # --------------------------------------------------
        # Display
        # --------------------------------------------------
        @testset "Subject/Population display" begin
            s = Subject(1, [ev(time=0.0, cmt=:Depot, amt=100.0)], [1.0, 4.0], [5.0, 8.0],
                        (WT=70.0, AGE=40))
            str = sprint(show, s)
            @test occursin("id=1", str)
            @test occursin("1 event", str)
            @test occursin("2 obs", str)

            pop = [s, Subject(2, IEvent[], Float64[], nothing, NamedTuple())]
            str = sprint(show, MIME"text/plain"(), pop)
            @test occursin("2 subjects", str)
        end

        # --------------------------------------------------
        # subjects() pipeline verb
        # --------------------------------------------------
        @testset "subjects() pipeline" begin
            df = DataFrame(
                ID   = [1, 1, 2, 2],
                TIME = [0.0, 0.0, 0.0, 0.0],
                EVID = [1, 0, 1, 0],
                AMT  = [100.0, 0.0, 200.0, 0.0],
                CMT  = [:Depot, :Depot, :Depot, :Depot],
                DV   = [0.0, 0.0, 0.0, 0.0],
            )

            pop = Population(df; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT)

            # subjects() returns PipelineStep
            fn = subjects(pop)
            @test fn isa PipelineStep

            # Apply to a SimContext — stages events per subject
            ctx = SimContext(base_prob; solver=Tsit5())
            results = subjects(ctx, pop; parallel=false)

            @test results isa PopulationResult
            @test length(results) == 2
            @test haskey(results, 1)
            @test haskey(results, 2)

            # Each result is a SimContext with dosing events staged
            @test length(results[1].events) == 1
            @test results[1].events[1].amt == 100.0
            @test length(results[2].events) == 1
            @test results[2].events[1].amt == 200.0

            # Dict iteration still works (backward compat)
            ids_seen = Set()
            for (id, ctx_subj) in results
                push!(ids_seen, id)
            end
            @test ids_seen == Set([1, 2])
        end

        @testset "subjects() with parameters" begin
            idata_df = DataFrame(
                ID  = [1, 2],
                WT  = [70.0, 85.0],
            )

            shared_events = [ev(time=0.0, cmt=:Depot, amt=100.0)]
            pop = Population(idata_df; id=:ID, parameters=[:WT], events=shared_events)

            ctx = SimContext(base_prob; solver=Tsit5())
            results = subjects(ctx, pop; parallel=false)

            # Covariates should be staged as parameter overrides
            @test results[1].params[:WT] == 70.0
            @test results[2].params[:WT] == 85.0
        end
    end

    # ============================================================
    # Population simulation pipeline
    # ============================================================

    @testset "Population pipeline" begin

        # Build a population with observations
        pop_df = DataFrame(
            ID   = [1, 1, 1, 2, 2, 2],
            TIME = [0.0, 4.0, 12.0, 0.0, 4.0, 12.0],
            EVID = [1, 0, 0, 1, 0, 0],
            AMT  = [100.0, 0.0, 0.0, 200.0, 0.0, 0.0],
            CMT  = [:Depot, :Depot, :Depot, :Depot, :Depot, :Depot],
            DV   = [0.0, 5.1, 3.2, 0.0, 9.8, 5.1],
            ka   = [0.5, 0.5, 0.5, 0.8, 0.8, 0.8],
        )
        pop = Population(pop_df; id=:ID, time=:TIME, dv=:DV, amt=:AMT, evid=:EVID, cmt=:CMT,
                         parameters=[:ka])

        @testset "full pipeline: subjects |> simulate() |> to_dataframe" begin
            pr = SimContext(base_prob; solver=Tsit5()) |> subjects(pop) |> simulate()
            @test pr isa PopulationResult
            @test length(pr.contexts) == 2
            @test isempty(pr.errors)

            # Both subjects should be simulated (have phases)
            @test !isempty(pr.contexts[1].phases)
            @test !isempty(pr.contexts[2].phases)
        end

        @testset "simulate with explicit duration" begin
            pr = SimContext(base_prob; solver=Tsit5()) |> subjects(pop) |> simulate(24.0)
            @test pr isa PopulationResult
            @test pr.contexts[1].phases[end].duration == 24.0
            @test pr.contexts[2].phases[end].duration == 24.0
        end

        @testset "to_dataframe — full output" begin
            df_out = SimContext(base_prob; solver=Tsit5()) |> subjects(pop) |> simulate(24.0) |> to_dataframe()
            @test df_out isa DataFrame
            @test :ID in Symbol.(names(df_out))
            @test :TIME in Symbol.(names(df_out))
            # Should have rows for both subjects
            @test length(unique(df_out.ID)) == 2
        end

        @testset "to_dataframe — obsonly" begin
            df_out = SimContext(base_prob; solver=Tsit5()) |> subjects(pop) |> simulate(24.0) |>
                     to_dataframe(; obsonly=true)
            @test df_out isa DataFrame
            # Should only have observation times (4.0 and 12.0 per subject = 4 rows)
            @test nrow(df_out) == 4
            @test :DV in Symbol.(names(df_out))
            @test sort(df_out.TIME) == [4.0, 4.0, 12.0, 12.0]
        end

        @testset "to_dataframe — carry_out" begin
            df_out = SimContext(base_prob; solver=Tsit5()) |> subjects(pop) |> simulate(24.0) |>
                     to_dataframe(; obsonly=true, carry_out=[:ka])
            @test :ka in Symbol.(names(df_out))
            # ka values should match subjects
            s1_rows = filter(r -> r.ID == 1, df_out)
            s2_rows = filter(r -> r.ID == 2, df_out)
            @test all(s1_rows.ka .== 0.5)
            @test all(s2_rows.ka .== 0.8)
        end

        @testset "to_dataframe — direct call (not curried)" begin
            pr = SimContext(base_prob; solver=Tsit5()) |> subjects(pop) |> simulate(24.0)
            df_out = to_dataframe(pr; obsonly=true)
            @test nrow(df_out) == 4
        end
    end

end
