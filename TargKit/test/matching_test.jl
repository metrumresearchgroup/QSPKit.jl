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

@testset verbose=true "TargKit matching (match / at)" begin

    @testset "one row per dose, matched on a dose column" begin
        targets_df = DataFrame(dose = [10.0, 100.0], response = [20.0, 60.0])
        ts = TargetSet(targets_df; match = :dose, value = :response)

        @test ts.match isa TargKit.MatchSpec
        @test ts.match.variable == :response
        @test ts.name == [Symbol("dose=10.0"), Symbol("dose=100.0")]
        @test :dose in propertynames(ts.df)

        sim = DataFrame(dose = [100.0, 10.0, 1.0], response = [60.0, 20.0, 5.0])
        report = score(ts; sim = sim)
        @test report.details.predicted == [20.0, 60.0]
        @test report.total_loss ≈ 0.0 atol=1e-12

        # Numbers match approximately (unit conversions), Int matches Float
        converted = DataFrame(dose = [0.1 + 0.2, 100.0], response = [20.0, 60.0])
        ts_conv = TargetSet(DataFrame(dose = [0.3, 100], response = [20.0, 60.0]);
            match = :dose, value = :response)
        @test score(ts_conv; sim = converted).details.predicted == [20.0, 60.0]
    end

    @testset "at: constant, column, renamed column, non-time axis" begin
        sim = DataFrame(
            dose = repeat([10.0, 100.0], inner = 3),
            TIME = repeat([0.0, 24.0, 48.0], outer = 2),
            y = [0.0, 1.0, 2.0, 0.0, 10.0, 20.0],
        )

        constant = TargetSet(DataFrame(dose = [10.0, 100.0], y = [1.0, 10.0]);
            match = :dose, value = :y, at = :TIME => 24.0)
        @test score(constant; sim = sim).details.predicted == [1.0, 10.0]
        @test constant.name == [Symbol("dose=10.0"), Symbol("dose=100.0")]

        column = TargetSet(DataFrame(dose = [10.0, 100.0], TIME = [48.0, 24.0], y = [2.0, 10.0]);
            match = :dose, value = :y, at = :TIME)
        @test score(column; sim = sim).details.predicted == [2.0, 10.0]
        @test column.name == [Symbol("dose=10.0,TIME=48.0"), Symbol("dose=100.0,TIME=24.0")]

        renamed = TargetSet(DataFrame(dose = [100.0], TIME_hr = [48.0], y = [20.0]);
            match = :dose, value = :y, at = :TIME_hr => :TIME)
        @test score(renamed; sim = sim).details.predicted == [20.0]

        # Dose-response curve: dose is the axis, no match keys
        curve = DataFrame(dose = [1.0, 10.0, 100.0], y = [1.0, 5.0, 9.0])
        dr = TargetSet(DataFrame(dose = [10.0, 100.0], y = [5.0, 9.0]); value = :y, at = :dose)
        @test score(dr; sim = curve).details.predicted == [5.0, 9.0]
    end

    @testset "several match keys, renamed keys, Symbol/String keys" begin
        sim = DataFrame(donor = [:D1, :D1, :D2, :D2], dose = [10.0, 100.0, 10.0, 100.0], y = [1.0, 2.0, 3.0, 4.0])
        ts = TargetSet(DataFrame(donor_id = ["D2", "D1"], dose = [100.0, 10.0], y = [4.0, 1.0]);
            match = [:donor_id => :donor, :dose], value = :y)
        @test score(ts; sim = sim).details.predicted == [4.0, 1.0]
        @test ts.name == [Symbol("donor_id=D2,dose=100.0"), Symbol("donor_id=D1,dose=10.0")]
        @test nrow(where(ts, :donor_id => "D1")) == 1
        @test where(ts, :donor_id => "D1").match === ts.match
    end

    @testset "simulated variable: value => :simvar and per-row variable column" begin
        sim = DataFrame(dose = [10.0, 100.0], Conc = [20.0, 60.0], Effect = [1.0, 5.0])

        named = TargetSet(DataFrame(dose = [10.0], obs = [20.0]); match = :dose, value = :obs => :Conc)
        @test named.match.variable == :Conc
        @test score(named; sim = sim).details.predicted == [20.0]

        transformed = TargetSet(DataFrame(dose = [10.0], pct = [2000.0]);
            match = :dose, value = :pct => (x -> x / 100) => :Conc)
        @test transformed.df.value == [20.0]
        @test score(transformed; sim = sim).details.predicted == [20.0]

        long = TargetSet(DataFrame(dose = [10.0, 100.0], analyte = [:Conc, :Effect], DV = [20.0, 5.0]);
            match = :dose, value = :DV, variable = :analyte)
        @test long.match.variable === nothing
        @test score(long; sim = sim).details.predicted == [20.0, 5.0]
        @test long.name == [Symbol("Conc,dose=10.0"), Symbol("Effect,dose=100.0")]
    end

    @testset "keyed results and Dict outputs" begin
        by_donor = KeyedResults([
            Dict(:donor => :D1) => DataFrame(dose = [10.0, 100.0], y = [1.0, 2.0]),
            Dict(:donor => :D2) => DataFrame(dose = [10.0, 100.0], y = [3.0, 4.0]),
        ])
        ts = TargetSet(DataFrame(donor = [:D2, :D1], dose = [10.0, 100.0], y = [3.0, 2.0]);
            match = [:donor, :dose], value = :y)
        @test score(ts; sim = by_donor).details.predicted == [3.0, 2.0]

        by_dose = Dict(10.0 => DataFrame(TIME = [0.0, 24.0], y = [0.0, 7.0]))
        ts_dict = TargetSet(DataFrame(dose = [10.0], y = [7.0]); match = :dose, value = :y, at = :TIME => 24.0)
        @test score(ts_dict; sim = by_dose).details.predicted == [7.0]
    end

    @testset "match errors" begin
        sim = DataFrame(
            dose = repeat([10.0, 100.0], inner = 2),
            TIME = repeat([0.0, 24.0], outer = 2),
            y = [0.0, 1.0, 0.0, 10.0],
        )
        at24 = (; match = :dose, value = :y, at = :TIME => 24.0)

        # No simulated dose
        msg = match_message(() -> score(TargetSet(DataFrame(dose = [30.0], y = [1.0]); at24...); sim = sim))
        @test occursin("no simulation row has dose = 30.0", msg)
        @test occursin("dose = 10.0", msg) && occursin("dose = 100.0", msg)

        # Point not in the output
        msg = match_message(() -> score(TargetSet(DataFrame(dose = [10.0], y = [1.0]);
            match = :dose, value = :y, at = :TIME => 30.0); sim = sim))
        @test occursin("no simulation row at TIME = 30.0 for dose = 10.0", msg)
        @test occursin("output ends at TIME = 24.0", msg)

        # Several rows and no `at`
        msg = match_message(() -> score(TargetSet(DataFrame(dose = [10.0], y = [1.0]); match = :dose, value = :y); sim = sim))
        @test occursin("2 simulation rows match", msg)
        @test occursin(":TIME", msg) && occursin("Use `at`", msg)

        # A missing identifier column
        two_donors = DataFrame(dose = [10.0, 10.0], donor = [:D1, :D2], TIME = [24.0, 24.0], y = [1.0, 2.0])
        msg = match_message(() -> score(TargetSet(DataFrame(dose = [10.0], y = [1.0]); at24...); sim = two_donors))
        @test occursin("They differ in :donor", msg)

        # Duplicate points at the same time (before/after a dose)
        dup = DataFrame(dose = [10.0, 10.0], TIME = [24.0, 24.0], y = [1.0, 11.0])
        msg = match_message(() -> score(TargetSet(DataFrame(dose = [10.0], y = [1.0]); at24...); sim = dup))
        @test occursin("They differ in :y", msg)
        @test occursin("before and after a dose", msg)

        # Columns missing from the simulation output
        @test occursin("no column :dose",
            match_message(() -> score(TargetSet(DataFrame(dose = [10.0], y = [1.0]); at24...); sim = select(sim, Not(:dose)))))
        @test occursin("no column :y to compare with",
            match_message(() -> score(TargetSet(DataFrame(dose = [10.0], y = [1.0]); at24...); sim = select(sim, Not(:y)))))

        # Keyed results with a key the targets do not match on
        keyed = KeyedResults([Dict(:dose => 10.0, :ka => 0.1) => sim, Dict(:dose => 10.0, :ka => 1.0) => sim])
        msg = match_message(() -> score(TargetSet(DataFrame(dose = [10.0], y = [1.0]); at24...); sim = keyed))
        @test occursin("2 simulation results match", msg) && occursin("differ in :ka", msg)

        # Unsupported output
        @test occursin("cannot match targets against a simulation output of type Int",
            match_message(() -> score(TargetSet(DataFrame(dose = [10.0], y = [1.0]); at24...); sim = 3)))
    end

    @testset "construction errors" begin
        df = DataFrame(dose = [10.0], y = [1.0])
        @test_throws ArgumentError TargetSet(df; match = :dose, value = :y, condition = :dose)
        @test_throws ArgumentError TargetSet(df; at = :TIME => 1.0, value = :y, timepoint = :dose)
        @test_throws ArgumentError TargetSet(df; match = :nope, value = :y)
        @test_throws ArgumentError TargetSet(df; match = :dose, value = :y, at = :nope)
        @test_throws ArgumentError TargetSet(df; match = :dose, value = :y, at = :dose => (x -> 2x))
        @test_throws ArgumentError TargetSet(DataFrame(dose = [10.0, missing], y = [1.0, 2.0]); match = :dose, value = :y)
        # :value alone does not name a simulated variable
        @test_throws ArgumentError TargetSet(DataFrame(dose = [10.0], value = [1.0]); match = :dose)
        @test TargetSet(DataFrame(dose = [10.0], value = [1.0]); match = :dose, value = :value => :y).match.variable == :y
        # Series values need one row per point
        @test_throws ArgumentError TargetSet(DataFrame(dose = [10.0], y = [(t = [1.0], y = [2.0])]); match = :dose, value = :y)
        # Variable named twice
        @test_throws ArgumentError TargetSet(DataFrame(dose = [10.0], analyte = [:a], y = [1.0]);
            match = :dose, value = :y => :b, variable = :analyte)

        # Roles naming columns that do not exist are errors, not silently skipped
        @test_throws ArgumentError TargetSet(DataFrame(value = [1.0]); variable = :analyte)
        @test_throws ArgumentError TargetSet(DataFrame(value = [1.0], obs = [2.0]); value = :obs)
        @test TargetSet(DataFrame(value = [1.0])) isa TargetSet   # default optional roles
    end

    @testset "predict cannot be combined with match" begin
        ts = TargetSet(DataFrame(dose = [10.0], y = [1.0]); match = :dose, value = :y)
        sim = DataFrame(dose = [10.0], y = [1.0])
        @test_throws ArgumentError score(ts; sim = sim, predict = (s, r) -> 1.0)
        @test_throws ArgumentError objective(ts;
            simulate = p -> sim, predict = (s, r) -> 1.0, params = [:a], bounds = (lb = [0.1], ub = [10.0]))
    end

    @testset "fit against a table output" begin
        doses = [1.0, 10.0, 100.0]
        ts = TargetSet(DataFrame(dose = doses, y = 2.0 .* doses); match = :dose, value = :y)
        sim_fn = p -> DataFrame(dose = reverse(doses), y = p.a .* reverse(doses))

        result = fit(ts; simulate = sim_fn, params = [:a], bounds = (lb = [0.1], ub = [10.0]),
            x0 = [1.0], strategy = :nm, verbose = false)
        @test result.params[:a] ≈ 2.0 rtol=1e-3
        @test result.report.details.predicted ≈ 2.0 .* doses rtol=1e-3

        # A target with no simulated counterpart stops setup before any optimization
        missing_dose = TargetSet(DataFrame(dose = [30.0], y = [60.0]); match = :dose, value = :y)
        @test_throws MatchError setup(missing_dose; simulate = sim_fn, params = [:a],
            bounds = (lb = [0.1], ub = [10.0]), verbose = false)

        # `simulate` returning nothing still applies the failure penalty
        obj = objective(ts; simulate = p -> nothing, params = [:a], bounds = (lb = [0.1], ub = [10.0]))
        @test obj(log.([1.0])) == 1e10
    end

    @testset "show" begin
        ts = TargetSet(DataFrame(donor_id = [:D1], dose = [10.0], y = [1.0]);
            match = [:donor_id => :donor, :dose], value = :y, at = :TIME => 24.0)
        shown = sprint(show, MIME("text/plain"), ts)
        @test occursin("match=[:donor_id => :donor, :dose]", shown)
        @test occursin("at=:TIME => 24.0", shown)
        @test occursin("variable=:y", shown)
    end
end
