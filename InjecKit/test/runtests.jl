using InjecKit
using ConfigKit
using DifferentialEquations
using DataFrames
using Test
using ModelingToolkitBase
@testset verbose=true "InjecKit.jl Tests" begin


    # Removed Traditional Event Handling tests - superseded by new ODEProblem constructors

    @testset "New ODEProblem Constructors" begin
        # Define a simple PK model
        @parameters k V
        @independent_variables t
        @variables C(t)
        D = Differential(t)

        sys = MTK.System([D(C) ~ -k * C / V], t, name=:simple_pk)
        sys = MTK.mtkcompile(sys)

        u0 = [C => 0.0]
        p = [k => 0.1, V => 10.0]
        tspan = (0.0, 48.0)

        @testset "ODEProblem with DataFrame" begin
            # Test bolus dosing
            dosing_df = DataFrame(
                TIME = [0.0, 8.0, 16.0, 24.0],
                EVID = [1, 1, 1, 1],
                CMT = [:C, :C, :C, :C],
                AMT = [100.0, 100.0, 100.0, 100.0],
                RATE = [0.0, 0.0, 0.0, 0.0]
            )

            # Create problem directly with DataFrame using MTK v10 style
            u0_p = merge(Dict(u0), Dict(p))
            prob = ODEProblem(sys, u0_p, tspan, dosing_df)#; tstops = [8.0, 16.0, 24.0])
            sol = solve(prob, Tsit5());

            @test sol.retcode == SciMLBase.ReturnCode.Success
            @test sol(0.0, idxs=C) == 100.0  # Initial dose
            @test sol(8.1, idxs=C) > sol(7.9, idxs=C)  # Dose at t=8
            @test sol(16.1, idxs=C) > sol(15.9, idxs=C)  # Dose at t=16
            @test sol(24.1, idxs=C) > sol(23.9, idxs=C)  # Dose at t=24
        end

        @testset "ODEProblem with SymbolicDiscreteCallback Vector" begin
            # Create events manually
            events = MTK.SymbolicDiscreteCallback[]
            push!(events, MTK.SymbolicDiscreteCallback([0.0], [C ~ Pre(C) + 100.0]))
            push!(events, MTK.SymbolicDiscreteCallback([12.0], [C ~ Pre(C) + 50.0]))
            push!(events, MTK.SymbolicDiscreteCallback([24.0], [C ~ Pre(C) + 75.0]))

            # Create problem with events vector using MTK v10 style
            u0_p = merge(Dict(u0), Dict(p))
            prob = ODEProblem(sys, u0_p, tspan, events)
            sol = solve(prob, Tsit5())

            @test sol.retcode == SciMLBase.ReturnCode.Success
            @test sol(0.0, idxs=C) == 100.0  # Initial dose
            @test sol(12.1, idxs=C) > sol(11.9, idxs=C)  # Dose at t=12
            @test sol(24.1, idxs=C) > sol(23.9, idxs=C)  # Dose at t=24
        end

        @testset "ODEProblem with IEvent Vector" begin
            # Create events using mrgsolve-style syntax
            events = [
                ev(time=0.0, cmt=:C, amt=100.0),
                ev(time=6.0, cmt=:C, amt=75.0),
                ev(time=12.0, cmt=:C, amt=50.0),
                ev(time=18.0, cmt=:C, amt=100.0)
            ]

            # Create problem with IEvent vector using MTK v10 style
            u0_p = merge(Dict(u0), Dict(p))
            prob = ODEProblem(sys, u0_p, tspan, events)
            sol = solve(prob, Tsit5())

            @test sol.retcode == SciMLBase.ReturnCode.Success
            @test sol(0.0, idxs=C) == 100.0  # Initial dose
            @test sol(6.1, idxs=C) > sol(5.9, idxs=C)  # Dose at t=6
            @test sol(12.1, idxs=C) > sol(11.9, idxs=C)  # Dose at t=12
            @test sol(18.1, idxs=C) > sol(17.9, idxs=C)  # Dose at t=18
        end

        @testset "solve-time simple IEvent runtime fast path" begin
            u0_p = merge(Dict(u0), Dict(p))
            base_prob = ODEProblem(sys, u0_p, tspan)

            t0_plan = InjecKit._try_callback_event_plan(
                base_prob, sys, tspan, [ev(time=0.0, cmt=:C, amt=100.0)]
            )
            @test t0_plan !== nothing
            @test t0_plan.lowering == :runtime_actions
            @test length(t0_plan.initial_actions) == 1
            t0_prob = InjecKit._apply_callback_event_plan(base_prob, t0_plan)
            @test t0_prob[C] == 100.0

            later_plan = InjecKit._try_callback_event_plan(
                base_prob, sys, tspan, [ev(time=1.0, cmt=:C, amt=100.0)]
            )
            @test later_plan !== nothing
            @test later_plan.lowering == :runtime_actions
            @test isempty(later_plan.initial_actions)
            @test later_plan.callback !== nothing

            sol = solve(base_prob, [ev(time=0.0, cmt=:C, amt=100.0)], Tsit5(); saveat=[0.0, 1.0])
            @test sol.retcode == SciMLBase.ReturnCode.Success
            @test sol(0.0, idxs=C) == 100.0

            sol_later = solve(base_prob, [ev(time=1.0, cmt=:C, amt=100.0)], Tsit5(); saveat=[0.9, 1.1])
            @test sol_later.retcode == SciMLBase.ReturnCode.Success
            @test sol_later(1.1, idxs=C) > sol_later(0.9, idxs=C)

            continuous_cb = SciMLBase.ContinuousCallback(
                (u, t, integrator) -> u[1] - 1e6,
                integrator -> nothing)
            @test_throws ErrorException ODEProblem(
                sys, u0_p, tspan, [ev(time=1.0, cmt=:C, amt=100.0)];
                callback=continuous_cb)
            @test_throws ErrorException solve(
                base_prob, [ev(time=1.0, cmt=:C, amt=100.0)], Tsit5();
                callback=continuous_cb)
        end

        @testset "ConfigKit update then solve events uses prepared path" begin
            u0_p = merge(Dict(u0), Dict(p))
            base_prob = ODEProblem(sys, u0_p, tspan)
            events = [
                ev(time=0.0, cmt=:C, amt=100.0),
                ev(time=6.0, cmt=:C, amt=50.0),
            ]
            saveat = [0.0, 6.1, 12.0]

            updated = ConfigKit.update(base_prob, (k=0.2,); strict=false)
            source = ConfigKit.prepared_update_source(updated)
            @test source !== nothing
            @test source.base_prob === base_prob
            @test source.raw_keys == (:k,)
            @test source.raw_values == (0.2,)

            cache_len = length(InjecKit.PREPARED_UPDATE_EVENT_SOLVE_CACHE)
            sol = solve(updated, events, Tsit5(); saveat)
            @test length(InjecKit.PREPARED_UPDATE_EVENT_SOLVE_CACHE) >= cache_len + 1

            expected_12 = 100.0 * exp(-(0.2 / 10.0) * 12.0) +
                50.0 * exp(-(0.2 / 10.0) * 6.0)
            @test sol.retcode == SciMLBase.ReturnCode.Success
            @test sol(12.0, idxs=C) ≈ expected_12 rtol=1e-5

            ConfigKit.with_thread_update_cache(base_prob, (:k,), (0.3,); strict=false) do cached_updated
                cached_source = ConfigKit.prepared_update_source(cached_updated)
                @test cached_source !== nothing
                @test cached_source.base_prob === base_prob
                @test cached_source.raw_keys == (:k,)
                @test cached_source.raw_values == (0.3,)

                cached_sol = solve(cached_updated, events, Tsit5(); saveat)
                expected_cached_12 = 100.0 * exp(-(0.3 / 10.0) * 12.0) +
                    50.0 * exp(-(0.3 / 10.0) * 6.0)
                @test cached_sol.retcode == SciMLBase.ReturnCode.Success
                @test cached_sol(12.0, idxs=C) ≈ expected_cached_12 rtol=1e-5
            end
        end
    end

    @testset "Continuous Infusion with ODEProblem Constructors" begin
        # Define model
        @parameters k V
        @independent_variables t
        @variables C(t)
        D = Differential(t)

        sys = MTK.System([D(C) ~ -k * C / V], t, name=:infusion_pk)
        sys = MTK.mtkcompile(sys)

        u0 = [C => 0.0]
        p = [k => 0.1, V => 10.0]
        tspan = (0.0, 24.0)

        @testset "DataFrame with Continuous Infusions" begin
            # Mixed bolus and infusion dosing
            infusion_df = DataFrame(
                TIME = [0.0, 2.0, 8.0, 12.0],
                EVID = [1, 1, 1, 1],
                CMT = [:C, :C, :C, :C],
                AMT = [100.0, 50.0, 75.0, 100.0],
                RATE = [0.0, 10.0, missing, 0.0],
                DURATION = [missing, missing, 3.0, missing]
            )

            # Create problem with infusion DataFrame using MTK v10 style
            u0_p = merge(Dict(u0), Dict(p))
            prob = ODEProblem(sys, u0_p, tspan, infusion_df; tstops = [2.0, 7.0, 8.0, 12.0])
            sol = solve(prob, Tsit5())

            @test sol.retcode == SciMLBase.ReturnCode.Success
            @test sol(0.0, idxs=C) == 100.0  # Initial bolus
            @test sol(4.0, idxs=C) > sol(2.0, idxs=C)  # During rate-based infusion
            @test sol(10.0, idxs=C) > sol(8.0, idxs=C)  # During duration-based infusion
        end

        @testset "IEvent Vector with Continuous Infusions" begin
            # Create mixed bolus and infusion events
            events = [
                ev(time=0.0, cmt=:C, amt=100.0),  # Bolus
                ev(time=2.0, cmt=:C, amt=50.0, rate=10.0),  # Rate-based infusion
                ev(time=8.0, cmt=:C, amt=75.0, duration=3.0),  # Duration-based infusion
                ev(time=14.0, cmt=:C, amt=50.0)  # Another bolus
            ]

            # Create problem with IEvent vector using MTK v10 style
            u0_p = merge(Dict(u0), Dict(p))
            prob = ODEProblem(sys, u0_p, tspan, events)
            sol = solve(prob, Tsit5())

            @test sol.retcode == SciMLBase.ReturnCode.Success
            @test sol(0.0, idxs=C) == 100.0  # Initial bolus

            # State-targeted infusions are RHS forcing intervals, not generated parameters.
            infusion_params = InjecKit.get_infusion_parameters(sol.prob.f.sys)
            @test isempty(infusion_params)
        end
    end

    @testset "Eventful ODEProblem construction is cold/warm deterministic" begin
        @parameters k V
        @independent_variables t
        @variables C(t)
        D = Differential(t)

        sys = MTK.System([D(C) ~ -k * C / V], t, name=:eventful_cache_regression)
        sys = MTK.mtkcompile(sys)

        u0_p = Dict(C => 0.0, k => 0.1, V => 10.0)
        tspan = (0.0, 12.0)
        events = [
            ev(time=0.0, cmt=:C, amt=100.0),
            ev(time=2.0, cmt=:C, amt=50.0, rate=10.0),
            ev(time=8.0, cmt=:C, amt=75.0, duration=3.0),
        ]

        cache_len_before = lock(InjecKit.CACHE_LOCK) do
            length(InjecKit.EVENT_PLAN_CACHE)
        end
        prob1 = ODEProblem(sys, u0_p, tspan, events)
        prob2 = ODEProblem(sys, u0_p, tspan, events)
        cache_len_after = lock(InjecKit.CACHE_LOCK) do
            length(InjecKit.EVENT_PLAN_CACHE)
        end

        @test cache_len_after == cache_len_before + 1

        sol1 = solve(prob1, Tsit5(); saveat=0.0:1.0:12.0)
        sol2 = solve(prob2, Tsit5(); saveat=0.0:1.0:12.0)
        @test sol1.retcode == SciMLBase.ReturnCode.Success
        @test sol2.retcode == SciMLBase.ReturnCode.Success
        @test [sol1(ti, idxs=C) for ti in 0.0:1.0:12.0] ≈
              [sol2(ti, idxs=C) for ti in 0.0:1.0:12.0] rtol=1e-10 atol=1e-10

        lock(InjecKit.CACHE_LOCK) do
            empty!(InjecKit.EXTENDED_SYSTEM_CACHE)
        end
        prob3 = ODEProblem(sys, u0_p, tspan, events)
        sol3 = solve(prob3, Tsit5(); saveat=0.0:1.0:12.0)
        @test sol3.retcode == SciMLBase.ReturnCode.Success
        @test [sol1(ti, idxs=C) for ti in 0.0:1.0:12.0] ≈
              [sol3(ti, idxs=C) for ti in 0.0:1.0:12.0] rtol=1e-10 atol=1e-10
    end

    @testset "Eventless cached ODEProblem remakes do not mutate cached parameters" begin
        @parameters k
        @independent_variables t
        @variables C(t)
        D = Differential(t)

        sys = MTK.System([D(C) ~ -k * C], t, name=:eventless_cache_regression)
        sys = MTK.mtkcompile(sys)
        c_sys = MTK.parse_variable(sys, "C")
        c0_key = MTK.Initial(c_sys)
        k_sys = MTK.parse_variable(sys, "k")

        prob1 = ODEProblem(sys, Dict(C => 1.0, k => 0.1), (0.0, 4.0), IEvent[])
        prob2 = ODEProblem(sys, Dict(C => 2.0, k => 0.2), (0.0, 4.0), IEvent[])

        @test prob1[c_sys] ≈ 1.0
        @test prob2[c_sys] ≈ 2.0
        @test prob1.ps[c0_key] ≈ 1.0
        @test prob2.ps[c0_key] ≈ 2.0
        @test prob1.ps[k_sys] ≈ 0.1
        @test prob2.ps[k_sys] ≈ 0.2

        prob3 = ODEProblem(sys, Dict(C => 1.0, k => 0.1), (0.0, 4.0), IEvent[])
        @test prob3[c_sys] ≈ 1.0
        @test prob3.ps[c0_key] ≈ 1.0
        @test prob3.ps[k_sys] ≈ 0.1
        @test prob1[c_sys] ≈ 1.0
        @test prob1.ps[c0_key] ≈ 1.0
        @test prob1.ps[k_sys] ≈ 0.1
    end

    @testset "Multi-Compartment with ODEProblem Constructors" begin
        # Two-compartment model
        @parameters ka k12 k21 k10 V1 V2
        @independent_variables t
        @variables depot(t) central(t) peripheral(t)
        D = Differential(t)

        eqs = [
            D(depot) ~ -ka * depot,
            D(central) ~ ka * depot - (k12 + k10) * central / V1 + k21 * peripheral / V2,
            D(peripheral) ~ k12 * central / V1 - k21 * peripheral / V2
        ]

        sys = MTK.System(eqs, t, name=:two_compartment)
        sys = MTK.mtkcompile(sys)

        u0 = [depot => 0.0, central => 0.0, peripheral => 0.0]
        p = [ka => 1.0, k12 => 0.5, k21 => 0.2, k10 => 0.1, V1 => 10.0, V2 => 20.0]
        tspan = (0.0, 48.0)

        @testset "DataFrame Multi-Compartment Dosing" begin
            multi_dose_df = DataFrame(
                TIME = [0.0, 0.0, 8.0, 16.0],
                EVID = [1, 1, 1, 1],
                CMT = [:depot, :central, :depot, :central],
                AMT = [100.0, 50.0, 100.0, 25.0],
                RATE = [0.0, 0.0, 0.0, 0.0]
            )

            u0_p = merge(Dict(u0), Dict(p))
            prob = ODEProblem(sys, u0_p, tspan, multi_dose_df)
            sol = solve(prob, Tsit5())

            @test sol.retcode == SciMLBase.ReturnCode.Success
            @test sol(0.0, idxs=depot) == 100.0  # Depot dose
            @test sol(0.0, idxs=central) == 50.0  # Central dose
            @test sol(8.1, idxs=depot) > sol(7.9, idxs=depot)  # Second depot dose
            @test sol(16.1, idxs=central) > sol(15.9, idxs=central)  # Second central dose
        end

        @testset "IEvent Multi-Compartment with Infusions" begin
            events = [
                ev(time=0.0, cmt=:depot, amt=100.0),  # Oral dose
                ev(time=2.0, cmt=:central, amt=50.0, rate=10.0),  # IV infusion
                ev(time=8.0, cmt=:depot, amt=100.0),  # Another oral dose
                ev(time=10.0, cmt=:peripheral, amt=25.0, duration=2.0)  # Peripheral infusion
            ]

            u0_p = merge(Dict(u0), Dict(p))
            prob = ODEProblem(sys, u0_p, tspan, events)
            sol = solve(prob, Tsit5())

            @test sol.retcode == SciMLBase.ReturnCode.Success
            @test sol(0.0, idxs=depot) == 100.0  # Initial depot dose

            # State-targeted infusions are RHS forcing intervals, not generated parameters.
            infusion_params = InjecKit.get_infusion_parameters(sol.prob.f.sys)
            @test isempty(infusion_params)
        end
    end

    @testset "Parameter Changes with ODEProblem Constructors" begin
        # Model with clearance that can change
        @independent_variables t
        @discretes CL(t)
        @parameters V
        @variables C(t)
        D = Differential(t)

        sys = MTK.System([D(C) ~ -(CL/V) * C], t, name=:varying_clearance)
        sys = MTK.mtkcompile(sys)

        u0 = [C => 0.0]
        p = [CL => 2.5, V => 10.0]
        tspan = (0.0, 48.0)

        @testset "DataFrame with Parameter Changes" begin
            # NONMEM/mrgsolve style: EVID=2 for parameter changes, use parameter column
            mixed_events_df = DataFrame(
                TIME = [0.0, 8.0, 12.0, 16.0, 24.0, 24.0, 32.0],
                EVID = [1, 1, 2, 1, 1, 2, 1],
                CMT = [:C, :C, missing, :C, :C, missing, :C],  # No CMT for parameter changes
                AMT = [100.0, 100.0, missing, 100.0, 100.0, missing, 100.0],  # No AMT for parameter changes
                CL = [missing, missing, 7.5, missing, missing, 10.0, missing]  # Parameter values
            )

            u0_p = merge(Dict(u0), Dict(p))
            prob = ODEProblem(sys, u0_p, tspan, mixed_events_df)
            sol = solve(prob, Tsit5())

            @test sol.retcode == SciMLBase.ReturnCode.Success
            @test sol(0.0, idxs=C) == 100.0  # Initial dose
            # Parameter changes should affect elimination rate
            slope1 = (sol(11.9, idxs=C) - sol(10.0, idxs=C)) / 1.9
            slope2 = (sol(14.0, idxs=C) - sol(12.1, idxs=C)) / 1.9
            @test abs(slope2) > abs(slope1)  # Faster elimination after CL increase
        end
    end

        @testset "DataFrame auto-promotes ordinary source parameter changes" begin
            @independent_variables t
            @parameters CL V
            @variables C(t)
            D = Differential(t)

            sys = MTK.System([D(C) ~ -(CL/V) * C], t, name=:auto_varying_clearance)
            sys = MTK.mtkcompile(sys)

            event_df = DataFrame(
                TIME = [0.0, 5.0],
                EVID = [1, 2],
                CMT = Union{Missing, Symbol}[:C, missing],
                AMT = Union{Missing, Float64}[100.0, missing],
                CL = Union{Missing, Float64}[missing, 8.0],
            )
            dose_df = DataFrame(
                TIME = [0.0],
                EVID = [1],
                CMT = [:C],
                AMT = [100.0],
            )

            u0_p = Dict(C => 0.0, CL => 2.0, V => 10.0)
            prob_change = ODEProblem(sys, u0_p, (0.0, 10.0), event_df)
            prob_nochange = ODEProblem(sys, u0_p, (0.0, 10.0), dose_df)

            cl_params = [p for p in MTK.parameters(prob_change.f.sys) if MTK.getname(p) == :CL]
            @test length(cl_params) == 1
            @test InjecKit._is_time_dependent_parameter(only(cl_params))

            sol_change = solve(prob_change, Tsit5(); saveat=[10.0], abstol=1e-9, reltol=1e-9)
            sol_nochange = solve(prob_nochange, Tsit5(); saveat=[10.0], abstol=1e-9, reltol=1e-9)
            @test sol_change.retcode == SciMLBase.ReturnCode.Success
            @test sol_nochange.retcode == SciMLBase.ReturnCode.Success
            @test sol_change(10.0, idxs=C) < sol_nochange(10.0, idxs=C) / 2
        end

        @testset "EVID=2 rejects dependent parameter targets" begin
            @independent_variables t
            @parameters CLbase scale CL V
            @variables C(t)
            D = Differential(t)

            sys = MTK.System([D(C) ~ -(CL/V) * C], t;
                name=:reject_dependent_clearance,
                bindings=Dict(CL => CLbase * scale))
            sys = MTK.mtkcompile(sys)

            event_df = DataFrame(
                TIME = [5.0],
                EVID = [2],
                CL = [8.0],
            )
            u0_p = Dict(C => 100.0, CLbase => 2.0, scale => 1.0, V => 10.0)
            @test_throws ErrorException ODEProblem(sys, u0_p, (0.0, 10.0), event_df)
        end

    @testset "Error Handling" begin
        @testset "Invalid DataFrame Input" begin
            # Test missing required columns
            bad_df1 = DataFrame(TIME=[0.0], AMT=[100.0])  # Missing EVID
            @parameters k V
            @independent_variables t
            @variables C(t)
            test_sys = MTK.System([Differential(t)(C) ~ -k*C/V], t, name=:test_system)
            test_sys = MTK.mtkcompile(test_sys)

            # Test with invalid DataFrame - should throw error in ODEProblem constructor
            @test_throws ErrorException ODEProblem(test_sys, Dict(), (0.0, 10.0), bad_df1)

            # Test invalid EVID values - should throw error with strict validation
            bad_df2 = DataFrame(TIME=[0.0], EVID=[99], CMT=[:C], AMT=[100.0])
            # Should throw error for invalid EVID values
            u0_p = Dict(C => 0.0, k => 0.1, V => 1.0)
            @test_throws ErrorException ODEProblem(test_sys, u0_p, (0.0, 10.0), bad_df2)
        end

    end

    @testset "Integration with Extended solve Method" begin
        # Test the extended solve method
        @parameters k V
        @independent_variables t
        @variables C(t)
        D = Differential(t)

        sys = MTK.System([D(C) ~ -k * C / V], t, name=:solve_test)
        sys = MTK.mtkcompile(sys)

        u0 = [C => 0.0]
        p = [k => 0.1, V => 10.0]
        tspan = (0.0, 24.0)

        # Create base problem
        prob = ODEProblem(sys, merge(Dict(u0), Dict(p)), tspan)

        # Test solve with DataFrame
        df = DataFrame(
            TIME = [0.0, 6.0, 12.0],
            EVID = [1, 1, 1],
            CMT = [:C, :C, :C],
            AMT = [100.0, 50.0, 75.0]
        )

        sol = solve(prob, df, Tsit5())
        @test sol.retcode == SciMLBase.ReturnCode.Success
        @test sol(0.0, idxs=C) == 100.0

        # Test solve with events
        events = [
            MTK.SymbolicDiscreteCallback([2.0], [C ~ Pre(C) + 50.0]),
            MTK.SymbolicDiscreteCallback([8.0], [C ~ Pre(C) + 25.0])
        ]

        sol2 = solve(prob, events, Tsit5())
        @test sol2.retcode == SciMLBase.ReturnCode.Success
        @test sol2(2.1, idxs=C) > sol2(1.9, idxs=C)
        @test sol2(8.1, idxs=C) > sol2(7.9, idxs=C)

        @testset "IEvent t=0 bolus through solve writes solver u0" begin
            @parameters k dose volume
            @independent_variables t
            @variables concentration(t)=dose / volume
            D = Differential(t)

            sys_ic = MTK.System([D(concentration) ~ -k * concentration], t, name=:solve_t0_initial_condition)
            sys_ic = MTK.mtkcompile(sys_ic)
            prob_ic = ODEProblem(sys_ic, Dict(k => 0.2, dose => 0.0, volume => 10.0), (0.0, 2.0))
            events_ic = [ev(time=0.0, cmt=:concentration, amt=5.0)]

            prob_evt = InjecKit.optimized_ode_constructor(sys_ic,
                InjecKit.extract_u0_p_from_problem(prob_ic), prob_ic.tspan, events_ic)
            @test prob_evt[concentration] ≈ 5.0

            sol_ic = solve(prob_ic, events_ic, Tsit5(); saveat=[0.0, 2.0], abstol=1e-10, reltol=1e-10)
            @test sol_ic.retcode == SciMLBase.ReturnCode.Success
            @test sol_ic(0.0, idxs=concentration) ≈ 5.0 atol=1e-10
            @test sol_ic(2.0, idxs=concentration) ≈ 5.0 * exp(-0.4) rtol=1e-8
        end
    end

    @testset "Input Validation Tests" begin
        include("test_cmt_validation.jl")
    end

    @testset "Parameter Dependency Tests" begin
        include("test_parameter_dependencies.jl")
    end

    include("test_state_set_events.jl")
    include("test_prepared_api.jl")

    @testset "Infusion Parameter Metadata Tests" begin
        include("test_metadata.jl")
    end

    @testset "Comprehensive Event Type Tests" begin
        include("test_event_types_comprehensive.jl")
    end

    @testset "Simultaneous Events Tests" begin
        include("test_simultaneous_events.jl")
    end

    @testset "Repeated Dosing Tests" begin
        include("test_repeated_dosing.jl")
    end

    @testset "Empty and Edge Case Tests" begin
        include("test_empty_edge_cases.jl")
    end

    @testset "Helper Function Tests" begin
        include("test_helper_functions.jl")
    end

    @testset "Complex Infusion Tests" begin
        include("test_complex_infusions.jl")
    end

    @testset "Error Handling Tests" begin
        include("test_error_handling.jl")
    end

    @testset "Event Composition and Regimen Templates" begin
        include("test_event_composition.jl")
    end

    @testset "Large event dataset correctness" begin
        @testset "deterministic bolus table" begin
            n_events = 50
            large_df = DataFrame(
                TIME = collect(range(0.0, 24.0; length=n_events)),
                EVID = fill(1, n_events),
                CMT = fill(:C, n_events),
                AMT = [10.0 + mod(i, 20) for i in 1:n_events],
                RATE = zeros(n_events)  # All bolus doses
            )

            @parameters k V
            @independent_variables t
            @variables C(t)
            sys = MTK.System([Differential(t)(C) ~ -k*C/V], t, name=:performance_test)
            sys = MTK.mtkcompile(sys)

            # Define initial conditions and parameters
            u0 = [C => 0.0]
            p = [k => 0.1, V => 10.0]

            u0_p = merge(Dict(u0), Dict(p))
            prob1 = ODEProblem(sys, u0_p, (0.0, 48.0), large_df)
            prob2 = ODEProblem(sys, u0_p, (0.0, 48.0), large_df)
            sol1 = solve(prob1, Tsit5(); saveat=[0.0, 24.0, 48.0])
            sol2 = solve(prob2, Tsit5(); saveat=[0.0, 24.0, 48.0])

            @test sol1.retcode == SciMLBase.ReturnCode.Success
            @test sol2.retcode == SciMLBase.ReturnCode.Success
            @test sol1(48.0; idxs=C) ≈ sol2(48.0; idxs=C) rtol=1e-10
            @test sol1(24.0; idxs=C) > sol1(0.0; idxs=C)
        end
    end
end
