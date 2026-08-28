# Test repeated dosing with ii and addl
using InjecKit
using DifferentialEquations
using DataFrames
using Test

@testset "Repeated Dosing (ii/addl)" begin
    # Common system setup
    @independent_variables t
    @variables C(t)
    @parameters CL V
    D = Differential(t)

    eqs = [D(C) ~ -(CL/V) * C]
    @mtkcompile sys = System(eqs, t)

    u0 = Dict(C => 0.0)
    p = Dict(CL => 2.0, V => 10.0)
    tspan = (0.0, 100.0)

    @testset "DataFrame with ii and addl" begin
        # Single row with ii=24 and addl=3 should create 4 doses total
        df = DataFrame(
            TIME = [0.0],
            EVID = [1],
            CMT = [:C],
            AMT = [100.0],
            RATE = [0.0],
            II = [24.0],    # interdose interval
            ADDL = [3]      # 3 additional doses
        )

        prob = ODEProblem(sys, merge(u0, p), tspan, df)
        sol = solve(prob, Tsit5())

        # Check concentrations just after each expected dose
        c_after_dose1 = sol(0.1)[1]    # After first dose at t=0
        c_after_dose2 = sol(24.1)[1]   # After second dose at t=24
        c_after_dose3 = sol(48.1)[1]   # After third dose at t=48
        c_after_dose4 = sol(72.1)[1]   # After fourth dose at t=72

        # Each dose should increase concentration
        @test c_after_dose1 > 90.0  # Close to 100
        @test c_after_dose2 > sol(23.9)[1]  # Increase at t=24
        @test c_after_dose3 > sol(47.9)[1]  # Increase at t=48
        @test c_after_dose4 > sol(71.9)[1]  # Increase at t=72

        @test sol.retcode == ReturnCode.Success
    end

    @testset "IEvent with ii and addl" begin
        # Create event with repeated dosing
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, evid=1, ii=24.0, addl=3)
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        # Check concentrations just after each expected dose
        c_after_dose1 = sol(0.1)[1]
        c_after_dose2 = sol(24.1)[1]
        c_after_dose3 = sol(48.1)[1]
        c_after_dose4 = sol(72.1)[1]

        @test c_after_dose1 > 90.0
        @test c_after_dose2 > sol(23.9)[1]
        @test c_after_dose3 > sol(47.9)[1]
        @test c_after_dose4 > sol(71.9)[1]

        @test sol.retcode == ReturnCode.Success
    end

    @testset "Mixed repeated and single doses" begin
        # Combine repeated dosing with individual doses
        df = DataFrame(
            TIME = [0.0, 30.0],
            EVID = [1, 1],
            CMT = [:C, :C],
            AMT = [100.0, 50.0],
            RATE = [0.0, 0.0],
            II = [12.0, missing],   # First has repeated doses, second is single
            ADDL = [2, missing]     # 2 additional doses for first event only
        )

        prob = ODEProblem(sys, merge(u0, p), tspan, df)
        sol = solve(prob, Tsit5())

        # Should have doses at: 0, 12, 24 (from repeated) and 30 (single)
        @test sol(0.1)[1] > 90.0      # After t=0 dose
        @test sol(12.1)[1] > sol(11.9)[1]  # After t=12 dose
        @test sol(24.1)[1] > sol(23.9)[1]  # After t=24 dose
        @test sol(30.1)[1] > sol(29.9)[1]  # After t=30 dose

        @test sol.retcode == ReturnCode.Success
    end

    @testset "Repeated infusions with ii and addl" begin
        # Test repeated infusions
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, rate=10.0, evid=1, ii=24.0, addl=2)
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        # During each infusion period, concentration should increase
        # Infusions should be at t=0-10, t=24-34, t=48-58
        @test sol(5.0)[1] > sol(0.1)[1]    # During first infusion
        @test sol(29.0)[1] > sol(24.1)[1]  # During second infusion
        @test sol(53.0)[1] > sol(48.1)[1]  # During third infusion

        @test sol.retcode == ReturnCode.Success
    end

    @testset "Parameter changes with ii and addl" begin
        # Test repeated parameter changes
        @discretes CL_td(t)
        @parameters V_static
        eqs_param = [D(C) ~ -(CL_td/V_static) * C]
        @mtkcompile sys_param = System(eqs_param, t)

        u0_param = Dict(C => 100.0)
        p_param = Dict(CL_td => 0.1, V_static => 10.0)

        df = DataFrame(
            TIME = [0.0, 4.0],
            EVID = [1, 2],
            CMT = [:C, missing],
            AMT = [100.0, missing],
            II = [missing, 20.0],
            ADDL = [missing, 2],
            CL_td = [missing, 0.5]
        )

        prob = ODEProblem(sys_param, merge(u0_param, p_param), tspan, df)
        sol = solve(prob, Tsit5())

        # CL should change at t=4, 24, 44
        # Higher CL means faster elimination
        slope_before_4 = (sol(3.0)[1] - sol(2.0)[1])
        slope_after_4 = (sol(5.0)[1] - sol(4.0)[1])
        slope_after_24 = (sol(25.0)[1] - sol(24.0)[1])
        slope_after_40 = (sol(41.0)[1] - sol(40.0)[1])

        @test abs(slope_after_24) > abs(slope_before_4)

        @test sol.retcode == ReturnCode.Success
    end

    @testset "Repeated dosing starting at t=0" begin
        # Test that ii/addl works when the first dose is at t=tspan[1]
        df = DataFrame(
            TIME = [0.0],
            EVID = [1],
            CMT = [:C],
            AMT = [100.0],
            RATE = [0.0],
            II = [24.0],
            ADDL = [3]
        )

        # Start simulation at t=0
        tspan_from_zero = (0.0, 100.0)
        u0_zero = Dict(C => 0.0)

        prob = ODEProblem(sys, merge(u0_zero, p), tspan_from_zero, df)
        sol = solve(prob, Tsit5())

        # First dose should be applied to initial conditions
        @test sol(0.0)[1] ≈ 100.0  # Initial condition should include the dose

        # Subsequent doses should still happen
        @test sol(24.1)[1] > sol(23.9)[1]  # Dose at t=24
        @test sol(48.1)[1] > sol(47.9)[1]  # Dose at t=48
        @test sol(72.1)[1] > sol(71.9)[1]  # Dose at t=72

        @test sol.retcode == ReturnCode.Success
    end

    @testset "Repeated dosing with mixed t=0 and later events" begin
        # Test combination of t=0 repeated dosing and other events
        events = [
            ev(time=0.0, cmt=:C, amt=50.0, evid=1, ii=12.0, addl=2),  # Doses at 0, 12, 24
            ev(time=6.0, cmt=:C, amt=25.0, evid=1)  # Single dose at t=6
        ]

        tspan_from_zero = (0.0, 30.0)
        u0_zero = Dict(C => 0.0)

        prob = ODEProblem(sys, merge(u0_zero, p), tspan_from_zero, events)
        sol = solve(prob, Tsit5())

        # First dose from repeated event should be in initial conditions
        @test sol(0.0)[1] ≈ 50.0

        # Check all expected doses
        @test sol(6.1)[1] > sol(5.9)[1]   # Single dose at t=6
        @test sol(12.1)[1] > sol(11.9)[1] # Second dose from repeated at t=12
        @test sol(24.1)[1] > sol(23.9)[1] # Third dose from repeated at t=24

        @test sol.retcode == ReturnCode.Success
    end
end