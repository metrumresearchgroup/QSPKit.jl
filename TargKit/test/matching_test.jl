using Test
using QSPKit.TargKit
using QSPKit.TargKit: MatchError, KeyedResults
using DataFrames

match_message(f) = try
    f()
    ""
catch e
    e isa MatchError || rethrow()
    sprint(showerror, e)
end

@testset verbose=true "TargKit matching (Match: keys / at / variable)" begin

    @testset "one row per dose, matched on a dose column" begin
        ts = TargetSet(DataFrame(dose = [10.0, 100.0], response = [20.0, 60.0]); value = :response)
        @test ts.auto_names
        @test :dose in propertynames(ts.df)

        sim = DataFrame(dose = [100.0, 10.0, 1.0], response = [60.0, 20.0, 5.0])
        report = score(ts; sim = sim, match = :dose, variable = :response)
        @test report.details.predicted == [20.0, 60.0]
        @test report.total_loss ≈ 0.0 atol=1e-12
        @test report.details.name == [Symbol("dose=10.0"), Symbol("dose=100.0")]   # named after the keys

        # Numbers match approximately (unit conversions), Int matches Float
        converted = DataFrame(dose = [0.1 + 0.2, 100.0], response = [20.0, 60.0])
        ts_conv = TargetSet(DataFrame(dose = [0.3, 100], response = [20.0, 60.0]); value = :response)
        @test score(ts_conv; sim = converted, match = :dose, variable = :response).details.predicted == [20.0, 60.0]

        # Given names are kept
        named = TargetSet(DataFrame(name = [:low, :high], dose = [10.0, 100.0], response = [20.0, 60.0]); value = :response)
        @test score(named; sim = sim, match = :dose, variable = :response).details.name == [:low, :high]
    end

    @testset "at: constant, column, renamed column, non-time axis" begin
        sim = DataFrame(
            dose = repeat([10.0, 100.0], inner = 3),
            TIME = repeat([0.0, 24.0, 48.0], outer = 2),
            y = [0.0, 1.0, 2.0, 0.0, 10.0, 20.0],
        )

        constant = TargetSet(DataFrame(dose = [10.0, 100.0], y = [1.0, 10.0]); value = :y)
        report = score(constant; sim = sim, match = :dose, at = :TIME => 24.0, variable = :y)
        @test report.details.predicted == [1.0, 10.0]
        @test report.details.name == [Symbol("dose=10.0"), Symbol("dose=100.0")]

        column = TargetSet(DataFrame(dose = [10.0, 100.0], TIME = [48.0, 24.0], y = [2.0, 10.0]); value = :y)
        report = score(column; sim = sim, match = :dose, at = :TIME, variable = :y)
        @test report.details.predicted == [2.0, 10.0]
        @test report.details.name == [Symbol("dose=10.0,TIME=48.0"), Symbol("dose=100.0,TIME=24.0")]

        renamed = TargetSet(DataFrame(dose = [100.0], TIME_hr = [48.0], y = [20.0]); value = :y)
        @test score(renamed; sim = sim, match = :dose, at = :TIME_hr => :TIME, variable = :y).details.predicted == [20.0]

        # Dose-response curve: dose is the axis, no match keys
        curve = DataFrame(dose = [1.0, 10.0, 100.0], y = [1.0, 5.0, 9.0])
        dr = TargetSet(DataFrame(dose = [10.0, 100.0], y = [5.0, 9.0]); value = :y)
        @test score(dr; sim = curve, at = :dose, variable = :y).details.predicted == [5.0, 9.0]
    end

    @testset "several keys, renamed keys, Symbol/String keys" begin
        sim = DataFrame(donor = [:D1, :D1, :D2, :D2], dose = [10.0, 100.0, 10.0, 100.0], y = [1.0, 2.0, 3.0, 4.0])
        ts = TargetSet(DataFrame(donor_id = ["D2", "D1"], dose = [100.0, 10.0], y = [4.0, 1.0]); value = :y)
        report = score(ts; sim = sim, match = [:donor_id => :donor, :dose], variable = :y)
        @test report.details.predicted == [4.0, 1.0]
        @test report.details.name == [Symbol("donor_id=D2,dose=100.0"), Symbol("donor_id=D1,dose=10.0")]

        filtered = where(ts, :donor_id => "D1")
        @test nrow(filtered) == 1
        @test filtered.auto_names
    end

    @testset "simulated variable: name, measured column, Dict translation" begin
        sim = DataFrame(dose = [10.0, 100.0], Conc = [20.0, 60.0], Effect = [1.0, 5.0])

        observed = TargetSet(DataFrame(dose = [10.0], obs = [20.0]); value = :obs)
        @test score(observed; sim = sim, match = :dose, variable = :Conc).details.predicted == [20.0]

        transformed = TargetSet(DataFrame(dose = [10.0], pct = [2000.0]); value = :pct => (x -> x / 100))
        @test score(transformed; sim = sim, match = :dose, variable = :Conc).details.predicted == [20.0]

        # The variable column already holds simulated names
        long = TargetSet(DataFrame(dose = [10.0, 100.0], analyte = [:Conc, :Effect], DV = [20.0, 5.0]);
            value = :DV, variable = :analyte)
        report = score(long; sim = sim, match = :dose)
        @test report.details.predicted == [20.0, 5.0]
        @test report.details.name == [Symbol("Conc,dose=10.0"), Symbol("Effect,dose=100.0")]

        # Measured names translated to simulated names
        measured = TargetSet(DataFrame(dose = [10.0, 100.0], assay = ["plasma", "biomarker"], DV = [20.0, 5.0]);
            value = :DV, variable = :assay)
        report = score(measured; sim = sim, match = :dose, variable = Dict("plasma" => :Conc, "biomarker" => :Effect))
        @test report.details.predicted == [20.0, 5.0]
        @test report.details.variable == ["plasma", "biomarker"]   # reports keep the measured names
    end

    @testset "keyed results and Dict outputs" begin
        by_donor = KeyedResults([
            Dict(:donor => :D1) => DataFrame(dose = [10.0, 100.0], y = [1.0, 2.0]),
            Dict(:donor => :D2) => DataFrame(dose = [10.0, 100.0], y = [3.0, 4.0]),
        ])
        ts = TargetSet(DataFrame(donor = [:D2, :D1], dose = [10.0, 100.0], y = [3.0, 2.0]); value = :y)
        @test score(ts; sim = by_donor, match = [:donor, :dose], variable = :y).details.predicted == [3.0, 2.0]

        by_dose = Dict(10.0 => DataFrame(TIME = [0.0, 24.0], y = [0.0, 7.0]))
        ts_dict = TargetSet(DataFrame(dose = [10.0], y = [7.0]); value = :y)
        @test score(ts_dict; sim = by_dose, match = :dose, at = :TIME => 24.0, variable = :y).details.predicted == [7.0]
    end

    @testset "several TargetSets, each with its own mapping and loss" begin
        sim = DataFrame(dose = [10.0, 100.0], Conc = [2.0, 20.0], Effect = [0.5, 0.9])
        pk = TargetSet(DataFrame(dose = [10.0, 100.0], conc = [2.0, 20.0]); value = :conc, loss = :squared)
        pd = TargetSet(DataFrame(dose_mg = [100.0], effect = [0.9]); value = :effect, loss = (p, o, w) -> 7.0)

        report = score(pk => Match(:dose; variable = :Conc),
                       pd => Match(:dose_mg => :dose; variable = :Effect); sim = sim)
        @test report.details.predicted == [2.0, 20.0, 0.9]
        @test report.details.loss == [0.0, 0.0, 7.0]   # each TargetSet keeps its loss

        # predict functions pair the same way
        report = score(pk => Match(:dose; variable = :Conc), pd => (s, row) -> 0.9; sim = sim)
        @test report.details.predicted[3] == 0.9

        # objective and fit honor each TargetSet's loss too; `loss` overrides them
        obj = objective(pk => Match(:dose; variable = :Conc), pd => Match(:dose_mg => :dose; variable = :Effect);
            simulate = p -> sim, params = [:a], bounds = (lb = [0.1], ub = [10.0]))
        @test obj(log.([1.0])) ≈ 7.0
        overridden = objective(pk => Match(:dose; variable = :Conc), pd => Match(:dose_mg => :dose; variable = :Effect);
            simulate = p -> sim, params = [:a], bounds = (lb = [0.1], ub = [10.0]), loss = :squared)
        @test overridden(log.([1.0])) ≈ 0.0 atol=1e-12
        state = setup(pd; simulate = p -> sim, match = :dose_mg => :dose, variable = :Effect,
            params = [:a], bounds = (lb = [0.1], ub = [10.0]), verbose = false)
        @test state.loss ≈ 7.0

        # The final report stacks TargetSets with different columns (dose vs dose_mg)
        result = fit(pk => Match(:dose; variable = :Conc), pd => Match(:dose_mg => :dose; variable = :Effect);
            simulate = p -> sim, params = [:a], bounds = (lb = [0.1], ub = [10.0]), strategy = :nm, verbose = false)
        @test nrow(result.report.details) == 3
        @test isequal(result.report.details.dose_mg, [missing, missing, 100.0])
    end

    @testset "match errors" begin
        sim = DataFrame(
            dose = repeat([10.0, 100.0], inner = 2),
            TIME = repeat([0.0, 24.0], outer = 2),
            y = [0.0, 1.0, 0.0, 10.0],
        )
        at24 = (; match = :dose, at = :TIME => 24.0, variable = :y)
        target(dose) = TargetSet(DataFrame(dose = [dose], y = [1.0]); value = :y)

        # No simulated dose
        msg = match_message(() -> score(target(30.0); sim = sim, at24...))
        @test occursin("no simulation row has dose = 30.0", msg)
        @test occursin("dose = 10.0", msg) && occursin("dose = 100.0", msg)

        # Point not in the output
        msg = match_message(() -> score(target(10.0); sim = sim, match = :dose, at = :TIME => 30.0, variable = :y))
        @test occursin("no simulation row at TIME = 30.0 for dose = 10.0", msg)
        @test occursin("output ends at TIME = 24.0", msg)

        # Several rows and no `at`
        msg = match_message(() -> score(target(10.0); sim = sim, match = :dose, variable = :y))
        @test occursin("2 simulation rows match", msg)
        @test occursin(":TIME", msg) && occursin("Use `at`", msg)

        # A missing identifier column
        two_donors = DataFrame(dose = [10.0, 10.0], donor = [:D1, :D2], TIME = [24.0, 24.0], y = [1.0, 2.0])
        @test occursin("They differ in :donor", match_message(() -> score(target(10.0); sim = two_donors, at24...)))

        # Duplicate points at the same time (before/after a dose)
        dup = DataFrame(dose = [10.0, 10.0], TIME = [24.0, 24.0], y = [1.0, 11.0])
        msg = match_message(() -> score(target(10.0); sim = dup, at24...))
        @test occursin("They differ in :y", msg)
        @test occursin("before and after a dose", msg)

        # Columns missing from the simulation output
        @test occursin("no column :dose",
            match_message(() -> score(target(10.0); sim = select(sim, Not(:dose)), at24...)))
        @test occursin("no column :y to compare with",
            match_message(() -> score(target(10.0); sim = select(sim, Not(:y)), at24...)))

        # Keyed results with a key the targets do not match on
        keyed = KeyedResults([Dict(:dose => 10.0, :ka => 0.1) => sim, Dict(:dose => 10.0, :ka => 1.0) => sim])
        msg = match_message(() -> score(target(10.0); sim = keyed, at24...))
        @test occursin("2 simulation results match", msg) && occursin("differ in :ka", msg)

        # Unsupported output
        @test occursin("cannot match targets against a simulation output of type Int",
            match_message(() -> score(target(10.0); sim = 3, at24...)))
    end

    @testset "mapping errors" begin
        ts = TargetSet(DataFrame(dose = [10.0], y = [1.0]); value = :y)
        sim = DataFrame(dose = [10.0], y = [1.0])

        # No mapping at all, or two
        @test_throws ArgumentError score(ts; sim = sim)
        @test_throws ArgumentError score(ts; sim = sim, match = :dose, variable = :y, predict = (s, r) -> 1.0)
        @test_throws ArgumentError objective(ts; simulate = p -> sim, match = :dose, variable = :y,
            predict = (s, r) -> 1.0, params = [:a], bounds = (lb = [0.1], ub = [10.0]))

        # Columns the Match names must exist and be complete
        @test_throws ArgumentError score(ts; sim = sim, match = :nope, variable = :y)
        @test_throws ArgumentError score(ts; sim = sim, match = :dose, at = :nope, variable = :y)
        with_missing = TargetSet(DataFrame(dose = [10.0, missing], y = [1.0, 2.0]); value = :y)
        @test_throws ArgumentError score(with_missing; sim = sim, match = :dose, variable = :y)

        # Match arguments
        @test_throws ArgumentError Match(:dose; at = :dose => (x -> 2x))
        @test_throws ArgumentError Match(:dose; variable = "y")
        @test_throws ArgumentError Match(42)

        # The simulated variable
        @test_throws ArgumentError score(ts; sim = sim, match = :dose)   # neither `variable` nor a column
        long = TargetSet(DataFrame(dose = [10.0], analyte = ["plasma"], y = [1.0]); value = :y, variable = :analyte)
        @test_throws ArgumentError score(long; sim = sim, match = :dose, variable = :y)   # column present: use a Dict
        @test_throws ArgumentError score(long; sim = sim, match = :dose, variable = Dict("biomarker" => :y))   # plasma unmapped
        @test_throws ArgumentError score(ts; sim = sim, match = :dose, variable = Dict("plasma" => :y))   # no column

        # Series values need one row per point
        series = TargetSet(DataFrame(dose = [10.0], y = [(t = [1.0], y = [2.0])]); value = :y)
        @test_throws ArgumentError score(series; sim = sim, match = :dose, variable = :y)

        # The mapping is not part of the TargetSet
        @test_throws MethodError TargetSet(DataFrame(dose = [10.0], y = [1.0]); value = :y, match = :dose)
        @test_throws MethodError TargetSet(DataFrame(dose = [10.0], y = [1.0]); value = :y, at = :TIME => 1.0)
        @test_throws MethodError TargetSet(DataFrame(dose = [10.0], y = [1.0]); value = :y, condition = :dose)

        # Roles naming columns that do not exist are errors, not silently skipped
        @test_throws ArgumentError TargetSet(DataFrame(value = [1.0]); variable = :analyte)
        @test_throws ArgumentError TargetSet(DataFrame(value = [1.0], obs = [2.0]); value = :obs)
        @test TargetSet(DataFrame(value = [1.0])) isa TargetSet   # default optional roles
    end

    @testset "fit against a table output" begin
        doses = [1.0, 10.0, 100.0]
        ts = TargetSet(DataFrame(dose = doses, y = 2.0 .* doses); value = :y)
        sim_fn = p -> DataFrame(dose = reverse(doses), y = p.a .* reverse(doses))

        result = fit(ts; simulate = sim_fn, match = :dose, variable = :y,
            params = [:a], bounds = (lb = [0.1], ub = [10.0]), x0 = [1.0], strategy = :nm, verbose = false)
        @test result.params[:a] ≈ 2.0 rtol=1e-3
        @test Float64.(result.report.details.predicted) ≈ 2.0 .* doses rtol=1e-3

        # The same fit through a pair
        paired = fit(ts => Match(:dose; variable = :y); simulate = sim_fn,
            params = [:a], bounds = (lb = [0.1], ub = [10.0]), x0 = [1.0], strategy = :nm, verbose = false)
        @test paired.params[:a] ≈ result.params[:a]

        # Without a mapping, or with one that does not fit the output, setup stops first
        @test_throws ArgumentError setup(ts; simulate = sim_fn, params = [:a],
            bounds = (lb = [0.1], ub = [10.0]), verbose = false)
        missing_dose = TargetSet(DataFrame(dose = [30.0], y = [60.0]); value = :y)
        @test_throws MatchError setup(missing_dose; simulate = sim_fn, match = :dose, variable = :y,
            params = [:a], bounds = (lb = [0.1], ub = [10.0]), verbose = false)

        # `simulate` returning nothing still applies the failure penalty
        obj = objective(ts; simulate = p -> nothing, match = :dose, variable = :y,
            params = [:a], bounds = (lb = [0.1], ub = [10.0]))
        @test obj(log.([1.0])) == 1e10
    end

    @testset "show" begin
        m = Match(:donor_id => :donor, :dose; at = :TIME => 24.0, variable = :y)
        @test sprint(show, m) == "Match(:donor_id => :donor, :dose; at = :TIME => 24.0, variable = :y)"
        @test sprint(show, Match(; at = :TIME_hr => :TIME)) == "Match(; at = :TIME_hr => :TIME)"
    end
end
