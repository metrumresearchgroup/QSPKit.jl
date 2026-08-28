# Test infusion parameter input metadata validation
using InjecKit
using DifferentialEquations
using DataFrames
using Test

@testset "Infusion Parameter Input Metadata Validation" begin
    @testset "Auto-created infusion parameters have input=true" begin
        # Create a simple system
        @independent_variables t
        @variables C(t)
        @parameters CL V
        D = Differential(t)

        eqs = [D(C) ~ -(CL/V) * C]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 100.0)
        p = Dict(CL => 2.0, V => 10.0)
        tspan = (0.0, 24.0)

        # Create an infusion event - this should work because InjecKit automatically
        # creates infusion parameters with input=true metadata
        df = DataFrame(
            TIME = [0.0, 2.0],
            EVID = [1, 1],
            CMT = [:C, :C],
            AMT = [100.0, missing],
            RATE = [missing, 10.0],  # This is an infusion
            DURATION = [missing, 5.0]
        )

        # This should succeed because we create infusion parameters with input=true
        @test_nowarn prob = ODEProblem(sys, merge(u0, p), tspan, df)
    end

    @testset "Manual infusion parameter without input=true fails validation" begin
        # Create a system with a manual infusion parameter that lacks input=true
        @independent_variables t
        @variables C(t)
        @parameters CL V
        @discretes manual_infusion_rate(t) = 0.0  # Missing [input=true]
        D = Differential(t)

        eqs = [
            D(C) ~ -(CL/V) * C + manual_infusion_rate
        ]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 100.0)
        p = Dict(CL => 2.0, V => 10.0, manual_infusion_rate => 0.0)
        tspan = (0.0, 24.0)

        # Create an infusion event targeting the compartment that uses manual_infusion_rate
        df = DataFrame(
            TIME = [0.0],
            EVID = [1],
            CMT = [:manual_infusion_rate],
            AMT = [missing],
            RATE = [10.0],
            DURATION = [5.0]
        )

        # This should fail because our validation checks that infusion parameters have input=true
        # Note: This test might be tricky to set up correctly - we need to ensure that
        # InjecKit tries to use the existing parameter instead of creating a new one
        @test_throws ErrorException prob = ODEProblem(sys, merge(u0, p), tspan, df)
    end

    @testset "System with proper input=true infusion parameter works" begin
        # Create a system with a properly declared infusion parameter
        @independent_variables t
        @variables C(t)
        @parameters CL V
        @discretes proper_infusion_rate(t) = 0.0 [input=true]
        D = Differential(t)

        eqs = [
            D(C) ~ -(CL/V) * C + proper_infusion_rate
        ]
        @mtkcompile sys = System(eqs, t)

        u0 = Dict(C => 100.0)
        p = Dict(CL => 2.0, V => 10.0, proper_infusion_rate => 0.0)
        tspan = (0.0, 24.0)

        # Create an infusion event
        df = DataFrame(
            TIME = [0.0],
            EVID = [1],
            CMT = [:C],
            AMT = [missing],
            RATE = [10.0],
            DURATION = [5.0]
        )

        # This should work - both auto-created and pre-existing proper parameters should work
        @test_nowarn prob = ODEProblem(sys, merge(u0, p), tspan, df)
    end
end