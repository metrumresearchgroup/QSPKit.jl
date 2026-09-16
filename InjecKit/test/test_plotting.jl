# Tests for plotting utilities in InjecKit
# Tests the plot_infusion_history function

using InjecKit
using DifferentialEquations
using DataFrames
using Test

@testset "Plotting Utilities" begin
    # Common system setup for infusion testing
    @independent_variables t
    @variables C(t)
    @parameters CL V
    D = Differential(t)

    eqs = [D(C) ~ -(CL/V) * C]
    @mtkcompile sys = System(eqs, t)

    u0 = Dict(C => 0.0)
    p = Dict(CL => 2.0, V => 10.0)
    tspan = (0.0, 10.0)

    @testset "plot_infusion_history with infusion events" begin
        # State-targeted infusions do not generate hidden infusion parameters.
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, rate=10.0),  # Rate-based infusion
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        infusion_params = InjecKit.get_infusion_parameters(sol.prob.f.sys)
        @test isempty(infusion_params)

        result = @test_logs (:warn, r"No infusion parameter found") plot_infusion_history(sol, :C)
        @test result === nothing
    end

    @testset "plot_infusion_history with no infusions (bolus only)" begin
        # Create events with only bolus doses (no infusions)
        events = [
            ev(time=0.0, cmt=:C, amt=100.0),  # Bolus dose
            ev(time=5.0, cmt=:C, amt=50.0),   # Another bolus
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        # No infusion parameters should exist for bolus-only scenario
        infusion_params = InjecKit.get_infusion_parameters(sol.prob.f.sys)
        @test length(infusion_params) == 0

        # plot_infusion_history should warn and return nothing when no infusion parameter found
        result = @test_logs (:warn, r"No infusion parameter found") plot_infusion_history(sol, :C)
        @test result === nothing
    end

    @testset "plot_infusion_history with invalid state variable" begin
        # Create state-targeted infusion events.
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, rate=10.0),
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        # Test with a state variable that doesn't have infusion parameters
        result = @test_logs (:warn, r"No infusion parameter found") plot_infusion_history(sol, :NonExistent)
        @test result === nothing
    end

    @testset "plot_infusion_history with String input" begin
        # Create state-targeted infusion events.
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, rate=10.0),
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        # Test with String instead of Symbol
        result = @test_logs (:warn, r"No infusion parameter found") plot_infusion_history(sol, "C")
        @test result === nothing
    end

    @testset "plot_infusion_history with duration-based infusion" begin
        # Create events with duration-based infusion
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, duration=4.0),  # Duration-based infusion
        ]

        prob = ODEProblem(sys, merge(u0, p), tspan, events)
        sol = solve(prob, Tsit5())

        infusion_params = InjecKit.get_infusion_parameters(sol.prob.f.sys)
        @test isempty(infusion_params)

        result = @test_logs (:warn, r"No infusion parameter found") plot_infusion_history(sol, :C)
        @test result === nothing
    end

    @testset "get_infusion_parameters edge cases" begin
        # Test get_infusion_parameters with system that has no metadata
        @independent_variables t2
        @variables X(t2)
        @parameters k
        simple_eqs = [Differential(t2)(X) ~ -k * X]
        @mtkcompile simple_sys = System(simple_eqs, t2)

        # get_infusion_parameters should return empty collection for a system
        # without user-authored input parameters.
        result = InjecKit.get_infusion_parameters(simple_sys)
        @test isempty(result)
        @test result isa Vector
    end
end
