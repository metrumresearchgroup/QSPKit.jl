using InjecKit
using DifferentialEquations
using DataFrames
using Test

@testset "CMT and Parameter Column Validation" begin

    @testset "CMT Validation for Dosing Events" begin
        # Define model with CL as parameter
        @independent_variables t
        @discretes CL(t)
        @parameters V
        @variables C(t)
        D = Differential(t)

        sys = MTK.System([D(C) ~ -(CL/V) * C], t, name=:test_validation)
        sys = MTK.mtkcompile(sys)

        u0 = [C => 0.0]
        p = [CL => 5.0, V => 10.0]
        tspan = (0.0, 24.0)
        u0_p = merge(Dict(u0), Dict(p))

        @testset "Error when dosing into parameter" begin
            # This should fail - trying to dose into parameter CL
            bad_df = DataFrame(
                TIME = [0.0, 12.0],
                EVID = [1, 1],
                CMT = [:C, :CL],  # CL is a parameter, not a state variable!
                AMT = [100.0, 50.0]
            )

            @test_throws ErrorException ODEProblem(sys, u0_p, tspan, bad_df)

            # Test the specific error message contains helpful guidance
            try
                ODEProblem(sys, u0_p, tspan, bad_df)
            catch e
                @test occursin("Cannot add a bolus dose into parameter", string(e))
                @test occursin("For parameter changes, use EVID=2 with a parameter column", string(e))
                @test occursin("EVID=2", string(e))
            end
        end

        @testset "Error when CMT not found" begin
            # Test with completely invalid CMT
            invalid_cmt_df = DataFrame(
                TIME = [0.0],
                EVID = [1],
                CMT = [:INVALID_CMT],
                AMT = [100.0]
            )

            @test_throws ErrorException ODEProblem(sys, u0_p, tspan, invalid_cmt_df)

            try
                ODEProblem(sys, u0_p, tspan, invalid_cmt_df)
            catch e
                @test occursin("not found in system", string(e))
                @test occursin("Available quantities", string(e))
            end
        end

        @testset "Success with valid CMT" begin
            # This should work - proper dosing into state variable
            good_df = DataFrame(
                TIME = [0.0, 12.0],
                EVID = [1, 1],
                CMT = [:C, :C],
                AMT = [100.0, 50.0]
            )

            @test_nowarn ODEProblem(sys, u0_p, tspan, good_df)
        end
    end

    @testset "Parameter Column Validation for Parameter Changes" begin
        # Define model with time-dependent parameter
        @independent_variables t
        @discretes CL(t)
        @parameters V
        @variables C(t)
        sys = MTK.System([Differential(t)(C) ~ -(CL/V) * C], t, name=:param_test)
        sys = MTK.mtkcompile(sys)

        u0_p = Dict(C => 0.0, CL => 5.0, V => 10.0)
        tspan = (0.0, 24.0)

        @testset "Success with valid parameter change" begin
            # This should work - proper parameter change
            good_df = DataFrame(
                TIME = [0.0, 12.0],
                EVID = [1, 2],
                CMT = [:C, missing],
                AMT = [100.0, missing],
                CL = [missing, 7.5]
            )

            @test_nowarn ODEProblem(sys, u0_p, tspan, good_df)
        end

        @testset "Error with invalid parameter name" begin
            # Test invalid parameter column
            invalid_param_df = DataFrame(
                TIME = [0.0, 12.0],
                EVID = [1, 2],
                CMT = [:C, missing],
                AMT = [100.0, missing],
                INVALID_PARAM = [missing, 7.5]  # This parameter doesn't exist in the model
            )

            @test_throws ErrorException ODEProblem(sys, u0_p, tspan, invalid_param_df)

            try
                ODEProblem(sys, u0_p, tspan, invalid_param_df)
            catch e
                @test occursin("not found in system. Available quantities:", string(e))
            end
        end

        @testset "Error when trying to change state variable with EVID=2" begin
            # Test trying to change state variable using EVID=2
            state_var_change_df = DataFrame(
                TIME = [0.0, 12.0],
                EVID = [1, 2],
                CMT = [:C, missing],
                AMT = [100.0, missing],
                C = [missing, 50.0]  # Trying to change state variable with EVID=2
            )

            @test_throws ErrorException ODEProblem(sys, u0_p, tspan, state_var_change_df)

            try
                ODEProblem(sys, u0_p, tspan, state_var_change_df)
            catch e
                @test occursin("to be a parameter, but it's a state variable", string(e))
                @test occursin(" State variables should be dosed using EVID=1 with CMT column", string(e))
            end
        end
    end

    @testset "Ordinary parameter changes are auto-promoted" begin
        @independent_variables t
        @parameters V_static
        @variables C2(t)
        sys2 = MTK.System([Differential(t)(C2) ~ -V_static * C2], t, name=:test_static)
        sys2 = MTK.mtkcompile(sys2)

        static_param_df = DataFrame(
            TIME = [0.0, 12.0],
            EVID = [1, 2],
            CMT = [:C2, missing],
            AMT = [100.0, missing],
            V_static = [missing, 0.5],
        )

        u0_p2 = Dict(C2 => 0.0, V_static => 0.1)
        tspan = (0.0, 24.0)

        prob = ODEProblem(sys2, u0_p2, tspan, static_param_df)
        v_params = [p for p in MTK.parameters(prob.f.sys) if MTK.getname(p) == :V_static]
        @test length(v_params) == 1
        @test InjecKit._is_time_dependent_parameter(only(v_params))
    end
end
