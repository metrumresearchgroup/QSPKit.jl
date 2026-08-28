@testset "absolute state-set events" begin
    @independent_variables reset_t
    @parameters reset_k=0.0
    @variables ResetX(reset_t)=3.0
    reset_D = Differential(reset_t)
    @mtkcompile reset_system = MTK.System([
        reset_D(ResetX) ~ -reset_k * ResetX,
    ], reset_t)
    reset_problem = ODEProblem(reset_system, [], (0.0, 3.0))

    direct = ev(time=1.0, evid=8, cmt=:ResetX, amt=7.0)
    named = setevent(1.0, :ResetX => 7.0)
    @test direct.evid == named.evid == 8
    @test direct.cmt == named.cmt == :ResetX
    @test direct.amt == named.amt == 7.0

    schedule = InjecKit.prepare_events([
        ev(time=0.0, cmt=:ResetX, amt=2.0),
        named,
    ])
    prepared = PreparedEventSolve(reset_problem, schedule; params=())
    solution = prepared(
        NamedTuple(); alg=Tsit5(), saveat=[0.0, 1.0, 2.0],
        abstol=1e-11, reltol=1e-11)
    @test solution(0.0; idxs=ResetX) ≈ 5.0 atol=1e-10
    @test solution(1.0; idxs=ResetX, continuity=:left) ≈ 5.0 atol=1e-10
    @test solution(1.0; idxs=ResetX, continuity=:right) ≈ 7.0 atol=1e-10
    @test solution(2.0; idxs=ResetX) ≈ 7.0 atol=1e-10

    initial_solution = solve(
        reset_problem, [setevent(0.0, ResetX => 9.0)], Tsit5();
        saveat=[0.0, 1.0], abstol=1e-11, reltol=1e-11)
    @test initial_solution(0.0; idxs=ResetX) ≈ 9.0 atol=1e-10

    @test_throws ArgumentError PreparedEventSolve(
        reset_problem,
        [ev(time=1.0, evid=8, cmt=ResetX, amt=1.0, rate=1.0)];
        params=())

    unsupported = try
        PreparedEventSolve(
            reset_problem, [ev(time=1.0, evid=3, cmt=ResetX, amt=1.0)];
            params=())
        nothing
    catch err
        err
    end
    @test unsupported isa ArgumentError
    @test occursin("Unsupported EVID=3 at time 1.0", sprint(showerror, unsupported))
end
