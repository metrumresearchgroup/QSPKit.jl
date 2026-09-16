@testset "prepared execution public API" begin
    @independent_variables prepared_t
    @parameters prepared_k=0.1
    @variables PreparedX(prepared_t)=0.0
    prepared_D = Differential(prepared_t)
    @mtkcompile prepared_system = MTK.System([
        prepared_D(PreparedX) ~ -prepared_k * PreparedX,
    ], prepared_t)
    prepared_problem = ODEProblem(prepared_system, [], (0.0, 2.0))
    prepared_events = [
        ev(time=0.0, cmt=:PreparedX, amt=2.0),
        ev(time=1.0, cmt=:PreparedX, amt=1.0),
    ]

    runner = EventRunner(prepared_problem, prepared_events)
    @test runner isa EventRunner
    runner_solution = solve_event_runner(
        runner, Tsit5(); saveat=[0.0, 0.9, 1.1, 2.0])
    @test runner_solution.retcode == SciMLBase.ReturnCode.Success
    @test runner_solution(0.0; idxs=PreparedX) ≈ 2.0 atol=1e-10
    @test runner_solution(1.1; idxs=PreparedX) >
        runner_solution(0.9; idxs=PreparedX)

    # The explicit-problem form reuses the plan with current problem values.
    remade_problem = SciMLBase.remake(
        prepared_problem; p=[prepared_k => 0.2], build_initializeprob=false)
    explicit_solution = solve_event_runner(
        runner, remade_problem, Tsit5(); saveat=[0.0, 2.0])
    @test explicit_solution.retcode == SciMLBase.ReturnCode.Success
    @test explicit_solution(2.0; idxs=PreparedX) <
        runner_solution(2.0; idxs=PreparedX)

    prepared = PreparedEventSolve(
        prepared_problem, prepared_events; params=(:prepared_k,))
    direct_solution = prepared(
        (prepared_k=0.3,); alg=Tsit5(), saveat=[0.0, 2.0])
    @test direct_solution.retcode == SciMLBase.ReturnCode.Success

    problem_info = with_prepared_event_problem(
        prepared, (prepared_k=0.3,)) do solve_problem, callback, solve_kwargs
        (
            parameter=solve_problem.ps[prepared_k],
            has_callback=callback !== nothing,
            has_tstops=:tstops in keys(solve_kwargs),
        )
    end
    @test problem_info.parameter ≈ 0.3
    @test problem_info.has_callback
    @test problem_info.has_tstops

    callback_value = with_prepared_event_solve(
        prepared, (prepared_k=0.4,); alg=Tsit5(), saveat=[0.0, 2.0]) do sol, updated_problem
        @test updated_problem.ps[prepared_k] ≈ 0.4
        @test sol.retcode == SciMLBase.ReturnCode.Success
        sol(2.0; idxs=PreparedX)
    end
    @test callback_value < direct_solution(2.0; idxs=PreparedX)

    flat_index = tunable_parameter_index(prepared_problem, prepared_k)
    @test flat_index isa Int
    @test flat_index > 0
    @test_throws ErrorException tunable_parameter_index(prepared_problem, PreparedX)

    no_event_prepared = PreparedEventSolve(
        prepared_problem, IEvent[]; params=(:prepared_k,))
    active_info = with_prepared_active_tunable_sensitivity_problem(
        no_event_prepared, (prepared_k=0.25,);
        active_params=(prepared_k=0.25,)) do active_problem, callback, solve_kwargs, indexing_problem
        (
            p=copy(active_problem.p),
            callback=callback,
            kwargs=solve_kwargs,
            index=tunable_parameter_index(indexing_problem, prepared_k),
        )
    end
    @test active_info.p == [0.25]
    @test active_info.callback === nothing
    @test isempty(active_info.kwargs)
    @test active_info.index == flat_index
end
