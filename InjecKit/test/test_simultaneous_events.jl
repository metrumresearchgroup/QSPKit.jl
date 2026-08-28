# Test simultaneous events at the same time point for all event types
using InjecKit
using DifferentialEquations
using DataFrames
using Test

@testset "Simultaneous Events Testing" begin
    # Common system setup
    @independent_variables t
    @variables C(t)
    @parameters CL V
    D = Differential(t)

    @testset "Simultaneous events at t=5" begin
        @testset "Parameter change + Infusion at t=5" begin
            # System with time-dependent clearance
            @discretes CL_td(t)
            @parameters V_static
            eqs = [D(C) ~ -(CL_td/V_static) * C]
            @mtkcompile sys = System(eqs, t)

            u0 = Dict(C => 100.0)  # Start with some drug
            p = Dict(CL_td => 2.0, V_static => 10.0)
            tspan = (0.0, 20.0)

            @testset "DataFrame" begin
                df = DataFrame(
                    TIME = [0.0, 5.0, 5.0, 10.0],  # Two events at t=5
                    EVID = [1, 2, 1, 1],
                    CMT = [:C, missing, :C, :C],
                    AMT = [100.0, missing, missing, missing],
                    RATE = [0.0, missing, 50.0, 0.0],  # Start infusion at t=5
                    DURATION = [missing, missing, 10.0, 10.0],
                    CL_td = [missing, 5.0, missing, missing]  # Change CL at t=5
                )

                prob = ODEProblem(sys, merge(u0, p), tspan, df)
                sol = solve(prob, Tsit5())

                # At t=5, both CL increases and infusion starts
                c_before = sol(4.9)[1]
                c_after = sol(5.5)[1]  # Check slightly later to allow infusion effect
                c_later = sol(8.0)[1]

                # Concentration should increase after t=5 due to infusion
                # despite higher clearance
                @test c_after > c_before || isapprox(c_after, c_before, rtol=0.01)
                @test c_later > c_after  # Should continue increasing during infusion
                @test sol.retcode == ReturnCode.Success
            end

            @testset "Vector{IEvent}" begin
                events = [
                    ev(time=0.0, cmt=:C, amt=100.0, evid=1),
                    ev(time=5.0, evid=2, CL_td=5.0),  # Parameter change
                    ev(time=5.0, cmt=:C, rate=50.0, evid=1, duration = 10.0),  # Start infusion
                ]

                prob = ODEProblem(sys, merge(u0, p), tspan, events)
                sol = solve(prob, Tsit5())

                c_before = sol(4.9)[1]
                c_after = sol(5.5)[1]  # Check slightly later to allow infusion effect
                c_later = sol(8.0)[1]

                @test c_after > c_before || isapprox(c_after, c_before, rtol=0.01)
                @test c_later > c_after
                @test sol.retcode == ReturnCode.Success
            end

            @testset "Vector{SymbolicDiscreteCallback}" begin
                @discretes infusion_rate(t) = 0.0 [input=true]
                eqs_with_inf = [D(C) ~ infusion_rate - (CL_td/V_static) * C]
                @mtkcompile sys_with_inf = System(eqs_with_inf, t)

                p_extended = Dict(CL_td => 2.0, V_static => 10.0, infusion_rate => 0.0, C => 100.0)

                events = [
                    MTK.SymbolicDiscreteCallback([5.0], [CL_td ~ 5.0]; discrete_parameters=[CL_td], iv=t),
                    MTK.SymbolicDiscreteCallback([5.0], [infusion_rate ~ 50.0]; discrete_parameters=[infusion_rate], iv=t),
                    MTK.SymbolicDiscreteCallback([10.0], [infusion_rate ~ 0.0]; discrete_parameters=[infusion_rate], iv=t)
                ]

                prob = ODEProblem(sys_with_inf, p_extended, tspan, events)
                sol = solve(prob, Tsit5())

                c_before = sol(4.9)[1]
                c_after = sol(5.5)[1]  # Check slightly later to allow infusion effect
                c_later = sol(8.0)[1]

                @test c_after > c_before || isapprox(c_after, c_before, rtol=0.01)
                @test c_later > c_after
                @test sol.retcode == ReturnCode.Success
            end
        end

        @testset "Parameter change + Bolus at t=5" begin
            @discretes CL_td(t)
            @parameters V_static
            eqs = [D(C) ~ -(CL_td/V_static) * C]
            @mtkcompile sys = System(eqs, t)

            u0 = Dict(C => 50.0)  # Start with some drug
            p = Dict(CL_td => 2.0, V_static => 10.0)
            tspan = (0.0, 20.0)

            @testset "DataFrame" begin
                df = DataFrame(
                    TIME = [5.0, 5.0],  # Two events at t=5
                    EVID = [2, 1],
                    CMT = [missing, :C],
                    AMT = [missing, 100.0],
                    CL_td = [5.0, missing]  # Change CL and add bolus at t=5
                )

                prob = ODEProblem(sys, merge(u0, p), tspan, df)
                sol = solve(prob, Tsit5())

                c_before = sol(4.99999)[1]
                c_immediate = sol(5.00001)[1]
                c_later = sol(8.0)[1]

                # Should see immediate jump due to bolus
                @test isapprox(c_immediate,c_before + 100.0; rtol = 1e-1)
                # Then faster elimination due to higher CL
                @test c_later < c_immediate
                @test sol.retcode == ReturnCode.Success
            end

            @testset "Vector{IEvent}" begin
                events = [
                    ev(time=5.0, evid=2, CL_td=5.0),      # Parameter change
                    ev(time=5.0, cmt=:C, amt=100.0, evid=1)  # Bolus dose
                ]

                prob = ODEProblem(sys, merge(u0, p), tspan, events)
                sol = solve(prob, Tsit5())

                c_before = sol(4.999999)[1]
                c_immediate = sol(5.000001)[1]
                c_later = sol(8.0)[1]

                @test isapprox(c_immediate,c_before + 100.0; rtol = 1e-1)
                @test c_later < c_immediate
                @test sol.retcode == ReturnCode.Success
            end

            @testset "Vector{SymbolicDiscreteCallback}" begin
                events = [
                    MTK.SymbolicDiscreteCallback([5.0], [CL_td ~ 5.0]; discrete_parameters=[CL_td], iv=t),
                    MTK.SymbolicDiscreteCallback([5.0], [C ~ Pre(C) + 100.0])
                ]

                prob = ODEProblem(sys, merge(u0, p), tspan, events)
                sol = solve(prob, Tsit5())

                c_before = sol(4.999999)[1]
                c_immediate = sol(5.000001)[1]
                c_later = sol(8.0)[1]

                @test isapprox(c_immediate,c_before + 100.0; rtol = 1e-1)
                @test c_later < c_immediate
                @test sol.retcode == ReturnCode.Success
            end
        end

        @testset "Bolus + Infusion at t=5" begin
            eqs = [D(C) ~ -(CL/V) * C]
            @mtkcompile sys = System(eqs, t)

            u0 = Dict(C => 30.0)  # Start with some drug
            p = Dict(CL => 2.0, V => 10.0)
            tspan = (0.0, 20.0)

            @testset "DataFrame" begin
                df = DataFrame(
                    TIME = [5.0, 5.0, 10.0],  # Bolus and infusion start at t=5
                    EVID = [1, 1, 1],
                    CMT = [:C, :C, :C],
                    AMT = [50.0, missing, missing],
                    RATE = [missing, 25.0, missing], # Bolus + start infusion at t=5,
                    DURATION =[missing, 5.0, missing]
                )

                prob = ODEProblem(sys, merge(u0, p), tspan, df)
                sol = solve(prob, Tsit5())

                c_before = sol(4.999999)[1]
                c_immediate = sol(5.000001)[1]
                c_during_inf = sol(7.5)[1]
                c_after_inf = sol(12.0)[1]

                # Should see immediate jump due to bolus
                @test isapprox(c_immediate,c_before + 50.0; rtol = 1e-1)
                # Then increase during infusion
                @test c_during_inf > c_immediate
                # Then decrease after infusion stops
                @test c_after_inf < c_during_inf
                @test sol.retcode == ReturnCode.Success
            end

            @testset "Vector{IEvent}" begin
                events = [
                    ev(time=5.0, cmt=:C, amt=50.0, evid=1),   # Bolus
                    ev(time=5.0, cmt=:C, rate=25.0, evid=1, duration=5),  # Start infusion
                    ev(time=10.0, cmt=:C, rate=0.0, evid=1)   # Stop infusion
                ]

                prob = ODEProblem(sys, merge(u0, p), tspan, events)
                sol = solve(prob, Tsit5())

                c_before = sol(4.99999)[1]
                c_immediate = sol(5.00001)[1]
                c_during_inf = sol(7.5)[1]
                c_after_inf = sol(12.0)[1]

                @test isapprox(c_immediate,c_before + 50.0; rtol = 1e-1)
                @test c_during_inf > c_immediate
                @test c_after_inf < c_during_inf
                @test sol.retcode == ReturnCode.Success
            end

            @testset "Vector{SymbolicDiscreteCallback}" begin
                @discretes infusion_rate(t) = 0.0 [input=true]
                eqs_with_inf = [D(C) ~ infusion_rate - (CL/V) * C]
                @mtkcompile sys_with_inf = System(eqs_with_inf, t)

                u0_extended = Dict(C => 30.0)
                p_extended = Dict(CL => 2.0, V => 10.0, infusion_rate => 0.0)

                events = [
                    MTK.SymbolicDiscreteCallback([5.0], [C ~ Pre(C) + 50.0]),
                    MTK.SymbolicDiscreteCallback([5.0], [infusion_rate ~ 50.0]; discrete_parameters=[infusion_rate], iv=t),
                    MTK.SymbolicDiscreteCallback([10.0], [infusion_rate ~ 0.0]; discrete_parameters=[infusion_rate], iv=t)
                ]

                prob = ODEProblem(sys_with_inf, merge(u0_extended, p_extended), tspan, events)
                sol = solve(prob, Tsit5())

                c_before = sol(4.9999)[1]
                c_immediate = sol(5.0001)[1]
                c_during_inf = sol(7.5)[1]
                c_after_inf = sol(12.0)[1]

                @test isapprox(c_immediate,c_before + 50.0; rtol = 1e-1)
                @test c_during_inf > c_immediate
                @test c_after_inf < c_during_inf
                @test sol.retcode == ReturnCode.Success
            end
        end
    end

    @testset "Multiple events at t=0" begin
        @testset "Parameter change + Infusion at t=0" begin
            @discretes CL_td(t)
            @parameters V_static
            eqs = [D(C) ~ -(CL_td/V_static) * C]
            @mtkcompile sys = System(eqs, t)

            u0 = Dict(C => 0.0)  # Start empty
            p = Dict(CL_td => 2.0, V_static => 10.0)
            tspan = (0.0, 10.0)

            @testset "DataFrame" begin
                df = DataFrame(
                    TIME = [0.0, 0.0, 5.0],
                    EVID = [2, 1, 1],
                    CMT = [missing, :C, :C],
                    AMT = [missing, missing, missing],
                    RATE = [missing, 25.0, 0.0],
                    DURATION = [missing, 5.0, 5.0],
                    CL_td = [5.0, missing, missing]
                )

                prob = ODEProblem(sys, merge(u0, p), tspan, df)
                sol = solve(prob, Tsit5())

                # Should start with infusion rate 10 and CL=5
                c_early = sol(0.1)[1]
                c_mid = sol(2.5)[1]
                c_after_stop = sol(7.0)[1]

                @test c_early > 0.0
                @test c_mid > c_early
                @test c_after_stop < c_mid
                @test sol.retcode == ReturnCode.Success
            end

            @testset "Vector{IEvent}" begin
                events = [
                    ev(time=0.0, evid=2, CL_td=5.0),
                    ev(time=0.0, cmt=:C, rate=25.0, evid=1, duration=5.0),
                    ev(time=5.0, cmt=:C, rate=0.0, evid=1, duration=5.0)
                ]

                prob = ODEProblem(sys, merge(u0, p), tspan, events)
                sol = solve(prob, Tsit5())

                c_early = sol(0.1)[1]
                c_mid = sol(2.5)[1]
                c_after_stop = sol(7.0)[1]

                @test c_early > 0.0
                @test c_mid > c_early
                @test c_after_stop < c_mid
                @test sol.retcode == ReturnCode.Success
            end
        end

        @testset "Bolus + Infusion at t=0" begin
            eqs = [D(C) ~ -(CL/V) * C]
            @mtkcompile sys = System(eqs, t)

            u0 = Dict(C => 0.0)
            p = Dict(CL => 2.0, V => 10.0)
            tspan = (0.0, 10.0)

            @testset "DataFrame" begin
                df = DataFrame(
                    TIME = [0.0, 0.0, 5.0],
                    EVID = [1, 1, 1],
                    CMT = [:C, :C, :C],
                    AMT = [100.0, missing, missing],
                    RATE = [0.0, 25.0, 0.0],
                    DURATION = [missing, 5.0, 5.0]
                )

                prob = ODEProblem(sys, merge(u0, p), tspan, df)
                sol = solve(prob, Tsit5())

                # Should start with bolus (C=100) + infusion
                c_immediate = sol(0.0)[1]
                c_during_inf = sol(2.5)[1]
                c_after_inf = sol(7.0)[1]

                @test c_immediate ≈ 100.0
                @test c_during_inf > c_immediate  # Infusion effect
                @test c_after_inf < c_during_inf   # Only elimination after infusion stops
                @test sol.retcode == ReturnCode.Success
            end

            @testset "Vector{IEvent}" begin
                events = [
                    ev(time=0.0, cmt=:C, amt=100.0, evid=1),
                    ev(time=0.0, cmt=:C, rate=25.0, evid=1, duration=5.0),
                    ev(time=5.0, cmt=:C, rate=0.0, evid=1, duration=5.0)
                ]

                prob = ODEProblem(sys, merge(u0, p), tspan, events)
                sol = solve(prob, Tsit5())

                c_immediate = sol(0.0)[1]
                c_during_inf = sol(2.5)[1]
                c_after_inf = sol(7.0)[1]

                @test c_immediate ≈ 100.0
                @test c_during_inf > c_immediate
                @test c_after_inf < c_during_inf
                @test sol.retcode == ReturnCode.Success
            end

            @testset "Vector{SymbolicDiscreteCallback}" begin
                @discretes infusion_rate(t) = 0.0 [input=true]
                eqs_with_inf = [D(C) ~ infusion_rate - (CL/V) * C]
                @mtkcompile sys_with_inf = System(eqs_with_inf, t)

                u0_extended = Dict(C => 0.0)
                p_extended = Dict(CL => 2.0, V => 10.0, infusion_rate => 0.0)

                events = [
                    MTK.SymbolicDiscreteCallback([0.0], [C ~ Pre(C) + 100.0]),
                    MTK.SymbolicDiscreteCallback([0.0], [infusion_rate ~ 25.0]; discrete_parameters=[infusion_rate], iv=t),
                    MTK.SymbolicDiscreteCallback([5.0], [infusion_rate ~ 0.0]; discrete_parameters=[infusion_rate], iv=t)
                ]

                prob = ODEProblem(sys_with_inf, merge(u0_extended, p_extended), tspan, events)
                sol = solve(prob, Tsit5())

                c_immediate = sol(0.0)[1]
                c_during_inf = sol(2.5)[1]
                c_after_inf = sol(7.0)[1]

                @test c_immediate ≈ 100.0
                @test c_during_inf > c_immediate
                @test c_after_inf < c_during_inf
                @test sol.retcode == ReturnCode.Success
            end
        end
    end

    @testset "Event order independence" begin
        # Test that event order doesn't matter when they occur at the same time
        @discretes CL_td(t)
        @parameters V_static
        eqs = [D(C) ~ -(CL_td/V_static) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 50.0)
        p = Dict(CL_td => 2.0, V_static => 10.0)
        tspan = (0.0, 10.0)

        # Test with different event orders
        @testset "DataFrame - Event order" begin
            # Order 1: Parameter change then bolus
            df1 = DataFrame(
                TIME = [5.0, 5.0],
                EVID = [2, 1],
                CMT = [missing, :C],
                AMT = [missing, 100.0],
                CL_td = [5.0, missing]
            )

            # Order 2: Bolus then parameter change
            df2 = DataFrame(
                TIME = [5.0, 5.0],
                EVID = [1, 2],
                CMT = [:C, missing],
                AMT = [100.0, missing],
                CL_td = [missing, 5.0]
            )

            prob1 = ODEProblem(sys, merge(u0, p), tspan, df1)
            prob2 = ODEProblem(sys, merge(u0, p), tspan, df2)

            sol1 = solve(prob1, Tsit5())
            sol2 = solve(prob2, Tsit5())

            # Results should be identical regardless of order
            test_times = [0.0, 4.9, 5.0, 5.1, 7.5, 10.0]
            for t_test in test_times
                @test isapprox(sol1(t_test)[1], sol2(t_test)[1], rtol=1e-10)
            end
        end

        @testset "Vector{IEvent} - Event order" begin
            # Order 1
            events1 = [
                ev(time=5.0, evid=2, CL_td=5.0),
                ev(time=5.0, cmt=:C, amt=100.0, evid=1)
            ]

            # Order 2
            events2 = [
                ev(time=5.0, cmt=:C, amt=100.0, evid=1),
                ev(time=5.0, evid=2, CL_td=5.0)
            ]

            prob1 = ODEProblem(sys, merge(u0, p), tspan, events1)
            prob2 = ODEProblem(sys, merge(u0, p), tspan, events2)

            sol1 = solve(prob1, Tsit5())
            sol2 = solve(prob2, Tsit5())

            test_times = [0.0, 4.9, 5.0, 5.1, 7.5, 10.0]
            for t_test in test_times
                @test isapprox(sol1(t_test)[1], sol2(t_test)[1], rtol=1e-10)
            end
        end
    end
end