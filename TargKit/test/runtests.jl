using Test
using QSPKit.TargKit
using DataFrames
using Optimization
using OptimizationOptimJL

struct FakeSolution
    slope::Float64
    intercept::Float64
end

(sol::FakeSolution)(t; idxs) = sol.slope .* t .+ sol.intercept

struct FakeSolutionWithNaNProperty
    slope::Float64
    intercept::Float64
end

(sol::FakeSolutionWithNaNProperty)(t; idxs) = sol.slope .* t .+ sol.intercept

function Base.getproperty(sol::FakeSolutionWithNaNProperty, name::Symbol)
    name === :slope && return getfield(sol, :slope)
    name === :intercept && return getfield(sol, :intercept)
    return NaN
end

@testset verbose=true "TargKit" begin

    # ============================================================
    # 1. targets() convenience constructor
    # ============================================================
    @testset "targets()" begin
        @testset "basic construction" begin
            df = targets(
                Blood_Eos = (2.5, 1.5, 4.0),
                FeNO      = (40.0, 25.0, 55.0),
            )
            @test df isa DataFrame
            @test nrow(df) == 2
            @test :name in propertynames(df)
            @test :value in propertynames(df)
            @test :lower in propertynames(df)
            @test :upper in propertynames(df)
        end

        @testset "values are correct" begin
            df = targets(Blood_Eos = (2.5, 1.5, 4.0))
            @test df.name[1] == :Blood_Eos
            @test df.value[1] == 2.5
            @test df.lower[1] == 1.5
            @test df.upper[1] == 4.0
        end

        @testset "scalar-only (no range)" begin
            df = targets(x = 5.0)
            @test df.value[1] == 5.0
            @test isnan(df.lower[1])
            @test isnan(df.upper[1])
        end

        @testset "empty" begin
            df = targets()
            @test nrow(df) == 0
            @test :name in propertynames(df)
        end

        @testset "Int -> Float64 conversion" begin
            df = targets(x = (2, 1, 3))
            @test df.value[1] === 2.0
            @test df.lower[1] === 1.0
        end
    end

    # ============================================================
    # 2. compute_loss
    # ============================================================
    @testset "compute_loss" begin
        @testset "log loss" begin
            loss = TargKit.compute_loss(2.5, 2.5, :log, 1.0)
            @test loss ≈ 0.0 atol=1e-12
        end

        @testset "log loss nonzero" begin
            loss = TargKit.compute_loss(5.0, 2.5, :log, 1.0)
            @test loss ≈ (log(5.0) - log(2.5))^2
        end

        @testset "log loss with weight" begin
            loss = TargKit.compute_loss(5.0, 2.5, :log, 2.0)
            @test loss ≈ 2.0 * (log(5.0) - log(2.5))^2
        end

        @testset "squared loss" begin
            loss = TargKit.compute_loss(3.0, 2.0, :squared, 1.0)
            @test loss ≈ 1.0
        end

        @testset "singleton predictions for scalar targets" begin
            @test TargKit.compute_loss([2.5], 2.5, :log, 1.0) ≈ 0.0 atol=1e-12
            @test TargKit.compute_loss([3.0], 2.0, :squared, 1.0) ≈ 1.0
            @test TargKit.compute_loss([NaN], 2.0, :squared, 1.0) == 1e6

            err = try
                TargKit.compute_loss([2.0, 3.0], 2.5, :log, 1.0)
                nothing
            catch caught
                caught
            end
            @test err isa DimensionMismatch
            @test occursin("returned 2 values with size (2,)", sprint(showerror, err))
            @test occursin("encode the target as a series", sprint(showerror, err))
        end

        @testset "NaN/Inf penalty" begin
            @test TargKit.compute_loss(NaN, 2.5, :log, 1.0) == 1e6
            @test TargKit.compute_loss(Inf, 2.5, :log, 1.0) == 1e6
        end

        @testset "negative value penalty for log" begin
            @test TargKit.compute_loss(-1.0, 2.5, :log, 1.0) == 1e6
        end

        @testset "series_log" begin
            value = (t=[0.0, 7.0], y=[1.0, 0.5])
            pred = [1.0, 0.5]
            loss = TargKit.compute_loss(pred, value, :series_log, 1.0)
            @test loss ≈ 0.0 atol=1e-12
        end

        @testset "series_mse" begin
            value = (t=[0.0, 7.0], y=[1.0, 2.0])
            pred = [1.0, 3.0]
            loss = TargKit.compute_loss(pred, value, :series_mse, 1.0)
            @test loss ≈ 0.5  # mean([0, 1])
        end

        @testset "custom loss function" begin
            custom = (pred, obs, w) -> w * abs(pred - obs)
            loss = TargKit.compute_loss(5.0, 3.0, custom, 2.0)
            @test loss ≈ 4.0
        end
    end

    # ============================================================
    # 3. compute_loss_range_only
    # ============================================================
    @testset "compute_loss_range_only" begin
        @test TargKit.compute_loss_range_only(2.5, 1.0, 4.0, 1.0) == 0.0
        @test TargKit.compute_loss_range_only([2.5], 1.0, 4.0, 1.0) == 0.0
        @test TargKit.compute_loss_range_only(0.5, 1.0, 4.0, 1.0) ≈ 0.25
        @test TargKit.compute_loss_range_only(5.0, 1.0, 4.0, 1.0) ≈ 1.0
    end

    # ============================================================
    # 4. score() — v2 Pair syntax
    # ============================================================
    @testset "score() — Pair syntax" begin
        @testset "basic scalar scoring" begin
            df = targets(x = (2.0, 1.0, 3.0), y = (4.0, 3.0, 5.0))
            ctx = (vals = Dict(:x => 2.0, :y => 4.0),)
            predict_fn = (ctx, row) -> ctx.vals[row.name]

            report = score(df => predict_fn; ctx=ctx)
            @test report isa ScoreReport
            @test report.total_loss ≈ 0.0 atol=1e-12
            @test report.n_met == 2
            @test report.n_total == 2
            @test nrow(report.details) == 2
        end

        @testset "out-of-range detection" begin
            df = targets(x = (2.0, 1.0, 3.0))
            ctx = (val = 5.0,)
            predict_fn = (ctx, row) -> ctx.val

            report = score(df => predict_fn; ctx=ctx)
            @test report.n_met == 0
            @test report.n_total == 1
            @test report.details.in_range[1] == false
        end

        @testset "no range → in_range is nothing" begin
            df = DataFrame(name=[:x], value=[2.0])
            ctx = (val = 2.0,)
            predict_fn = (ctx, row) -> ctx.val

            report = score(df => predict_fn; ctx=ctx)
            @test report.details.in_range[1] === nothing
            @test report.n_total == 0
        end

        @testset "multiple target pairs" begin
            df1 = targets(a = (1.0, 0.5, 1.5))
            df2 = targets(b = (2.0, 1.5, 2.5))
            ctx = (vals = Dict(:a => 1.0, :b => 2.0),)
            predict = (ctx, row) -> ctx.vals[row.name]

            report = score(df1 => predict, df2 => predict; ctx=ctx)
            @test report.n_met == 2
            @test report.n_total == 2
            @test nrow(report.details) == 2
        end

        @testset "metadata columns preserved" begin
            df = DataFrame(
                name = [:x],
                value = [2.0],
                lower = [1.0],
                upper = [3.0],
                drug = [:mepo],
                species = [:eos],
            )
            ctx = nothing
            report = score(df => (ctx, row) -> 2.0; ctx=ctx)
            @test :drug in propertynames(report.details)
            @test report.details.drug[1] == :mepo
        end

        @testset "per-row loss override" begin
            df = DataFrame(
                name = [:x, :y],
                value = [2.0, 3.0],
                loss = [:log, :squared],
            )
            ctx = (vals = Dict(:x => 2.0, :y => 4.0),)
            report = score(df => (ctx, row) -> ctx.vals[row.name]; ctx=ctx)
            @test report.details.loss[1] ≈ 0.0 atol=1e-12
            @test report.details.loss[2] ≈ 1.0
        end

        @testset "per-row weight" begin
            df = DataFrame(
                name = [:x],
                value = [1.0],
                weight = [3.0],
            )
            report = score(df => (ctx, row) -> 2.0; ctx=nothing)
            @test report.details.loss[1] ≈ 3.0 * (log(2.0) - log(1.0))^2
        end

        @testset "series auto-detect" begin
            df = DataFrame(
                name = [:curve],
                value = [(t=[0.0, 7.0], y=[1.0, 0.5])],
            )
            report = score(df => (ctx, row) -> [1.0, 0.5]; ctx=nothing)
            @test report.details.loss[1] ≈ 0.0 atol=1e-12
        end
    end

    # ============================================================
    # 5. objective() + evaluation
    # ============================================================
    @testset "objective()" begin
        df = targets(x = (10.0, 5.0, 15.0))
        predict_fn = (ctx, row) -> ctx.val

        obj = objective(
            df => predict_fn;
            simulate = overrides -> (val = overrides[:p],),
            params = [:p],
            bounds = (lb = [5.0], ub = [15.0]),
        )
        @test obj isa TargKit.ObjectiveFunction
        @test obj.on_eval === nothing

        # Evaluate at the target value
        loss = obj(log.([10.0]))
        @test loss ≈ 0.0 atol=1e-12
        @test obj._eval_count[] == 0

        # Evaluate at a different value
        loss2 = obj(log.([5.0]))
        @test loss2 > 0
    end

    @testset "objective bounds_penalty" begin
        df = targets(x = (10.0, 5.0, 15.0))
        obj = objective(
            df => (ctx, row) -> ctx.val;
            simulate = overrides -> (val = overrides[:p],),
            params = [:p],
            bounds = (lb = [5.0], ub = [15.0]),
            bounds_penalty = 1e4,
            on_eval = nothing,
        )
        loss = obj(log.([100.0]))
        @test loss > 1e6
    end

    @testset "objective failure_penalty" begin
        df = targets(x = (10.0, 5.0, 15.0))
        obj = objective(
            df => (ctx, row) -> ctx.val;
            simulate = overrides -> nothing,
            params = [:p],
            bounds = (lb = [5.0], ub = [15.0]),
            on_eval = nothing,
        )
        @test obj(log.([10.0])) == 1e10
    end

    @testset "reset!" begin
        df = targets(x = (10.0, 5.0, 15.0))
        obj = objective(
            df => (ctx, row) -> ctx.val;
            simulate = overrides -> (val = overrides[:p],),
            params = [:p],
            bounds = (lb = [5.0], ub = [15.0]),
            on_eval = (_, _, _, _) -> nothing,
        )
        obj(log.([10.0]))
        @test obj._eval_count[] == 1
        reset!(obj)
        @test obj._eval_count[] == 0
        @test obj._best_loss[] == Inf
    end

    # ============================================================
    # 6. Stage
    # ============================================================
    @testset "Stage" begin
        s = Stage(NelderMead(); maxiters=100)
        @test s.maxiters == 100
        @test s.restarts == 1

        s2 = Stage(ParticleSwarm(n_particles=10); maxiters=50, restarts=3)
        @test s2.restarts == 3
    end

    # ============================================================
    # 7. fit() — Pair syntax
    # ============================================================
    @testset "fit() — Pair syntax" begin
        df = DataFrame(name = [:sum_val], value = [2.0])
        predict_fn = (ctx, row) -> ctx.result

        @testset "NelderMead only" begin
            result = fit(
                df => predict_fn;
                simulate = overrides -> (result = overrides[:a] + overrides[:b],),
                params = [:a, :b],
                bounds = (lb = [0.1, 0.1], ub = [5.0, 5.0]),
                x0 = [1.0, 1.0],
                strategy = :nm,
                on_eval = nothing,
                verbose = false,
            )
            @test result isa FitResult
            @test result.loss < 0.01
            @test result.params[:a] + result.params[:b] ≈ 2.0 atol=0.1
            @test result.method == :nm
        end

        @testset "NelderMead enforces lower bound" begin
            below_bound_df = DataFrame(name = [:value], value = [-1.0])
            result = fit(
                below_bound_df => predict_fn;
                simulate = overrides -> (result = overrides[:a],),
                params = [:a],
                bounds = (lb = [1e-4], ub = [100.0]),
                x0 = [1.0],
                strategy = :nm,
                loss = :squared,
                on_eval = nothing,
                verbose = false,
            )
            @test 1e-4 <= result.params[:a] <= 100.0
        end

        @testset "PSO-NelderMead pipeline preserves bounds" begin
            below_bound_df = DataFrame(name = [:value], value = [-1.0])
            result = fit(
                below_bound_df => predict_fn;
                simulate = overrides -> (result = overrides[:a],),
                params = [:a],
                bounds = (lb = [1e-4], ub = [100.0]),
                x0 = [1.0],
                strategy = [
                    Stage(ParticleSwarm(n_particles=10); maxiters=20),
                    Stage(NelderMead(); maxiters=100),
                ],
                loss = :squared,
                on_eval = nothing,
                verbose = false,
            )
            @test 1e-4 <= result.params[:a] <= 100.0
        end

        @testset "custom Stage pipeline" begin
            result = fit(
                df => predict_fn;
                simulate = overrides -> (result = overrides[:a] + overrides[:b],),
                params = [:a, :b],
                bounds = (lb = [0.1, 0.1], ub = [5.0, 5.0]),
                x0 = [1.0, 1.0],
                strategy = [Stage(NelderMead(); maxiters=200)],
                on_eval = nothing,
                verbose = false,
            )
            @test result.loss < 0.01
            @test result.method == :custom
        end

        @testset "unsupported solver rejects silent bound loss" begin
            obj = objective(
                df => predict_fn;
                simulate = overrides -> (result = overrides[:a],),
                params = [:a],
                bounds = (lb = [0.1], ub = [5.0]),
            )
            @test_throws ArgumentError TargKit._bounded_solver(:unsupported_solver)
        end

        @testset "numerical bound overshoot is projected" begin
            lb = log.([1e-4, 1e-4])
            ub = log.([100.0, 100.0])
            x = [lb[1] - 1e-8, ub[2] + 1e-8]
            projected = TargKit._project_numerical_bound_overshoot(x, lb, ub, NelderMead())
            @test projected == [lb[1], ub[2]]
            @test_throws ErrorException TargKit._project_numerical_bound_overshoot(
                [lb[1] - 1e-3, ub[2]], lb, ub, NelderMead())
        end

        @testset "box solver starts in the interior" begin
            interior = TargKit._box_interior([0.0, 1.0], [0.0, 0.0], [1.0, 1.0])
            @test 0.0 < interior[1] < 1.0
            @test 0.0 < interior[2] < 1.0
        end

        @testset "fit with pre-built objective" begin
            obj = objective(
                df => predict_fn;
                simulate = overrides -> (result = overrides[:a] + overrides[:b],),
                params = [:a, :b],
                bounds = (lb = [0.1, 0.1], ub = [5.0, 5.0]),
                on_eval = nothing,
            )
            result = fit(obj; strategy=:nm, x0=[1.0, 1.0], verbose=false)
            @test result.loss < 0.01
        end
    end

    # ============================================================
    # 8. FitResult report
    # ============================================================
    @testset "FitResult report" begin
        df = targets(x = (2.0, 1.0, 3.0))
        result = fit(
            df => (ctx, row) -> ctx.val;
            simulate = overrides -> (val = overrides[:p],),
            params = [:p],
            bounds = (lb = [1.0], ub = [5.0]),
            x0 = [2.0],
            strategy = :nm,
            on_eval = nothing,
            verbose = false,
        )
        @test !isnothing(result.report)
        @test result.report.n_met == 1
        @test result.report.n_total == 1
        @test nrow(result.report.details) == 1
        @test result.report.details.name[1] == :x
    end

    # ============================================================
    # 9. fingerprint
    # ============================================================
    @testset "fingerprint" begin
        df1 = targets(x = (2.0, 1.0, 3.0))
        df2 = targets(x = (2.0, 1.0, 3.0))
        df3 = targets(x = (3.0, 1.0, 4.0))

        @test fingerprint(df1) == fingerprint(df2)
        @test fingerprint(df1) != fingerprint(df3)
        @test length(fingerprint(df1)) == 16
    end

    # ============================================================
    # 10. Display
    # ============================================================
    @testset "display" begin
        @testset "ScoreReport show" begin
            df = targets(x = (2.0, 1.0, 3.0))
            report = score(df => (ctx, row) -> 2.0; ctx=nothing)
            buf = IOBuffer()
            show(buf, report)
            s = String(take!(buf))
            @test occursin("1/1 targets met", s)
        end

        @testset "ScoreReport text/plain" begin
            df = targets(x = (2.0, 1.0, 3.0), y = (4.0, 3.0, 5.0))
            report = score(
                df => (ctx, row) -> row.name == :x ? 2.0 : 6.0;
                ctx=nothing
            )
            buf = IOBuffer()
            show(buf, MIME"text/plain"(), report)
            s = String(take!(buf))
            @test occursin("MISS", s)
            @test occursin("OK", s)
        end

        @testset "FitResult show" begin
            result = FitResult(Dict(:p => 2.0), 0.001, nothing, true, :nm)
            buf = IOBuffer()
            show(buf, result)
            s = String(take!(buf))
            @test occursin("loss=", s)
            @test occursin(":nm", s)
        end
    end

    # ============================================================
    # 11. Strategy presets
    # ============================================================
    @testset "strategy presets" begin
        @test TargKit._resolve_strategy(:pso_nm) isa Vector{Stage}
        @test length(TargKit._resolve_strategy(:pso_nm)) == 2
        @test TargKit._resolve_strategy(:nm) isa Vector{Stage}
        @test length(TargKit._resolve_strategy(:nm)) == 1
        @test TargKit._resolve_strategy(:lbfgs) isa Vector{Stage}
        @test_throws ErrorException TargKit._resolve_strategy(:bogus)
    end

    # ============================================================
    # 12. Edge cases
    # ============================================================
    @testset "edge cases" begin
        @testset "empty DataFrame" begin
            df = DataFrame(name=Symbol[], value=Float64[])
            report = score(df => (ctx, row) -> 0.0; ctx=nothing)
            @test report.total_loss == 0.0
            @test nrow(report.details) == 0
        end

        @testset "single target" begin
            df = DataFrame(name=[:x], value=[1.0])
            report = score(df => (ctx, row) -> 1.0; ctx=nothing)
            @test report.total_loss ≈ 0.0 atol=1e-12
        end

        @testset "range_only loss" begin
            df = DataFrame(
                name = [:x],
                value = [0.0],
                lower = [1.0],
                upper = [3.0],
                loss = [:range_only],
            )
            report = score(df => (ctx, row) -> 2.0; ctx=nothing)
            @test report.details.loss[1] == 0.0

            report2 = score(df => (ctx, row) -> 4.0; ctx=nothing)
            @test report2.details.loss[1] ≈ 1.0
        end
    end

    # ============================================================
    # 13. TargetSet — Pair syntax constructor
    # ============================================================
    @testset "TargetSet — Pair syntax" begin
        @testset "basic from DataFrame" begin
            df = DataFrame(name=[:x, :y], value=[2.0, 4.0], lower=[1.0, 3.0], upper=[3.0, 5.0])
            ts = TargetSet(df)
            @test nrow(ts) == 2
            @test ts.loss == :log
            @test isnothing(ts.metadata)
            @test ts.df.name == [:x, :y]
        end

        @testset "column rename" begin
            df = DataFrame(obs=[:a, :b], measurement=[1.0, 2.0])
            ts = TargetSet(df; value=:measurement)
            @test :value in propertynames(ts.df)
            @test ts.df.value == [1.0, 2.0]
        end

        @testset "transform via Pair" begin
            pct_to_ratio(x) = 1.0 + x / 100.0
            df = DataFrame(name=[:x], pct=[-50.0], lower=[NaN], upper=[NaN])
            ts = TargetSet(df; value=:pct => pct_to_ratio)
            @test ts.df.value[1] ≈ 0.5
        end

        @testset "recode via Dict Pair" begin
            df = DataFrame(
                treatment = ["Anti-IL5", "Anti-IL13"],
                value = [0.5, 0.8],
            )
            ts = TargetSet(df;
                condition = :treatment => Dict("Anti-IL5" => :mepolizumab, "Anti-IL13" => :lebrikizumab),
            )
            @test :condition in propertynames(ts.df)
            @test ts.df.condition[1] == :mepolizumab
            @test ts.df.condition[2] == :lebrikizumab
        end

        @testset "recode preserves Dict values" begin
            endpoint = Ref(:brain_endpoint)
            df = DataFrame(endpoint = ["brain"], value = [1.0])
            ts = TargetSet(df; variable = :endpoint => Dict("brain" => endpoint))

            @test ts.df.variable[1] === endpoint
        end

        @testset "auto-generate name from condition + variable" begin
            df = DataFrame(
                treatment = ["A", "A", "B", "B"],
                endpoint = ["X", "Y", "X", "Y"],
                value = [1.0, 2.0, 3.0, 4.0],
            )
            ts = TargetSet(df;
                condition = :treatment => Dict("A" => :a, "B" => :b),
                variable = :endpoint => Dict("X" => :x, "Y" => :y),
            )
            @test nrow(ts) == 4
            @test :name in propertynames(ts.df)
            @test ts.df.name[1] == :a_x
            @test ts.df.name[4] == :b_y
        end

        @testset "NaN lower/upper auto-filled" begin
            df = DataFrame(name=[:x], value=[1.0])
            ts = TargetSet(df)
            @test :lower in propertynames(ts.df)
            @test :upper in propertynames(ts.df)
            @test isnan(ts.df.lower[1])
            @test isnan(ts.df.upper[1])
        end

        @testset "custom loss" begin
            df = DataFrame(name=[:x], value=[1.0])
            ts = TargetSet(df; loss=:squared)
            @test ts.loss == :squared
        end

        @testset "handles NaN in transform gracefully" begin
            df = DataFrame(name=[:x, :y], val=[10.0, NaN])
            ts = TargetSet(df; value=:val => x -> x * 2)
            @test ts.df.value[1] ≈ 20.0
            @test isnan(ts.df.value[2])
        end
    end

    # ============================================================
    # 14. TargetSet — Wide format pivot
    # ============================================================
    @testset "TargetSet — wide format" begin
        df = DataFrame(
            drug = [:mepo, :dupi],
            time = [24.0, 24.0],
            Blood_Eos = [0.4, 0.8],
            FeNO = [0.9, 0.7],
            FEV1 = [1.05, 1.12],
        )
        ts = TargetSet(df;
            targets = [:Blood_Eos, :FeNO, :FEV1],
            condition = :drug,
            timepoint = :time,
            loss = :log,
        )

        @test nrow(ts) == 6  # 2 drugs × 3 variables
        @test :variable in propertynames(ts.df)
        @test :value in propertynames(ts.df)
        @test :condition in propertynames(ts.df)
        @test Set(ts.df.variable) == Set([:Blood_Eos, :FeNO, :FEV1])
    end

    # ============================================================
    # 15. TargetSet — Tables.jl interface
    # ============================================================
    @testset "TargetSet — Tables.jl interface" begin
        df = DataFrame(name=[:x, :y], value=[1.0, 2.0], lower=[0.5, 1.5], upper=[1.5, 2.5])
        ts = TargetSet(df)

        @test Tables.istable(typeof(ts))
        @test length(ts) == 2
        @test nrow(ts) == 2

        # Property access delegates to DataFrame
        @test ts.value == ts.df.value
    end

    # ============================================================
    # 16. Validation
    # ============================================================
    @testset "Validation" begin
        @testset "valid TargetSet" begin
            df = DataFrame(name=[:x, :y], value=[1.0, 2.0], lower=[0.5, 1.5], upper=[1.5, 2.5])
            ts = TargetSet(df)
            @test validate(ts) == true
        end

        @testset "invalid ranges" begin
            df = DataFrame(name=[:x], value=[1.0], lower=[5.0], upper=[1.0])
            ts = TargetSet(df)
            @test_throws ErrorException validate(ts)
        end

        @testset "duplicate names" begin
            df = DataFrame(name=[:x, :x], value=[1.0, 2.0], lower=[NaN, NaN], upper=[NaN, NaN])
            ts = TargetSet(df)
            @test_throws ErrorException validate(ts)
        end
    end

    # ============================================================
    # 17. score() — TargetSet with convention-based prediction
    # ============================================================
    @testset "score() — TargetSet" begin
        @testset "convention: sim[name]" begin
            df = DataFrame(name=[:x, :y], value=[2.0, 4.0], lower=[1.0, 3.0], upper=[3.0, 5.0])
            ts = TargetSet(df)
            sim = Dict(:x => 2.0, :y => 4.0)

            report = score(ts; sim=sim)
            @test report.total_loss ≈ 0.0 atol=1e-12
            @test report.n_met == 2
        end

        @testset "convention: sim[condition][variable]" begin
            df = DataFrame(
                treatment = ["A", "B"],
                endpoint = ["x", "y"],
                value = [2.0, 4.0],
                lower = [1.0, 3.0],
                upper = [3.0, 5.0],
            )
            ts = TargetSet(df;
                condition = :treatment => Dict("A" => :a, "B" => :b),
                variable = :endpoint => Dict("x" => :x, "y" => :y),
            )
            sim = Dict(:a => Dict(:x => 2.0), :b => Dict(:y => 4.0))

            report = score(ts; sim=sim)
            @test report.total_loss ≈ 0.0 atol=1e-12
            @test report.n_met == 2
        end

        @testset "convention: solution series targets" begin
            df = DataFrame(
                dose = [20.0],
                organ = ["brain"],
                value = [(t = [1.0, 2.0], y = [3.0, 5.0])],
            )
            ts = TargetSet(df;
                condition = :dose,
                variable = :organ => Dict("brain" => :brain),
            )
            sim = Dict(20.0 => FakeSolution(2.0, 1.0))

            report = score(ts; sim=sim)
            @test report.total_loss ≈ 0.0 atol=1e-12
            @test report.details.predicted[1] == [3.0, 5.0]
        end

        @testset "convention: solution series before property lookup" begin
            df = DataFrame(
                dose = [20.0],
                organ = ["brain"],
                value = [(t = [1.0, 2.0], y = [3.0, 5.0])],
            )
            ts = TargetSet(df;
                condition = :dose,
                variable = :organ => Dict("brain" => :brain),
            )
            sim = Dict(20.0 => FakeSolutionWithNaNProperty(2.0, 1.0))

            report = score(ts; sim=sim)
            @test report.total_loss ≈ 0.0 atol=1e-12
            @test report.details.predicted[1] == [3.0, 5.0]
        end

        @testset "convention: nested series targets" begin
            df = DataFrame(
                treatment = ["A"],
                endpoint = ["x"],
                value = [(t = [1.0, 2.0], y = [3.0, 5.0])],
            )
            ts = TargetSet(df;
                condition = :treatment => Dict("A" => :a),
                variable = :endpoint => Dict("x" => :x),
            )
            sim = Dict(:a => Dict(:x => [3.0, 5.0]))

            report = score(ts; sim=sim)
            @test report.total_loss ≈ 0.0 atol=1e-12
            @test report.details.predicted[1] == [3.0, 5.0]
        end

        @testset "custom predict function" begin
            df = DataFrame(name=[:x], value=[2.0], lower=[1.0], upper=[3.0])
            ts = TargetSet(df)
            sim = (val=2.0,)

            report = score(ts; sim=sim, predict=(sim, row) -> sim.val)
            @test report.total_loss ≈ 0.0 atol=1e-12
        end

        @testset "multiple TargetSets" begin
            ts1 = TargetSet(DataFrame(name=[:a], value=[1.0], lower=[0.5], upper=[1.5]))
            ts2 = TargetSet(DataFrame(name=[:b], value=[2.0], lower=[1.5], upper=[2.5]))
            sim = Dict(:a => 1.0, :b => 2.0)

            report = score(ts1, ts2; sim=sim)
            @test report.n_met == 2
            @test nrow(report.details) == 2
        end

        @testset "metadata columns preserved" begin
            df = DataFrame(
                treatment = ["A"],
                endpoint = ["x"],
                value = [2.0],
            )
            ts = TargetSet(df;
                condition = :treatment => Dict("A" => :a),
                variable = :endpoint => Dict("x" => :x),
            )
            sim = Dict(:a => Dict(:x => 2.0))

            report = score(ts; sim=sim)
            @test :condition in propertynames(report.details)
            @test :variable in propertynames(report.details)
        end
    end

    # ============================================================
    # 18. fit() — TargetSet
    # ============================================================
    @testset "fit() — TargetSet" begin
        ts = TargetSet(DataFrame(name=[:sum_val], value=[2.0]))

        result = fit(ts;
            simulate = overrides -> Dict(:sum_val => overrides[:a] + overrides[:b]),
            params = [:a, :b],
            bounds = (lb = [0.1, 0.1], ub = [5.0, 5.0]),
            x0 = [1.0, 1.0],
            strategy = :nm,
            on_eval = nothing,
            verbose = false,
        )

        @test result isa FitResult
        @test result.loss < 0.01
        @test result.params[:a] + result.params[:b] ≈ 2.0 atol=0.1
    end

    @testset "fit() — TargetSet with custom predict" begin
        df = DataFrame(
            treatment = ["A"],
            endpoint = ["x"],
            value = [2.0],
        )
        ts = TargetSet(df;
            condition = :treatment => Dict("A" => :a),
            variable = :endpoint => Dict("x" => :x),
        )

        result = fit(ts;
            simulate = overrides -> Dict(:a => Dict(:x => overrides[:p])),
            predict = (sim, row) -> sim[row.condition][row.variable],
            params = [:p],
            bounds = (lb = [1.0], ub = [5.0]),
            x0 = [2.0],
            strategy = :nm,
            on_eval = nothing,
            verbose = false,
        )

        @test result.loss < 0.01
    end

    @testset "fit() — print_every across stages" begin
        ts = TargetSet(DataFrame(name=[:sum_val], value=[2.0]))
        seen = Int[]
        out = mktemp() do path, io
            redirect_stdout(io) do
                fit(ts;
                    simulate = overrides -> Dict(:sum_val => overrides[:a] + overrides[:b]),
                    params = [:a, :b],
                    bounds = (lb = [0.1, 0.1], ub = [5.0, 5.0]),
                    x0 = [0.5, 0.5],
                    strategy = [
                        Stage(ParticleSwarm(n_particles=5); maxiters=5, restarts=2),
                        Stage(NelderMead(); maxiters=50),
                    ],
                    on_eval = (n, _, _, _) -> push!(seen, n),
                    print_every = 5,
                    verbose = false,
                )
            end
            flush(io)
            read(path, String)
        end
        lines = filter(startswith("  [eval"), split(out, '\n'))

        @test length(lines) == length(seen) ÷ 5
        @test all(l -> occursin(r"^  \[eval \d*[05] \| stage \d: \w+.*\] loss=\S+ best=\S+ \(\S+s\)$", l), lines)
        @test any(l -> occursin("stage 1: ParticleSwarm restart 1/2", l), lines)
        @test any(l -> occursin("stage 1: ParticleSwarm restart 2/2", l), lines)
        @test any(l -> occursin("stage 2: NelderMead", l), lines)
        @test seen == 1:length(seen)   # on_eval still fires on every evaluation

        obj = objective(ts;
            simulate = overrides -> Dict(:sum_val => overrides[:a] + overrides[:b]),
            params = [:a, :b],
            bounds = (lb = [0.1, 0.1], ub = [5.0, 5.0]),
            print_every = 1000,
        )
        obj(log.([1.0, 1.0]))
        @test obj._eval_count[] == 1   # counts without an on_eval callback

        @test_throws ArgumentError objective(ts;
            simulate = overrides -> nothing,
            params = [:a], bounds = (lb = [0.1], ub = [5.0]),
            print_every = 0,
        )
    end

    # ============================================================
    # 19. where() — TargetSet filtering
    # ============================================================
    include("filtering_test.jl")

    # ============================================================
    # 20. objective() — TargetSet
    # ============================================================
    @testset "objective() — TargetSet" begin
        ts = TargetSet(DataFrame(name=[:x], value=[10.0], lower=[5.0], upper=[15.0]))

        obj = objective(ts;
            simulate = overrides -> Dict(:x => overrides[:p]),
            params = [:p],
            bounds = (lb = [5.0], ub = [15.0]),
            on_eval = nothing,
        )

        @test obj isa TargKit.ObjectiveFunction
        @test obj.prepared_targets !== nothing
        loss = obj(log.([10.0]))
        @test loss ≈ 0.0 atol=1e-12
    end

    @testset "objective() — TargetSet series loss" begin
        ts = TargetSet(DataFrame(
            name = [:curve],
            value = [(t = [1.0, 2.0], y = [2.0, 4.0])],
        ))

        obj = objective(ts;
            simulate = overrides -> Dict(:curve => [overrides[:p], 2 * overrides[:p]]),
            params = [:p],
            bounds = (lb = [0.1], ub = [10.0]),
            on_eval = nothing,
        )

        @test obj.prepared_targets !== nothing
        @test obj(log.([2.0])) ≈ 0.0 atol=1e-12
    end

    @testset "objective() — TargetSet prepared solution convention" begin
        ts = TargetSet(DataFrame(
            dose = [20.0],
            organ = ["brain"],
            value = [(t = [1.0, 2.0], y = [3.0, 5.0])],
        );
            condition = :dose,
            variable = :organ => Dict("brain" => :brain),
        )

        obj = objective(ts;
            simulate = overrides -> Dict(20.0 => FakeSolution(overrides[:slope], 1.0)),
            params = [:slope],
            bounds = (lb = [0.1], ub = [10.0]),
            on_eval = nothing,
        )

        @test obj.prepared_targets !== nothing
        @test obj(log.([2.0])) ≈ 0.0 atol=1e-12
    end

end

include("matching_test.jl")
include("matching_simkit_test.jl")
