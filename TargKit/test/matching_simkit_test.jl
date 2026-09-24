using Test
using QSPKit.TargKit
using QSPKit.TargKit: MatchError
using QSPKit.SimKit
using QSPKit.InjecKit: ev
using ModelingToolkit
using OrdinaryDiffEq: Tsit5
using DataFrames

# Depot → central PK model with an observed concentration
@independent_variables t
Dt = Differential(t)
@parameters ka=0.5 CL=1.0 V=10.0
@variables Depot(t)=0.0 Central(t)=0.0 Conc(t)
@named matching_pk = System([
    Dt(Depot) ~ -ka * Depot,
    Dt(Central) ~ ka * Depot - (CL / V) * Central,
    Conc ~ Central / V,
], t)
const MATCH_SYS = mtkcompile(matching_pk)
const MATCH_PROB = ODEProblem(MATCH_SYS, [], (0.0, 10.0))

# Two doses: one at 0 and one at 5, so t = 5 is a discontinuity
twice(p) = [ev(time=0.0, cmt=:Depot, amt=p.dose), ev(time=5.0, cmt=:Depot, amt=p.dose)]

# Dense solutions unless `saveat` is passed
function pk_scan(overrides; doses = [10.0, 20.0], kwargs...)
    scan(SimContext(MATCH_PROB; solver=Tsit5()) |> with(overrides), :dose => doses;
        events = twice, duration = 10.0, kwargs...)
end
pk_scan_saved(overrides; kwargs...) = pk_scan(overrides; saveat = 0:1.0:10, kwargs...)

conc_at(results, dose, time) = only(r for r in results if r.params[:dose] == dose).result.sol(time; idxs=MATCH_SYS.Conc)

@testset verbose=true "TargKit matching — SimKit outputs" begin

    @testset "scan result: keys from scanned values, `at` on solution time" begin
        results = pk_scan((CL = 1.0,))
        ts = TargetSet(DataFrame(dose = [20.0, 10.0], TIME = [3.0, 7.5], Conc = [1.0, 1.0]); value = :Conc) => Match(:dose; at = :TIME, variable = :Conc)
        predicted = score(ts; sim = results).details.predicted
        @test predicted[1] ≈ conc_at(results, 20.0, 3.0)
        @test predicted[2] ≈ conc_at(results, 10.0, 7.5)   # between saved points: dense output

        # State variables work as well as observed ones
        ts_state = TargetSet(DataFrame(dose = [10.0], Central = [1.0]); value = :Central) => Match(:dose; at = :TIME => 2.0, variable = :Central)
        @test only(score(ts_state; sim = results).details.predicted) ≈
            results[1].result.sol(2.0; idxs=MATCH_SYS.Central)
    end

    @testset "same targets against to_dataframe, result(scan), and a SimContext" begin
        results = pk_scan_saved((CL = 1.0,))
        ts = TargetSet(DataFrame(dose = [10.0, 20.0], Conc = [1.0, 1.0]); value = :Conc) => Match(:dose; at = :TIME => 8.0, variable = :Conc)
        expected = [conc_at(results, 10.0, 8.0), conc_at(results, 20.0, 8.0)]

        @test score(ts; sim = results).details.predicted ≈ expected
        @test score(ts; sim = to_dataframe(results)).details.predicted ≈ expected
        @test score(ts; sim = result(results)).details.predicted ≈ expected

        single = TargetSet(DataFrame(Conc = [1.0]); value = :Conc) => Match(; at = :TIME => 8.0, variable = :Conc)
        @test only(score(single; sim = results[1].result).details.predicted) ≈ expected[1]
    end

    @testset "errors against solutions" begin
        results = pk_scan_saved((CL = 1.0,))
        msg(ts, sim) = try
            score(ts; sim = sim)
            ""
        catch e
            e isa MatchError || rethrow()
            sprint(showerror, e)
        end

        # A target at the second dose time: two saved points, before and after the dose
        at5 = TargetSet(DataFrame(dose = [10.0], Conc = [1.0]); value = :Conc) => Match(:dose; at = :TIME => 5.0, variable = :Conc)
        @test occursin("2 points at t = 5.0", msg(at5, results))
        @test occursin("2 points at t = 5.0", msg(at5, pk_scan((CL = 1.0,))))   # dense solutions too
        # The same target against the table output: two rows at TIME = 5
        @test occursin("before and after a dose", msg(at5, to_dataframe(results)))

        outside = TargetSet(DataFrame(dose = [10.0], Conc = [1.0]); value = :Conc) => Match(:dose; at = :TIME => 12.0, variable = :Conc)
        @test occursin("outside the simulated time span [0.0, 10.0]", msg(outside, results))

        unscanned = TargetSet(DataFrame(dose = [30.0], Conc = [1.0]); value = :Conc) => Match(:dose; at = :TIME => 2.0, variable = :Conc)
        m = msg(unscanned, results)
        @test occursin("no simulation result has dose = 30.0", m)
        @test occursin("dose = 10.0; dose = 20.0", m)

        # saveat solutions have no dense output: only saved times can be targeted
        between = TargetSet(DataFrame(dose = [10.0], Conc = [1.0]); value = :Conc) => Match(:dose; at = :TIME => 7.5, variable = :Conc)
        @test occursin("t = 7.5 is not a saved point", msg(between, results))

        no_at = TargetSet(DataFrame(dose = [10.0], Conc = [1.0]); value = :Conc) => Match(:dose; variable = :Conc)
        @test occursin("needs `at`", msg(no_at, results))

        extra_key = TargetSet(DataFrame(dose = [10.0], donor = [:D1], Conc = [1.0]); value = :Conc) => Match(:dose, :donor; at = :TIME => 2.0, variable = :Conc)
        @test occursin("match key(s) :donor were not found", msg(extra_key, results))

        grid = scan(SimContext(MATCH_PROB; solver=Tsit5()), :dose => [10.0], :ka => [0.1, 1.0];
            events = twice, duration = 10.0)
        ambiguous = TargetSet(DataFrame(dose = [10.0], Conc = [1.0]); value = :Conc) => Match(:dose; at = :TIME => 2.0, variable = :Conc)
        @test occursin("differ in :ka", msg(ambiguous, grid))
    end

    @testset "failed solves: objective penalty, score error" begin
        failing = overrides -> pk_scan(overrides; maxiters = 2)
        @test !any(r -> TargKit.SciMLBase.successful_retcode(r.result.sol), failing((CL = 1.0,)))

        ts = TargetSet(DataFrame(dose = [10.0], Conc = [1.0]); value = :Conc) => Match(:dose; at = :TIME => 2.0, variable = :Conc)
        obj = objective(ts; simulate = failing, params = [:CL], bounds = (lb = [0.1], ub = [10.0]))
        @test obj(log.([1.0])) == 1e10
        @test_throws MatchError score(ts; sim = failing((CL = 1.0,)))
    end

    @testset "fit CL from concentrations at several doses and times" begin
        truth = pk_scan((CL = 2.0,))
        times = [1.0, 2.0, 4.0, 7.0, 9.0]   # avoids the dose at t = 5
        rows = [(dose = d, TIME = tt, Conc = conc_at(truth, d, tt)) for d in [10.0, 20.0] for tt in times]
        ts = TargetSet(DataFrame(rows); value = :Conc)

        result = fit(ts; simulate = pk_scan, match = :dose, at = :TIME, variable = :Conc,
            params = [:CL], bounds = (lb = [0.1], ub = [10.0]), x0 = [1.0], strategy = :nm, verbose = false)
        @test result.params[:CL] ≈ 2.0 rtol=1e-3
        @test result.loss < 1e-8
    end
end
