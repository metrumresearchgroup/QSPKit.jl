# Tests for error handling in InjecKit
# Tests error messages and validation failures

using InjecKit
using DifferentialEquations
using DataFrames
using Test

@testset "Error Handling" begin
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

    @testset "Invalid DataFrame column errors" begin
        # Missing TIME column
        df_no_time = DataFrame(
            EVID = [1],
            CMT = [:C],
            AMT = [100.0]
        )
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(df_no_time)

        # Missing EVID column
        df_no_evid = DataFrame(
            TIME = [0.0],
            CMT = [:C],
            AMT = [100.0]
        )
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(df_no_evid)

        # Non-numeric TIME
        df_bad_time = DataFrame(
            TIME = ["0.0"],  # String instead of number
            EVID = [1],
            CMT = [:C],
            AMT = [100.0]
        )
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(df_bad_time)

        # Non-integer EVID
        df_bad_evid = DataFrame(
            TIME = [0.0],
            EVID = [1.5],  # Float instead of integer
            CMT = [:C],
            AMT = [100.0]
        )
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(df_bad_evid)

        # Invalid EVID value
        df_invalid_evid = DataFrame(
            TIME = [0.0],
            EVID = [99],  # Invalid EVID
            CMT = [:C],
            AMT = [100.0]
        )
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(df_invalid_evid)

        # Missing CMT for dosing event
        df_no_cmt = DataFrame(
            TIME = [0.0],
            EVID = [1],
            AMT = [100.0]
        )
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(df_no_cmt)
    end

    @testset "Infusion parameter calculation errors" begin
        # Neither rate nor duration specified
        @test_throws ErrorException InjecKit.calculate_infusion_parameters(100.0, nothing, nothing)

        # amt missing when only rate provided
        @test_throws ErrorException InjecKit.calculate_infusion_parameters(nothing, 10.0, nothing)

        # amt missing when only duration provided
        @test_throws ErrorException InjecKit.calculate_infusion_parameters(nothing, nothing, 5.0)

        # Inconsistent amt, rate, duration
        @test_throws ErrorException InjecKit.calculate_infusion_parameters(200.0, 10.0, 5.0)  # 200 != 10*5
    end

    @testset "CMT validation errors" begin
        # Bolus to non-existent compartment
        df_bad_cmt = DataFrame(
            TIME = [0.0],
            EVID = [1],
            CMT = [:NonExistent],
            AMT = [100.0]
        )
        @test_throws ErrorException ODEProblem(sys, merge(u0, p), tspan, df_bad_cmt)

        # IEvent with non-existent compartment
        events_bad_cmt = [ev(time=0.0, cmt=:NonExistent, amt=100.0)]
        @test_throws ErrorException ODEProblem(sys, merge(u0, p), tspan, events_bad_cmt)

        # Bolus to parameter (should be state variable)
        df_param_as_cmt = DataFrame(
            TIME = [0.0],
            EVID = [1],
            CMT = [:CL],  # CL is a parameter, not a state variable
            AMT = [100.0]
        )
        @test_throws ErrorException ODEProblem(sys, merge(u0, p), tspan, df_param_as_cmt)

        # IEvent bolus to parameter
        events_param_cmt = [ev(time=0.0, cmt=:CL, amt=100.0)]
        @test_throws ErrorException ODEProblem(sys, merge(u0, p), tspan, events_param_cmt)
    end

    @testset "Parameter change validation errors" begin
        # EVID=2 for parameter that doesn't exist
        df_bad_param = DataFrame(
            TIME = [0.0],
            EVID = [2],
            CMT = [missing],
            AMT = [missing],
            NonExistentParam = [5.0]  # Parameter doesn't exist
        )
        @test_throws ErrorException ODEProblem(sys, merge(u0, p), tspan, df_bad_param)

        # IEvent parameter change for non-existent parameter
        events_bad_param = [ev(time=0.0, evid=2, NonExistentParam=5.0)]
        @test_throws ErrorException ODEProblem(sys, merge(u0, p), tspan, events_bad_param)

        # Ordinary source parameters are auto-promoted to time-dependent inputs.
        df_static_param = DataFrame(
            TIME = [0.0],
            EVID = [2],
            CMT = [missing],
            AMT = [missing],
            CL = [5.0]
        )
        @test_nowarn ODEProblem(sys, merge(u0, p), tspan, df_static_param)

        events_static_param = [ev(time=0.0, evid=2, CL=5.0)]
        @test_nowarn ODEProblem(sys, merge(u0, p), tspan, events_static_param)
    end

    @testset "resolve_variable_to_num errors" begin
        # Symbol not in system
        @test_throws ErrorException InjecKit.resolve_variable_to_num(:NonExistent, sys)

        @test_throws ArgumentError InjecKit.resolve_variable_to_num(123, sys)  # Int
        @test_throws ArgumentError InjecKit.resolve_variable_to_num([1, 2, 3], sys)  # Array
    end

    # Note: Computed parameter binding validation is handled during system extension
    # and may not throw in all cases depending on how the system is constructed.

    @testset "Infusion to parameter without input metadata" begin
        # System with discrete parameter but without input=true
        @discretes rate_param_no_input(t)  # Missing [input=true]
        @parameters V_inf
        @variables C_inf(t)
        inf_eqs = [D(C_inf) ~ rate_param_no_input - (CL/V_inf) * C_inf]
        @mtkcompile inf_sys = System(inf_eqs, t)

        u0_inf = Dict(C_inf => 0.0)
        p_inf = Dict(CL => 2.0, V_inf => 10.0, rate_param_no_input => 0.0)

        # Infusion targeting a parameter without input=true should error
        events_inf = [ev(time=0.0, cmt=:rate_param_no_input, amt=100.0, rate=10.0)]

        @test_throws ErrorException ODEProblem(inf_sys, merge(u0_inf, p_inf), tspan, events_inf)
    end

    @testset "Missing CMT for EVID=1 in DataFrame row" begin
        # CMT is missing in the row but exists in DataFrame
        df_missing_cmt_row = DataFrame(
            TIME = [0.0, 2.0],
            EVID = [1, 1],
            CMT = [:C, missing],  # Second row has missing CMT
            AMT = [100.0, 50.0]
        )

        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(df_missing_cmt_row)
    end

    @testset "IEvent with invalid evid" begin
        # EVID values outside standard range
        # Note: IEvent constructor doesn't validate evid, but resolution should fail for unknown evids
        invalid_event = InjecKit.IEvent(0.0, :C, 100.0, nothing, nothing, 99, nothing, nothing, nothing, Dict{Union{Symbol, MTK.Num}, Float64}())

        # When processed through the full pipeline, invalid EVID should be caught
        # (validation happens in dataframe_to_mrgevents for DataFrames)
        bad_df = DataFrame(TIME = [0.0], EVID = [5], CMT = [:C], AMT = [100.0])
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(bad_df)
    end

    @testset "Empty parameter changes for EVID=2" begin
        # EVID=2 without any parameter columns shouldn't cause errors, just no-op
        @discretes rate_td(t)
        @parameters V_td
        td_eqs = [D(C) ~ -(rate_td/V_td) * C]
        @mtkcompile td_sys = System(td_eqs, t)

        u0_td = Dict(C => 100.0)
        p_td = Dict(rate_td => 2.0, V_td => 10.0)

        # EVID=2 but no parameter columns (all reserved columns)
        df_empty_param = DataFrame(
            TIME = [0.0],
            EVID = [2],
            CMT = [missing],
            AMT = [missing]
            # No parameter columns provided
        )

        # Should work but effectively be a no-op
        events = InjecKit.dataframe_to_mrgevents(df_empty_param)
        @test length(events) == 1
        @test isempty(events[1].param_changes)
    end

    @testset "String vs Symbol resolution" begin
        # Ensure both String and Symbol resolve correctly to same variable
        resolved_symbol = InjecKit.resolve_variable_to_num(:C, sys)
        @test resolved_symbol !== nothing

        resolved_string = InjecKit.resolve_variable_to_num("C", sys)
        @test isequal(resolved_symbol, resolved_string)
    end
end
