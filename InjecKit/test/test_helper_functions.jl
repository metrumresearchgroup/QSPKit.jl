# Tests for internal helper functions in InjecKit
# Unit tests for functions in variable_resolution.jl, infusion_handling.jl, event_processing.jl

using InjecKit
using DifferentialEquations
using DataFrames
using Test

@testset "Helper Function Unit Tests" begin
    # Setup a test system for variable resolution tests
    @independent_variables t
    @variables C(t) depot(t)
    @parameters CL V ka
    @discretes rate_param(t) = 0.0 [input=true]
    D = Differential(t)

    eqs = [
        D(C) ~ ka * depot - (CL/V) * C,
        D(depot) ~ -ka * depot
    ]
    @mtkcompile sys = System(eqs, t)

    @testset "missing_to_nothing" begin
        @test InjecKit.missing_to_nothing(missing) === nothing
        @test InjecKit.missing_to_nothing(nothing) === nothing
        @test InjecKit.missing_to_nothing(5.0) === 5.0
        @test InjecKit.missing_to_nothing("test") === "test"
        @test InjecKit.missing_to_nothing(0) === 0
        @test InjecKit.missing_to_nothing(true) === true
    end

    @testset "is_bolus_dose" begin
        # Bolus cases (rate and duration both zero or nothing)
        @test InjecKit.is_bolus_dose(nothing, nothing) == true
        @test InjecKit.is_bolus_dose(0.0, nothing) == true
        @test InjecKit.is_bolus_dose(nothing, 0.0) == true
        @test InjecKit.is_bolus_dose(0.0, 0.0) == true
        @test InjecKit.is_bolus_dose(0, 0) == true

        # Infusion cases (rate or duration > 0)
        @test InjecKit.is_bolus_dose(10.0, nothing) == false  # Has rate
        @test InjecKit.is_bolus_dose(nothing, 5.0) == false   # Has duration
        @test InjecKit.is_bolus_dose(10.0, 5.0) == false      # Has both
        @test InjecKit.is_bolus_dose(0.0, 5.0) == false       # Zero rate but has duration
    end

    @testset "is_infusion" begin
        # Infusion cases
        @test InjecKit.is_infusion(10.0, nothing) == true   # Rate-based
        @test InjecKit.is_infusion(nothing, 5.0) == true    # Duration-based
        @test InjecKit.is_infusion(10.0, 5.0) == true       # Both specified
        @test InjecKit.is_infusion(0.1, 0.0) == true        # Small positive rate

        # Non-infusion cases
        @test InjecKit.is_infusion(nothing, nothing) == false
        @test InjecKit.is_infusion(0.0, nothing) == false
        @test InjecKit.is_infusion(nothing, 0.0) == false
        @test InjecKit.is_infusion(0.0, 0.0) == false
    end

    @testset "calculate_infusion_parameters" begin
        # Rate-only: calculate duration from amt/rate
        amt, rate, duration = InjecKit.calculate_infusion_parameters(100.0, 10.0, nothing)
        @test amt == 100.0
        @test rate == 10.0
        @test duration == 10.0  # 100/10

        # Duration-only: calculate rate from amt/duration
        amt, rate, duration = InjecKit.calculate_infusion_parameters(100.0, nothing, 5.0)
        @test amt == 100.0
        @test rate == 20.0  # 100/5
        @test duration == 5.0

        # Both specified (consistent): validate and return
        amt, rate, duration = InjecKit.calculate_infusion_parameters(100.0, 20.0, 5.0)
        @test amt == 100.0
        @test rate == 20.0
        @test duration == 5.0

        # Both specified, amt missing: calculate amt
        amt, rate, duration = InjecKit.calculate_infusion_parameters(nothing, 20.0, 5.0)
        @test amt == 100.0  # 20*5
        @test rate == 20.0
        @test duration == 5.0

        # Error cases
        @test_throws ErrorException InjecKit.calculate_infusion_parameters(nothing, nothing, nothing)
        @test_throws ErrorException InjecKit.calculate_infusion_parameters(nothing, 10.0, nothing)  # amt missing with rate only
        @test_throws ErrorException InjecKit.calculate_infusion_parameters(nothing, nothing, 5.0)   # amt missing with duration only

        # Inconsistent parameters should error
        @test_throws ErrorException InjecKit.calculate_infusion_parameters(200.0, 10.0, 5.0)  # 200 != 10*5
    end

    @testset "calculate_infusion_stop_time" begin
        # Rate-based
        stop = InjecKit.calculate_infusion_stop_time(0.0, 100.0, 10.0, nothing)
        @test stop == 10.0  # duration = 100/10 = 10

        # Duration-based
        stop = InjecKit.calculate_infusion_stop_time(2.0, 100.0, nothing, 5.0)
        @test stop == 7.0  # 2.0 + 5.0

        # Both specified
        stop = InjecKit.calculate_infusion_stop_time(1.0, 100.0, 20.0, 5.0)
        @test stop == 6.0  # 1.0 + 5.0

        # Different start times
        stop = InjecKit.calculate_infusion_stop_time(10.0, 50.0, 10.0, nothing)
        @test stop == 15.0  # 10.0 + (50/10)
    end

    @testset "is_state_variable" begin
        @test InjecKit.is_state_variable(:C, sys) == true
        @test InjecKit.is_state_variable(:depot, sys) == true
        @test InjecKit.is_state_variable(:CL, sys) == false      # Parameter, not state
        @test InjecKit.is_state_variable(:V, sys) == false       # Parameter, not state
        @test InjecKit.is_state_variable(:nonexistent, sys) == false
    end

    @testset "is_parameter" begin
        @test InjecKit.is_parameter(:CL, sys) == true
        @test InjecKit.is_parameter(:V, sys) == true
        @test InjecKit.is_parameter(:ka, sys) == true
        @test InjecKit.is_parameter(:C, sys) == false       # State variable, not parameter
        @test InjecKit.is_parameter(:depot, sys) == false   # State variable, not parameter
        @test InjecKit.is_parameter(:nonexistent, sys) == false
    end

    @testset "buildSet" begin
        # Test with simple parameters
        params = MTK.parameters(sys)
        param_set = InjecKit.buildSet(params)
        @test !isempty(param_set)
        @test param_set isa Set

        # Test with unknowns
        unknowns = MTK.unknowns(sys)
        unknowns_set = InjecKit.buildSet(unknowns)
        @test !isempty(unknowns_set)

        # Test with empty input
        empty_set = InjecKit.buildSet([])
        @test isempty(empty_set)
    end

    @testset "find_variable_in_system" begin
        # Find state variables
        result = InjecKit.find_variable_in_system(:C, sys, MTK.unknowns)
        @test result !== nothing

        result = InjecKit.find_variable_in_system(:depot, sys, MTK.unknowns)
        @test result !== nothing

        # Find parameters
        result = InjecKit.find_variable_in_system(:CL, sys, MTK.parameters)
        @test result !== nothing

        # Not found cases
        result = InjecKit.find_variable_in_system(:nonexistent, sys, MTK.unknowns)
        @test result === nothing

        result = InjecKit.find_variable_in_system(:C, sys, MTK.parameters)  # C is not a parameter
        @test result === nothing
    end

    @testset "is_variable_in_system" begin
        # State variables exist in unknowns
        @test InjecKit.is_variable_in_system(:C, sys, MTK.unknowns) == true
        @test InjecKit.is_variable_in_system(:depot, sys, MTK.unknowns) == true

        # Parameters exist in parameters
        @test InjecKit.is_variable_in_system(:CL, sys, MTK.parameters) == true
        @test InjecKit.is_variable_in_system(:V, sys, MTK.parameters) == true

        # Cross-checks (state var not in params, param not in unknowns)
        @test InjecKit.is_variable_in_system(:C, sys, MTK.parameters) == false
        @test InjecKit.is_variable_in_system(:CL, sys, MTK.unknowns) == false

        # Nonexistent
        @test InjecKit.is_variable_in_system(:fake, sys, MTK.unknowns) == false
        @test InjecKit.is_variable_in_system(:fake, sys, MTK.parameters) == false
    end

    @testset "expand_repeated_events" begin
        # Single event without ii/addl should return unchanged
        events = [ev(time=0.0, cmt=:C, amt=100.0)]
        expanded = InjecKit.expand_repeated_events(events)
        @test length(expanded) == 1
        @test expanded[1].time == 0.0

        # Event with ii and addl should expand
        events = [ev(time=0.0, cmt=:C, amt=100.0, ii=24.0, addl=2)]
        expanded = InjecKit.expand_repeated_events(events)
        @test length(expanded) == 3  # Original + 2 additional
        @test expanded[1].time == 0.0
        @test expanded[2].time == 24.0
        @test expanded[3].time == 48.0

        # All expanded events should have same amt
        @test all(e -> e.amt == 100.0, expanded)

        # Expanded events should NOT have ii/addl (to avoid infinite recursion)
        @test expanded[2].ii === nothing
        @test expanded[2].addl === nothing

        # Multiple events, some with repeats
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, ii=12.0, addl=1),
            ev(time=6.0, cmt=:C, amt=50.0)  # Single event
        ]
        expanded = InjecKit.expand_repeated_events(events)
        @test length(expanded) == 3  # 2 from first + 1 from second

        # Should be sorted by time
        @test expanded[1].time == 0.0
        @test expanded[2].time == 6.0   # Single event
        @test expanded[3].time == 12.0  # Expanded from first

        # addl=0 should not add extra events
        events = [ev(time=0.0, cmt=:C, amt=100.0, ii=24.0, addl=0)]
        expanded = InjecKit.expand_repeated_events(events)
        @test length(expanded) == 1

        # ii without addl should not expand
        events = [ev(time=0.0, cmt=:C, amt=100.0, ii=24.0)]
        expanded = InjecKit.expand_repeated_events(events)
        @test length(expanded) == 1
    end

    @testset "_extract_all_event_times" begin
        # Bolus events only
        events = [
            InjecKit.IEvent(0.0, :C, 100.0, nothing, nothing, 1, nothing, nothing, nothing, Dict{Union{Symbol, MTK.Num}, Float64}()),
            InjecKit.IEvent(5.0, :C, 50.0, nothing, nothing, 1, nothing, nothing, nothing, Dict{Union{Symbol, MTK.Num}, Float64}())
        ]
        times = InjecKit._extract_all_event_times(events)
        @test 0.0 in times
        @test 5.0 in times
        @test length(times) == 2

        # Infusion events (should include stop times)
        events_infusion = [
            InjecKit.IEvent(0.0, :C, 100.0, 10.0, nothing, 1, nothing, nothing, nothing, Dict{Union{Symbol, MTK.Num}, Float64}()),  # Rate=10, duration=10
        ]
        times_infusion = InjecKit._extract_all_event_times(events_infusion)
        @test 0.0 in times_infusion
        @test 10.0 in times_infusion  # Stop time

        # Duration-based infusion
        events_duration = [
            InjecKit.IEvent(2.0, :C, 100.0, nothing, 4.0, 1, nothing, nothing, nothing, Dict{Union{Symbol, MTK.Num}, Float64}()),  # Duration=4
        ]
        times_duration = InjecKit._extract_all_event_times(events_duration)
        @test 2.0 in times_duration
        @test 6.0 in times_duration  # Stop time = 2 + 4

        # Parameter change events (EVID=2, should not add stop times)
        events_param = [
            InjecKit.IEvent(3.0, nothing, nothing, nothing, nothing, 2, nothing, nothing, nothing, Dict{Union{Symbol, MTK.Num}, Float64}(:CL => 5.0))
        ]
        times_param = InjecKit._extract_all_event_times(events_param)
        @test 3.0 in times_param
        @test length(times_param) == 1
    end

    @testset "_add_event_times_to_tstops" begin
        # Empty kwargs, add new tstops
        kwargs = (;)
        event_times = [1.0, 3.0, 5.0]
        result = InjecKit._add_event_times_to_tstops(kwargs, event_times)
        @test haskey(result, :tstops)
        @test result.tstops == [1.0, 3.0, 5.0]

        # Empty event times should return kwargs unchanged
        kwargs = (other_kwarg = 123,)
        event_times = Float64[]
        result = InjecKit._add_event_times_to_tstops(kwargs, event_times)
        @test haskey(result, :other_kwarg)
        @test result.other_kwarg == 123
    end

    @testset "dataframe_to_mrgevents" begin
        # Valid DataFrame
        df = DataFrame(
            TIME = [0.0, 2.0, 4.0],
            EVID = [1, 1, 1],
            CMT = [:C, :C, :C],
            AMT = [100.0, 50.0, 75.0]
        )
        events = InjecKit.dataframe_to_mrgevents(df)
        @test length(events) == 3
        @test events[1].time == 0.0
        @test events[1].amt == 100.0
        @test events[2].time == 2.0
        @test events[3].amt == 75.0

        # DataFrame with parameter change events
        df_param = DataFrame(
            TIME = [0.0, 2.0],
            EVID = [1, 2],
            CMT = [:C, missing],
            AMT = [100.0, missing],
            CL = [missing, 5.0]  # Parameter column
        )
        events_param = InjecKit.dataframe_to_mrgevents(df_param)
        @test length(events_param) == 2
        @test events_param[2].evid == 2
        @test haskey(events_param[2].param_changes, :CL)
        @test events_param[2].param_changes[:CL] == 5.0

        # Missing TIME column should error
        bad_df = DataFrame(EVID = [1], CMT = [:C], AMT = [100.0])
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(bad_df)

        # Missing EVID column should error
        bad_df2 = DataFrame(TIME = [0.0], CMT = [:C], AMT = [100.0])
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(bad_df2)

        # Invalid EVID value should error
        bad_df3 = DataFrame(TIME = [0.0], EVID = [99], CMT = [:C], AMT = [100.0])
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(bad_df3)

        # Missing CMT for EVID=1 should error
        bad_df4 = DataFrame(TIME = [0.0], EVID = [1], AMT = [100.0])
        @test_throws ErrorException InjecKit.dataframe_to_mrgevents(bad_df4)
    end

end
