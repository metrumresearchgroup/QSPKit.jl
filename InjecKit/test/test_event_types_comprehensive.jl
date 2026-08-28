# Comprehensive tests for all event types: DataFrame, Vector{IEvent}, Vector{SymbolicDiscreteCallback}
# Tests functionality and correctness across all input formats

using InjecKit
using DifferentialEquations
using DataFrames
using Test

@testset "Comprehensive Event Type Testing" begin
    # Common system setup
    @independent_variables t
    @variables C(t)
    @parameters CL V
    D = Differential(t)

    eqs = [D(C) ~ -(CL/V) * C]
    @mtkcompile sys = System(eqs, t)

    u0 = Dict(C => 0.0)
    p = Dict(CL => 2.0, V => 10.0)
    tspan = (0.0, 10.0)

    @testset "Infusions starting at t=0" begin
        @testset "DataFrame - Rate-based infusion at t=0" begin
            df = DataFrame(
                TIME = [0.0, 5.0],
                EVID = [1, 1],
                CMT = [:C, :C],
                AMT = [missing, missing],
                RATE = [10.0, 0.0],
                DURATION = [1.0, 1.0]
            )

            prob = ODEProblem(sys, merge(u0, p), tspan, df)
            sol = solve(prob, Tsit5())

            c_early = sol(0.1)[1]
            c_mid = sol(2.5)[1]
            c_after_stop = sol(7.5)[1]

            @test c_early > 0.0
            @test c_mid > c_early
            @test c_after_stop < c_mid
            @test sol.retcode == ReturnCode.Success
        end

        @testset "Vector{IEvent} - Rate-based infusion at t=0" begin
            events = [
                ev(time=0.0, cmt=:C, rate=10.0, evid=1, duration=1.0),
                ev(time=5.0, cmt=:C, rate=0.0, evid=1, duration=1.0)
            ]

            prob = ODEProblem(sys, merge(u0, p), tspan, events)
            sol = solve(prob, Tsit5())

            c_early = sol(0.1)[1]
            c_mid = sol(2.5)[1]
            c_after_stop = sol(7.5)[1]

            @test c_early > 0.0
            @test c_mid > c_early
            @test c_after_stop < c_mid
            @test sol.retcode == ReturnCode.Success
        end

        @testset "Vector{SymbolicDiscreteCallback} - Infusion at t=0" begin
            @discretes infusion_rate(t) = 0.0 [input=true]
            eqs_with_infusion = [D(C) ~ infusion_rate - (CL/V) * C]
            @mtkcompile sys_with_infusion = System(eqs_with_infusion, t)

            p_extended = Dict(CL => 2.0, V => 10.0, infusion_rate => 0.0)

            events = [
                MTK.SymbolicDiscreteCallback([0.0], [infusion_rate ~ 10.0]; discrete_parameters=[infusion_rate], iv = t),
                MTK.SymbolicDiscreteCallback([5.0], [infusion_rate ~ 0.0]; discrete_parameters=[infusion_rate], iv = t)
            ]

            prob = ODEProblem(sys_with_infusion, merge(u0, p_extended), tspan, events)
            sol = solve(prob, Tsit5())

            c_early = sol(0.1)[1]
            c_mid = sol(2.5)[1]
            c_after_stop = sol(7.5)[1]

            # Check infusion rate values at different times to debug the issue
            infusion_rate_after = sol(7.5,idxs=infusion_rate)[1]    # Should be 0.0 after callback at t=5

            @test c_early > 0.0
            @test c_mid > c_early
            @test c_after_stop < c_mid
            @test sol.retcode == ReturnCode.Success
        end
    end

    @testset "Duration-based infusions at t=0" begin
        @testset "DataFrame - Duration-based infusion at t=0" begin
            df = DataFrame(
                TIME = [0.0],
                EVID = [1],
                CMT = [:C],
                AMT = [100.0],
                RATE = [missing],
                DURATION = [4.0]
            )

            prob = ODEProblem(sys, merge(u0, p), tspan, df)
            sol = solve(prob, Tsit5())

            c_start = sol(0.1)[1]
            c_mid_infusion = sol(2.0)[1]
            c_end_infusion = sol(3.9)[1]
            c_post_infusion = sol(6.0)[1]

            @test c_start > 0.0
            @test c_mid_infusion > c_start
            @test c_end_infusion > c_mid_infusion
            @test c_post_infusion < c_end_infusion
            @test sol.retcode == ReturnCode.Success
        end

        @testset "Vector{IEvent} - Duration-based infusion at t=0" begin
            events = [ev(time=0.0, cmt=:C, amt=100.0, duration=4.0, evid=1)]

            prob = ODEProblem(sys, merge(u0, p), tspan, events)
            sol = solve(prob, Tsit5())

            c_start = sol(0.1)[1]
            c_mid_infusion = sol(2.0)[1]
            c_end_infusion = sol(3.9)[1]
            c_post_infusion = sol(6.0)[1]

            @test c_start > 0.0
            @test c_mid_infusion > c_start
            @test c_end_infusion > c_mid_infusion
            @test c_post_infusion < c_end_infusion
            @test sol.retcode == ReturnCode.Success
        end
    end

    @testset "Bolus doses at t=0" begin
        @testset "DataFrame - Bolus dose at t=0" begin
            df = DataFrame(
                TIME = [0.0],
                EVID = [1],
                CMT = [:C],
                AMT = [100.0],
                RATE = [0.0]
            )

            prob = ODEProblem(sys, merge(u0, p), tspan, df)
            sol = solve(prob, Tsit5())

            c_immediate = sol(0.0)[1]
            c_later = sol(5.0)[1]

            @test c_immediate ≈ 100.0  # Should start with bolus amount
            @test c_later < c_immediate  # Should decrease due to elimination
            @test sol.retcode == ReturnCode.Success
        end

        @testset "Vector{IEvent} - Bolus dose at t=0" begin
            events = [ev(time=0.0, cmt=:C, amt=100.0, evid=1)]

            prob = ODEProblem(sys, merge(u0, p), tspan, events)
            sol = solve(prob, Tsit5())

            c_immediate = sol(0.0)[1]
            c_later = sol(5.0)[1]

            @test c_immediate ≈ 100.0
            @test c_later < c_immediate
            @test sol.retcode == ReturnCode.Success
        end

        @testset "Vector{SymbolicDiscreteCallback} - Bolus dose at t=0" begin
            events = [MTK.SymbolicDiscreteCallback([0.0], [C ~ Pre(C) + 100.0])]

            prob = ODEProblem(sys, merge(u0, p), tspan, events)
            sol = solve(prob, Tsit5())

            c_immediate = sol(0.0)[1]
            c_later = sol(5.0)[1]

            @test c_immediate ≈ 100.0
            @test c_later < c_immediate
            @test sol.retcode == ReturnCode.Success
        end
    end

    @testset "Parameter changes at t=0" begin
        # Extended system with time-dependent parameter for testing
        @discretes CL_td(t)
        @parameters V_static
        eqs_param = [D(C) ~ -(CL_td/V_static) * C]
        @mtkcompile sys_param = System(eqs_param, t)

        u0_param = Dict(C => 100.0)  # Start with some drug
        p_param = Dict(CL_td => 2.0, V_static => 10.0)

        @testset "DataFrame - Parameter change at t=0" begin
            df = DataFrame(
                TIME = [0.0],
                EVID = [2],
                CMT = [missing],
                AMT = [missing],
                CL_td = [5.0]  # Increase clearance immediately
            )

            prob = ODEProblem(sys_param, merge(u0_param, p_param), tspan, df)
            sol = solve(prob, Tsit5())

            # With higher clearance from t=0, elimination should be faster
            c_early = sol(1.0)[1]
            c_later = sol(5.0)[1]

            @test c_early < 100.0  # Should eliminate faster due to higher CL
            @test c_later < c_early
            @test sol.retcode == ReturnCode.Success
        end

        @testset "Vector{IEvent} - Parameter change at t=0" begin
            events = [ev(time=0.0, evid=2, CL_td=5.0)]

            prob = ODEProblem(sys_param, merge(u0_param, p_param), tspan, events)
            sol = solve(prob, Tsit5())

            c_early = sol(1.0)[1]
            c_later = sol(5.0)[1]

            @test c_early < 100.0
            @test c_later < c_early
            @test sol.retcode == ReturnCode.Success
        end

        @testset "Vector{SymbolicDiscreteCallback} - Parameter change at t=0" begin
            events = [MTK.SymbolicDiscreteCallback([0.0], [CL_td ~ 5.0])]

            prob = ODEProblem(sys_param, merge(u0_param, p_param), tspan, events)
            sol = solve(prob, Tsit5())

            c_early = sol(1.0)[1]
            c_later = sol(5.0)[1]

            @test c_early < 100.0
            @test c_later < c_early
            @test sol.retcode == ReturnCode.Success
        end
    end

    @testset "Multiple events starting at t=0" begin
        @testset "DataFrame - Bolus + Parameter change at t=0" begin
            @discretes CL_td(t)
            @parameters V_static
            eqs_multi = [D(C) ~ -(CL_td/V_static) * C]
            @mtkcompile sys_multi = System(eqs_multi, t)

            # Multiple events at t=0: bolus dose + parameter change
            df = DataFrame(
                TIME = [0.0, 0.0],
                EVID = [1, 2],
                CMT = [:C, missing],
                AMT = [100.0, missing],
                RATE = [0.0, missing],
                CL_td = [missing, 5.0]
            )

            u0_multi = Dict(C => 0.0)
            p_multi = Dict(CL_td => 2.0, V_static => 10.0)

            prob = ODEProblem(sys_multi, merge(u0_multi, p_multi), tspan, df)
            sol = solve(prob, Tsit5())

            c_immediate = sol(0.0)[1]
            c_later = sol(2.0)[1]

            @test c_immediate ≈ 100.0  # Should get bolus
            @test c_later < 50.0  # Should eliminate faster due to higher CL
            @test sol.retcode == ReturnCode.Success
        end

        @testset "Vector{IEvent} - Bolus + Parameter change at t=0" begin
            @discretes CL_td(t)
            @parameters V_static
            eqs_multi = [D(C) ~ -(CL_td/V_static) * C]
            @mtkcompile sys_multi = System(eqs_multi, t)

            events = [
                ev(time=0.0, cmt=:C, amt=100.0, evid=1),
                ev(time=0.0, evid=2, CL_td=5.0)
            ]

            u0_multi = Dict(C => 0.0)
            p_multi = Dict(CL_td => 2.0, V_static => 10.0)

            prob = ODEProblem(sys_multi, merge(u0_multi, p_multi), tspan, events)
            sol = solve(prob, Tsit5())

            c_immediate = sol(0.0)[1]
            c_later = sol(2.0)[1]

            @test c_immediate ≈ 100.0
            @test c_later < 50.0
            @test sol.retcode == ReturnCode.Success
        end

        @testset "Vector{SymbolicDiscreteCallback} - Bolus + Parameter change at t=0" begin
            @discretes CL_td(t)
            @parameters V_static
            eqs_multi = [D(C) ~ -(CL_td/V_static) * C]
            @mtkcompile sys_multi = System(eqs_multi, t)

            events = [
                MTK.SymbolicDiscreteCallback([0.0], [C ~ Pre(C) + 100.0]),
                MTK.SymbolicDiscreteCallback([0.0], [CL_td ~ 5.0])
            ]

            u0_multi = Dict(C => 0.0)
            p_multi = Dict(CL_td => 2.0, V_static => 10.0)

            prob = ODEProblem(sys_multi, merge(u0_multi, p_multi), tspan, events)
            sol = solve(prob, Tsit5())

            c_immediate = sol(0.0)[1]
            c_later = sol(2.0)[1]

            @test c_immediate ≈ 100.0
            @test c_later < 50.0
            @test sol.retcode == ReturnCode.Success
        end
    end

    @testset "Cross-validation: All event types produce similar results" begin
        # Test that all event types produce consistent results for the same scenario
        @discretes infusion_rate(t) = 0.0 [input=true]
        eqs_with_infusion = [D(C) ~ infusion_rate - (CL/V) * C]
        @mtkcompile sys_with_infusion = System(eqs_with_infusion, t)
        p_extended = Dict(CL => 2.0, V => 10.0, infusion_rate => 0.0)
        # Scenario: Infusion starting at t=0, stopping at t=5
        @testset "Rate-based infusion consistency" begin
            # DataFrame version
            df = DataFrame(
                TIME = [0.0, 5.0],
                EVID = [1, 1],
                CMT = [:C, :C],
                AMT = [missing, missing],
                RATE = [10.0, 0.0],
                DURATION = [5.0, 5.0]
            )
            prob_df = ODEProblem(sys, merge(u0, p), tspan, df)
            sol_df = solve(prob_df, Tsit5())

            # IEvent version
            events_mrg = [
                ev(time=0.0, cmt=:C, rate=10.0, evid=1, duration = 5.0),
                ev(time=5.0, cmt=:C, rate=0.0, evid=1, duration = 5.0)
            ]
            prob_mrg = ODEProblem(sys, merge(u0, p), tspan, events_mrg)
            sol_mrg = solve(prob_mrg, Tsit5())

            # SymbolicDiscreteCallback version

            events_sdc = [
                MTK.SymbolicDiscreteCallback([0.0], [infusion_rate ~ 10.0]; discrete_parameters = infusion_rate, iv = t),
                MTK.SymbolicDiscreteCallback([5.0], [infusion_rate ~ 0.0]; discrete_parameters = infusion_rate, iv = t)
            ]
            prob_sdc = ODEProblem(sys_with_infusion, merge(u0, p_extended), tspan, events_sdc)
            sol_sdc = solve(prob_sdc, Tsit5())

            # Test similarity at key time points
            test_times = [0.1, 2.5, 4.9, 7.5]
            for t_test in test_times
                c_df = sol_df(t_test)[1]
                c_mrg = sol_mrg(t_test)[1]
                c_sdc = sol_sdc(t_test)[1]

                @test isapprox(c_df, c_mrg, rtol=0.01)
                @test isapprox(c_df, c_sdc, rtol=0.01)
                @test isapprox(c_mrg, c_sdc, rtol=0.01)
            end
        end

        @testset "Bolus dose consistency" begin
            # DataFrame version
            df = DataFrame(
                TIME = [0.0, 5.0],
                EVID = [1, 1],
                CMT = [:C, :C],
                AMT = [100.0, 50.0],
                RATE = [0.0, 0.0]
            )
            prob_df = ODEProblem(sys, merge(u0, p), tspan, df)
            sol_df = solve(prob_df, Tsit5())

            # IEvent version
            events_mrg = [
                ev(time=0.0, cmt=:C, amt=100.0, evid=1),
                ev(time=5.0, cmt=:C, amt=50.0, evid=1)
            ]
            prob_mrg = ODEProblem(sys, merge(u0, p), tspan, events_mrg)
            sol_mrg = solve(prob_mrg, Tsit5())

            # SymbolicDiscreteCallback version
            events_sdc = [
                MTK.SymbolicDiscreteCallback([0.0], [C ~ Pre(C) + 100.0]),
                MTK.SymbolicDiscreteCallback([5.0], [C ~ Pre(C) + 50.0])
            ]
            prob_sdc = ODEProblem(sys_with_infusion, merge(u0, p_extended), tspan, events_sdc)
            sol_sdc = solve(prob_sdc, Tsit5())

            # Test similarity at key time points
            test_times = [0.0, 2.5, 4.9, 5.0, 7.5]
            for t_test in test_times
                c_df = sol_df(t_test)[1]
                c_mrg = sol_mrg(t_test)[1]
                c_sdc = sol_sdc(t_test)[1]

                @test isapprox(c_df, c_mrg, rtol=0.01)
                @test isapprox(c_df, c_sdc, rtol=0.01)
                @test isapprox(c_mrg, c_sdc, rtol=0.01)
            end
        end
    end
end