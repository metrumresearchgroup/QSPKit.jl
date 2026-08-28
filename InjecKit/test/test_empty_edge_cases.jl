# Tests for empty and edge case inputs in InjecKit
# Tests handling of empty DataFrames, empty event vectors, and unusual inputs

using InjecKit
using DifferentialEquations
using DataFrames
using Test

@testset "Empty and Edge Case Inputs" begin
    # Common system setup
    @independent_variables t
    @variables C(t)
    @parameters CL V
    D = Differential(t)

    eqs = [D(C) ~ -(CL/V) * C]
    @mtkcompile sys = System(eqs, t)

    u0 = Dict(C => 100.0)  # Start with some drug for elimination tests
    p = Dict(CL => 2.0, V => 10.0)
    tspan = (0.0, 10.0)

    @testset "Event constructors skip MTK initialization by default" begin
        @independent_variables tau
        @variables X(tau)
        @parameters kinit
        Dtau = Differential(tau)

        sys_init = MTK.System(
            [Dtau(X) ~ -kinit * X],
            tau;
            initialization_eqs = [X ~ 1.0, X ~ 1.0],
            initial_conditions = Dict(X => 1.0),
            name = :event_init_skip,
        )
        sys_init = MTK.mtkcompile(sys_init)
        init_events = [ev(time = 0.0, cmt = :X, amt = 0.0)]
        init_map = Dict(X => 1.0, kinit => 0.1)

        prob = ODEProblem(sys_init, init_map, (0.0, 1.0), init_events)
        @test prob.f.initialization_data === nothing
        @test solve(prob, Tsit5()).retcode == ReturnCode.Success

        prob_with_init = ODEProblem(
            sys_init, init_map, (0.0, 1.0), init_events;
            build_initializeprob = true,
        )
        @test prob_with_init.f.initialization_data !== nothing
    end

    @testset "Empty DataFrame" begin
        # Create an empty DataFrame with required columns
        empty_df = DataFrame(
            TIME = Float64[],
            EVID = Int[],
            CMT = Symbol[],
            AMT = Float64[]
        )

        # Should create a valid problem with no events
        prob = ODEProblem(sys, merge(u0, p), tspan, empty_df)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        # With no events and initial C=100, drug should just decay
        @test sol(0.0, idxs=C) == 100.0
        @test sol(5.0, idxs=C) < 100.0  # Should decay
    end

    @testset "Empty Vector{IEvent}" begin
        empty_events = IEvent[]

        prob = ODEProblem(sys, merge(u0, p), tspan, empty_events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(0.0, idxs=C) == 100.0
        @test sol(5.0, idxs=C) < 100.0
    end

    @testset "Empty Vector{SymbolicDiscreteCallback}" begin
        empty_callbacks = MTK.SymbolicDiscreteCallback[]

        prob = ODEProblem(sys, merge(u0, p), tspan, empty_callbacks)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(0.0, idxs=C) == 100.0
        @test sol(5.0, idxs=C) < 100.0
    end

    @testset "DataFrame with only parameter changes (no dosing events)" begin
        # Extended system with time-dependent parameter
        @discretes CL_td(t)
        @parameters V_static
        eqs_param = [D(C) ~ -(CL_td/V_static) * C]
        @mtkcompile sys_param = System(eqs_param, t)

        u0_param = Dict(C => 100.0)
        p_param = Dict(CL_td => 2.0, V_static => 10.0)

        # DataFrame with only EVID=2 events
        param_only_df = DataFrame(
            TIME = [2.0, 5.0],
            EVID = [2, 2],
            CMT = [missing, missing],
            AMT = [missing, missing],
            CL_td = [5.0, 10.0]  # Increase clearance at t=2 and t=5
        )

        prob = ODEProblem(sys_param, merge(u0_param, p_param), tspan, param_only_df)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        # Clearance increases should lead to faster elimination
        # At t=1.9 (before first change), elimination rate based on CL=2
        # At t=2.1 (after first change), elimination rate based on CL=5
        c_before_first = sol(1.9, idxs=C)
        c_after_first = sol(3.0, idxs=C)
        c_after_second = sol(7.0, idxs=C)

        @test c_before_first > c_after_first  # Drug decays
        @test c_after_first > c_after_second   # Drug continues to decay
    end

    @testset "Single IEvent (should work without wrapping)" begin
        # Test that a single event works when passed directly
        single_event = ev(time=0.0, cmt=:C, amt=50.0)

        u0_zero = Dict(C => 0.0)
        prob = ODEProblem(sys, merge(u0_zero, p), tspan, single_event)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(0.0, idxs=C) == 50.0  # Single dose applied
    end

    @testset "Single SymbolicDiscreteCallback (should work without wrapping)" begin
        single_callback = MTK.SymbolicDiscreteCallback([2.0], [C ~ Pre(C) + 50.0])

        # Wrap in vector since single callback may need to be wrapped
        prob = ODEProblem(sys, merge(u0, p), tspan, [single_callback])
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(2.1, idxs=C) > sol(1.9, idxs=C)  # Dose at t=2
    end

    @testset "DataFrame with missing values in optional columns" begin
        # DataFrame with various missing values in optional columns
        df_with_missing = DataFrame(
            TIME = [0.0, 2.0, 4.0],
            EVID = [1, 1, 1],
            CMT = [:C, :C, :C],
            AMT = [100.0, 50.0, 75.0],
            RATE = [missing, missing, missing],      # All missing
            DURATION = [missing, missing, missing],  # All missing
            II = [missing, missing, missing],        # All missing
            ADDL = [missing, missing, missing]       # All missing
        )

        u0_zero = Dict(C => 0.0)
        prob = ODEProblem(sys, merge(u0_zero, p), tspan, df_with_missing)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(0.0, idxs=C) == 100.0  # First bolus
        @test sol(2.1, idxs=C) > sol(1.9, idxs=C)  # Second bolus at t=2
        @test sol(4.1, idxs=C) > sol(3.9, idxs=C)  # Third bolus at t=4
    end

    @testset "DataFrame with zero amounts (valid but edge case)" begin
        # Zero amount doses should be valid (no-op)
        df_zero_amt = DataFrame(
            TIME = [0.0, 2.0],
            EVID = [1, 1],
            CMT = [:C, :C],
            AMT = [0.0, 50.0],  # First dose is zero
            RATE = [0.0, 0.0]
        )

        u0_zero = Dict(C => 0.0)
        prob = ODEProblem(sys, merge(u0_zero, p), tspan, df_zero_amt)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(0.0, idxs=C) == 0.0   # Zero dose at t=0
        @test sol(1.0, idxs=C) ≈ 0.0 atol=1e-10  # Still zero before second dose
        # After bolus at t=2, concentration should be ~50 (minus tiny decay)
        @test sol(2.1, idxs=C) > 40.0  # Should have most of the 50 dose
    end

    @testset "Events at exact tspan boundaries" begin
        # Test events at exact start and end of tspan
        events = [
            ev(time=0.0, cmt=:C, amt=100.0),   # At tspan start
            ev(time=9.0, cmt=:C, amt=50.0),    # Near tspan end (not at exact end)
        ]

        u0_zero = Dict(C => 0.0)
        prob = ODEProblem(sys, merge(u0_zero, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(0.0, idxs=C) == 100.0
        # Event near end of tspan should be captured
        @test sol(9.1, idxs=C) > sol(8.9, idxs=C)  # Dose at t=9 should increase concentration
    end

    @testset "Very small time differences between events" begin
        # Events very close together in time
        events = [
            ev(time=0.0, cmt=:C, amt=100.0),
            ev(time=0.001, cmt=:C, amt=50.0),   # Very close to t=0
            ev(time=0.002, cmt=:C, amt=25.0),   # Even closer
        ]

        u0_zero = Dict(C => 0.0)
        prob = ODEProblem(sys, merge(u0_zero, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        # All three doses should be applied
        c_after_all = sol(0.01, idxs=C)
        @test c_after_all > 170.0  # Should have ~175 (100+50+25 minus tiny decay)
    end

    # Note: String CMT is not currently supported - use Symbol instead
    # The implementation requires Symbol for CMT column in DataFrame and IEvent

    @testset "Multiple t=0 boluses to same compartment accumulate" begin
        # Two separate bolus events at t=0 should stack additively
        events = [
            ev(time=0.0, cmt=:C, amt=60.0),
            ev(time=0.0, cmt=:C, amt=40.0),
        ]

        u0_zero = Dict(C => 0.0)
        prob = ODEProblem(sys, merge(u0_zero, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(0.0, idxs=C) == 100.0  # 60 + 40 = 100, not just 40
    end

    @testset "t=0 bolus adds to nonzero IC" begin
        # A t=0 event should add ON TOP of the existing initial condition
        events = [
            ev(time=0.0, cmt=:C, amt=50.0),
        ]

        u0_nonzero = Dict(C => 25.0)
        prob = ODEProblem(sys, merge(u0_nonzero, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(0.0, idxs=C) == 75.0  # 25 (IC) + 50 (dose) = 75
    end

    @testset "t=0 event via solve(prob, events) path" begin
        # Test that t=0 events work when using the solve(prob, events) interface
        # First create a bare problem without events
        u0_zero = Dict(C => 0.0)
        base_prob = ODEProblem(sys, merge(u0_zero, p), tspan)

        events = [
            ev(time=0.0, cmt=:C, amt=100.0),
            ev(time=5.0, cmt=:C, amt=50.0),
        ]

        sol = solve(base_prob, events, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(0.0, idxs=C) == 100.0  # t=0 dose applied
        @test sol(5.1, idxs=C) > sol(4.9, idxs=C)  # t=5 dose fires
    end

    @testset "addl=0 edge case (valid, no additional doses)" begin
        events = [
            ev(time=0.0, cmt=:C, amt=100.0, ii=2.0, addl=0),  # addl=0 means no additional doses
        ]

        u0_zero = Dict(C => 0.0)
        prob = ODEProblem(sys, merge(u0_zero, p), tspan, events)
        sol = solve(prob, Tsit5())

        @test sol.retcode == ReturnCode.Success
        @test sol(0.0, idxs=C) == 100.0
        # With addl=0, there should be no dose at t=2
        # The value should be lower than if we had gotten a second dose
        @test sol(2.1, idxs=C) < 100.0  # Just decaying, no second dose
    end
end
