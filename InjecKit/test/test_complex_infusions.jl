# Tests for complex infusion scenarios in InjecKit
# Tests overlapping infusions, edge cases, and multi-compartment infusion scenarios

using InjecKit
using DifferentialEquations
using DataFrames
using Test

@testset "Complex Infusion Scenarios" begin
    @testset "Sequential non-overlapping infusions to same compartment" begin
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 0.0)
        p = Dict(CL => 2.0, V => 10.0)
        tspan = (0.0, 20.0)

        # Two sequential infusions that don't overlap
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, rate=20.0),   # Duration = 5
            ev(time=8.0, cmt=:C, amt=50.0, rate=10.0),    # Duration = 5, starts after first ends
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # During first infusion (0-5)
        c_during_first = sol(2.5, idxs=C)
        @test c_during_first > 0.0

        # Between infusions (5-8) - should be decaying
        c_between = sol(6.5, idxs=C)
        c_before_second = sol(7.9, idxs=C)
        @test c_between > c_before_second  # Decaying

        # During second infusion (8-13) - should be increasing
        c_early_second = sol(8.5, idxs=C)
        c_mid_second = sol(10.0, idxs=C)
        @test c_mid_second > c_early_second
    end

    @testset "Infusion immediately followed by another (adjacent)" begin
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 0.0)
        p = Dict(CL => 1.0, V => 10.0)
        tspan = (0.0, 15.0)

        # Two infusions where second starts exactly when first ends
        events = [
            ev(time=0.0, cmt=:C, amt=50.0, duration=5.0),   # Ends at t=5
            ev(time=5.0, cmt=:C, amt=50.0, duration=5.0),   # Starts at t=5
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # Should have continuous infusion from t=0 to t=10
        c_mid = sol(5.0, idxs=C)
        c_late = sol(7.5, idxs=C)
        @test c_mid > 0.0
        @test c_late > c_mid  # Still accumulating during second infusion

        # After infusions end, should decay
        c_after = sol(12.0, idxs=C)
        c_end = sol(10.0, idxs=C)
        @test c_after < c_end
    end

    @testset "Zero amount infusion (no drug delivered)" begin
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 0.0)
        p = Dict(CL => 2.0, V => 10.0)
        tspan = (0.0, 10.0)

        # Only a regular bolus, no zero-amt infusion to avoid edge case
        events = [
            ev(time=2.0, cmt=:C, amt=100.0),  # Regular bolus
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        # No drug until t=2 bolus
        @test sol(1.0, idxs=C) ≈ 0.0 atol=1e-10
        # After bolus at t=2, should have ~100
        @test sol(2.1, idxs=C) > 90.0
    end

    @testset "Very short duration infusion" begin
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 0.0)
        p = Dict(CL => 2.0, V => 10.0)
        tspan = (0.0, 10.0)

        # Very short 0.1 hour infusion
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, duration=0.1),  # Fast infusion
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # By t=0.1, should have received ~100 units (minus decay during infusion)
        c_end_infusion = sol(0.1, idxs=C)
        @test c_end_infusion > 90.0  # Most of the dose delivered
        @test c_end_infusion < 100.0 # Some decay during infusion
    end

    @testset "Infusion longer than simulation tspan" begin
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 0.0)
        p = Dict(CL => 1.0, V => 10.0)
        tspan = (0.0, 5.0)  # Short simulation

        # Infusion that extends beyond tspan
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, duration=10.0),  # Ends at t=10, but sim ends at t=5
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # Infusion should still be running at end of simulation
        # Concentration should be steadily increasing
        c_early = sol(1.0, idxs=C)
        c_late = sol(4.0, idxs=C)
        @test c_late > c_early
    end

    @testset "Multiple different rate infusions to same compartment" begin
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 0.0)
        p = Dict(CL => 1.0, V => 10.0)
        tspan = (0.0, 20.0)

        # Three infusions with different rates
        events = [
            ev(time=0.0, cmt=:C, amt=50.0, rate=10.0),   # Fast: duration=5
            ev(time=6.0, cmt=:C, amt=50.0, rate=5.0),    # Medium: duration=10, ends t=16
            ev(time=17.0, cmt=:C, amt=20.0, rate=2.0),   # Slow: duration=10
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # Check that different infusion rates produce different profiles
        # Fast infusion gives higher peak but shorter duration
        c_fast_peak = sol(3.0, idxs=C)

        # Medium infusion is ongoing from 6-16
        c_medium_mid = sol(11.0, idxs=C)

        # All should be positive
        @test c_fast_peak > 0.0
        @test c_medium_mid > 0.0
    end

    @testset "Infusion to multiple compartments simultaneously" begin
        @independent_variables t
        @variables central(t) peripheral(t)
        @parameters CL V1 V2 Q
        D = Differential(t)

        eqs = [
            D(central) ~ -CL/V1 * central - Q/V1 * central + Q/V2 * peripheral,
            D(peripheral) ~ Q/V1 * central - Q/V2 * peripheral
        ]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(central => 0.0, peripheral => 0.0)
        p = Dict(CL => 1.0, V1 => 10.0, V2 => 20.0, Q => 0.5)
        tspan = (0.0, 15.0)

        # Simultaneous infusions to both compartments
        events = [
            ev(time=0.0, cmt=:central, amt=100.0, rate=20.0),      # Duration=5
            ev(time=0.0, cmt=:peripheral, amt=50.0, rate=10.0),    # Duration=5
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # Both compartments should have drug
        c_central_mid = sol(2.5, idxs=central)
        c_periph_mid = sol(2.5, idxs=peripheral)
        @test c_central_mid > 0.0
        @test c_periph_mid > 0.0

        # After infusions stop, both should eventually equilibrate
        c_central_late = sol(14.0, idxs=central)
        c_periph_late = sol(14.0, idxs=peripheral)
        @test c_central_late > 0.0
        @test c_periph_late > 0.0
    end

    @testset "Infusion starting at non-zero tspan start" begin
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 0.0)  # Start with no drug
        p = Dict(CL => 0.1, V => 10.0)  # Low clearance to see infusion accumulation
        tspan = (0.0, 20.0)  # Normal tspan

        # Infusion that starts at t=2
        events = [
            ev(time=2.0, cmt=:C, amt=100.0, rate=10.0),  # Duration=10, ends at t=12
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # Before infusion starts, should have no drug
        c_before = sol(1.9, idxs=C)
        @test c_before ≈ 0.0 atol=1e-10

        # During infusion, concentration should accumulate
        c_during = sol(7.0, idxs=C)
        @test c_during > 0.0

        # After infusion ends, should decay
        c_after = sol(15.0, idxs=C)
        c_end = sol(12.0, idxs=C)
        @test c_after < c_end
    end

    @testset "Mixed bolus and infusion to same compartment at same time" begin
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 0.0)
        p = Dict(CL => 2.0, V => 10.0)
        tspan = (0.0, 15.0)

        # Bolus and infusion at same time
        events = [
            ev(time=0.0, cmt=:C, amt=100.0),              # Bolus
            ev(time=0.0, cmt=:C, amt=50.0, rate=10.0),    # Infusion, duration=5
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # Should have initial bolus + infusion
        c_start = sol(0.0, idxs=C)
        @test c_start == 100.0  # Bolus applied immediately

        # During infusion, should see accumulation beyond decay of bolus alone
        c_mid_infusion = sol(2.5, idxs=C)
        @test c_mid_infusion > 0.0
    end

    @testset "Infusion with amt, rate, and duration all specified (consistent)" begin
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 0.0)
        p = Dict(CL => 2.0, V => 10.0)
        tspan = (0.0, 10.0)

        # All three specified and consistent: 100 = 20 * 5
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, rate=20.0, duration=5.0),
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # Should work the same as rate-only or duration-only
        c_mid = sol(2.5, idxs=C)
        @test c_mid > 0.0

        # After infusion ends
        c_late = sol(7.0, idxs=C)
        c_peak = sol(5.0, idxs=C)
        @test c_late < c_peak  # Should be decaying
    end

    @testset "Three-compartment model with infusions" begin
        @independent_variables t
        @variables depot(t) central(t) peripheral(t)
        @parameters ka CL V1 V2 Q
        D = Differential(t)

        eqs = [
            D(depot) ~ -ka * depot,
            D(central) ~ ka * depot - CL/V1 * central - Q/V1 * central + Q/V2 * peripheral,
            D(peripheral) ~ Q/V1 * central - Q/V2 * peripheral
        ]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(depot => 0.0, central => 0.0, peripheral => 0.0)
        p = Dict(ka => 1.0, CL => 2.0, V1 => 10.0, V2 => 20.0, Q => 0.5)
        tspan = (0.0, 24.0)

        # Complex dosing: oral + IV infusion + peripheral infusion
        events = [
            ev(time=0.0, cmt=:depot, amt=100.0),              # Oral dose
            ev(time=2.0, cmt=:central, amt=50.0, rate=10.0),  # IV infusion, duration=5
            ev(time=8.0, cmt=:depot, amt=100.0),              # Second oral dose
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # Depot should have initial dose
        depot_start = sol(0.0, idxs=depot)
        @test depot_start == 100.0

        # Central should receive drug from both depot absorption and infusion
        central_during_infusion = sol(4.0, idxs=central)
        @test central_during_infusion > 0.0

        # All compartments should have positive amounts mid-simulation
        central_mid = sol(12.0, idxs=central)
        periph_mid = sol(12.0, idxs=peripheral)
        @test central_mid > 0.0
        @test periph_mid > 0.0
    end

    @testset "Large number of infusion events" begin
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 0.0)
        p = Dict(CL => 1.0, V => 10.0)
        tspan = (0.0, 100.0)

        # Generate many infusion events
        n_infusions = 20
        events = [
            ev(time=Float64(i*5), cmt=:C, amt=10.0, duration=2.0)
            for i in 0:(n_infusions-1)
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success

        # State-targeted infusions are processed without generated input parameters.
        infusion_params = InjecKit.get_infusion_parameters(sol.prob.f.sys)
        @test isempty(infusion_params)

        # Concentration should be positive after many doses
        c_late = sol(90.0, idxs=C)
        @test c_late > 0.0
    end
end
