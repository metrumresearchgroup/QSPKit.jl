using Test
using TargKit
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

function caught_error(f::Function)
    try
        f()
        return nothing
    catch err
        return err
    end
end

@testset verbose=true "TargKit" begin

    @testset "exported API is bound" begin
        for name in (
            :fit, :score, :objective, :targets, :Stage, :setup, :finish,
            :inspect_fit, :score_fit, :checkpoint, :FitResult, :ScoreReport,
            :TargetSet, :FitState, :StageResult, :FitStep, :FitPipeline,
            :PSO_NM, :NM_ONLY, :LBFGS_ONLY, :fingerprint, :reset!, :validate,
            :filter_flags, :where, :DataFrame, :nrow, :eachrow, :groupby,
            :innerjoin, :leftjoin, Symbol("@chain"), Symbol("@rsubset"),
            Symbol("@rtransform"), Symbol("@rselect"), Symbol("@select"),
            Symbol("@transform"), Symbol("@subset"), Symbol("@combine"),
            Symbol("@by"), Symbol("@rename"), Symbol("@orderby"),
            Symbol("@groupby"), :CSV, :ParticleSwarm, :NelderMead, :LBFGS,
        )
            @test isdefined(TargKit, name)
        end
    end

    # ============================================================
    # 1. targets() convenience constructor
    # ============================================================
    @testset "targets()" begin
        @testset "basic construction" begin
            df = targets(
                gain = (0.75, 0.4, 1.2),
                lag = (1.8, 1.1, 2.6),
            )
            @test df isa DataFrame
            @test nrow(df) == 2
            @test :name in propertynames(df)
            @test :value in propertynames(df)
            @test :lower in propertynames(df)
            @test :upper in propertynames(df)
        end

        @testset "values are correct" begin
            df = targets(gain = (0.75, 0.4, 1.2))
            @test df.name[1] == :gain
            @test df.value[1] == 0.75
            @test df.lower[1] == 0.4
            @test df.upper[1] == 1.2
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
            @test_throws DomainError TargKit.compute_loss([NaN], 2.0, :squared, 1.0)

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

        @testset "NaN/Inf errors" begin
            @test_throws DomainError TargKit.compute_loss(NaN, 2.5, :log, 1.0)
            @test_throws DomainError TargKit.compute_loss(Inf, 2.5, :log, 1.0)
            @test_throws DomainError TargKit.compute_loss(2.5, NaN, :log, 1.0)
            @test_throws DomainError TargKit.compute_loss(2.5, Inf, :squared, 1.0)
        end

        @testset "nonpositive log values error" begin
            @test_throws DomainError TargKit.compute_loss(-1.0, 2.5, :log, 1.0)
            @test_throws DomainError TargKit.compute_loss(2.5, 0.0, :log, 1.0)
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

        @testset "invalid series values error with index context" begin
            value = (t=[0.0, 7.0], y=[1.0, 0.5])
            err = caught_error() do
                TargKit.compute_loss([1.0, NaN], value, :series_mse, 1.0; target=:curve)
            end
            @test err isa DomainError
            @test occursin("target :curve", sprint(showerror, err))
            @test occursin("index 2", sprint(showerror, err))

            @test_throws DomainError TargKit.compute_loss(
                [1.0, 0.5], (t=[0.0, 7.0], y=[1.0, Inf]), :series_mse, 1.0)
            @test_throws DomainError TargKit.compute_loss(
                [1.0, 0.0], value, :series_log, 1.0)
            @test_throws DomainError TargKit.compute_loss(
                [1.0, 0.5], (t=[0.0, 7.0], y=[1.0, -0.5]), :series_log, 1.0)
            @test_throws DimensionMismatch TargKit.compute_loss(
                [1.0], value, :series_mse, 1.0)
            @test_throws DimensionMismatch TargKit.compute_loss(
                [1.0, 0.5], (t=[0.0], y=[1.0, 0.5]), :series_mse, 1.0)
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
        @test_throws DomainError TargKit.compute_loss_range_only(NaN, 1.0, 4.0, 1.0)
        @test_throws DomainError TargKit.compute_loss_range_only(2.5, 1.0, Inf, 1.0)
        @test_throws ArgumentError TargKit.compute_loss_range_only(2.5, 4.0, 1.0, 1.0)
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
                group = [:group_a],
                series = [:series_a],
            )
            ctx = nothing
            report = score(df => (ctx, row) -> 2.0; ctx=ctx)
            @test :group in propertynames(report.details)
            @test report.details.group[1] == :group_a
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

        @testset "invalid values identify the target" begin
            df = DataFrame(name=[:bad_prediction], value=[2.0])
            err = caught_error() do
                score(df => (ctx, row) -> NaN; ctx=nothing)
            end
            @test err isa DomainError
            @test occursin("target :bad_prediction", sprint(showerror, err))

            incomplete_range = DataFrame(
                name=[:partial_range], value=[2.0], lower=[1.0], upper=[NaN])
            range_err = caught_error() do
                score(incomplete_range => (ctx, row) -> 2.0; ctx=nothing)
            end
            @test range_err isa ArgumentError
            @test occursin("target :partial_range", sprint(showerror, range_err))
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

    @testset "objective propagates target errors" begin
        invalid_prediction = DataFrame(name=[:invalid_prediction], value=[1.0])
        invalid_obj = objective(
            invalid_prediction => (ctx, row) -> ctx.value;
            simulate = overrides -> (value=NaN,),
            params = [:p],
            bounds = (lb=[0.5], ub=[2.0]),
        )
        invalid_err = caught_error(() -> invalid_obj(log.([1.0])))
        @test invalid_err isa DomainError
        @test occursin("target :invalid_prediction", sprint(showerror, invalid_err))

        missing_range = DataFrame(
            name=[:missing_range], value=[1.0], loss=[:range_only])
        range_obj = objective(
            missing_range => (ctx, row) -> 1.0;
            simulate = overrides -> NamedTuple(),
            params = [:p],
            bounds = (lb=[0.5], ub=[2.0]),
        )
        range_err = caught_error(() -> range_obj(log.([1.0])))
        @test range_err isa ArgumentError
        @test occursin("target :missing_range", sprint(showerror, range_err))

        series_ts = TargetSet(DataFrame(
            name=[:invalid_series],
            value=[(t=[0.0, 1.0], y=[1.0, 2.0])],
            condition=[:baseline],
            variable=[:endpoint],
        ))
        series_obj = objective(
            series_ts;
            simulate = overrides -> Dict(:baseline => Dict(:endpoint => [1.0, Inf])),
            params = [:p],
            bounds = (lb=[0.5], ub=[2.0]),
        )
        series_err = caught_error(() -> series_obj(log.([1.0])))
        @test series_err isa DomainError
        @test occursin("target :invalid_series", sprint(showerror, series_err))
        @test occursin("index 2", sprint(showerror, series_err))

        missing_source_obj = objective(
            series_ts;
            simulate = overrides -> Dict(),
            params = [:p],
            bounds = (lb=[0.5], ub=[2.0]),
        )
        source_err = caught_error(() -> missing_source_obj(log.([1.0])))
        @test source_err isa ArgumentError
        @test occursin("target :invalid_series", sprint(showerror, source_err))
        @test occursin("condition :baseline", sprint(showerror, source_err))
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
                group = ["Group A", "Group B"],
                value = [0.5, 0.8],
            )
            ts = TargetSet(df;
                condition = :group => Dict("Group A" => :group_a, "Group B" => :group_b),
            )
            @test :condition in propertynames(ts.df)
            @test ts.df.condition[1] == :group_a
            @test ts.df.condition[2] == :group_b
        end

        @testset "recode preserves Dict values" begin
            endpoint = Ref(:custom_endpoint)
            df = DataFrame(endpoint = ["custom"], value = [1.0])
            ts = TargetSet(df; variable = :endpoint => Dict("custom" => endpoint))

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
            mode = [:idle, :nominal, :burst],
            sample_time = [3.0, 7.0, 11.0],
            gain = [0.2, 0.75, 1.4],
            error = [0.03, -0.02, 0.08],
        )
        ts = TargetSet(df;
            targets = [:gain, :error],
            condition = :mode,
            timepoint = :sample_time,
            loss = :squared,
        )

        @test nrow(ts) == 6  # 3 modes × 2 variables
        @test :variable in propertynames(ts.df)
        @test :value in propertynames(ts.df)
        @test :condition in propertynames(ts.df)
        @test Set(ts.df.variable) == Set([:gain, :error])
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

        @testset "missing convention sources error with target context" begin
            df = DataFrame(
                name=[:mapped_target],
                value=[2.0],
                condition=[:baseline],
                variable=[:endpoint],
            )
            ts = TargetSet(df)

            condition_err = caught_error(() -> score(ts; sim=Dict()))
            @test condition_err isa ArgumentError
            @test occursin("target :mapped_target", sprint(showerror, condition_err))
            @test occursin("condition :baseline", sprint(showerror, condition_err))

            variable_err = caught_error(() -> score(
                ts; sim=Dict(:baseline => Dict{Symbol, Float64}())))
            @test variable_err isa ArgumentError
            @test occursin("target :mapped_target", sprint(showerror, variable_err))
            @test occursin("variable :endpoint", sprint(showerror, variable_err))

            source_ts = TargetSet(DataFrame(name=[:unmapped_target], value=[2.0]))
            source_err = caught_error(() -> score(source_ts; sim=Dict()))
            @test source_err isa ArgumentError
            @test occursin("target :unmapped_target", sprint(showerror, source_err))
            @test occursin("no prediction source", sprint(showerror, source_err))
        end

        @testset "convention: solution series targets" begin
            df = DataFrame(
                dose = [20.0],
                output = ["signal"],
                value = [(t = [1.0, 2.0], y = [3.0, 5.0])],
            )
            ts = TargetSet(df;
                condition = :dose,
                variable = :output => Dict("signal" => :signal),
            )
            sim = Dict(20.0 => FakeSolution(2.0, 1.0))

            report = score(ts; sim=sim)
            @test report.total_loss ≈ 0.0 atol=1e-12
            @test report.details.predicted[1] == [3.0, 5.0]
        end

        @testset "convention: solution series before property lookup" begin
            df = DataFrame(
                dose = [20.0],
                output = ["signal"],
                value = [(t = [1.0, 2.0], y = [3.0, 5.0])],
            )
            ts = TargetSet(df;
                condition = :dose,
                variable = :output => Dict("signal" => :signal),
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

    @testset "TargetSet loss is inherited by setup() and fit()" begin
        ts = TargetSet(DataFrame(name=[:x], value=[2.0]); loss=:squared)
        simulate = _ -> (prediction=-1.0,)
        predict = (sim, _) -> sim.prediction
        kwargs = (
            simulate=simulate,
            predict=predict,
            params=[:p],
            bounds=(lb=[0.1], ub=[10.0]),
            x0=[1.0],
            on_eval=nothing,
            verbose=false,
        )

        state = setup(ts; kwargs...)
        @test state.obj.default_loss == :squared
        @test state.loss ≈ 9.0

        result = fit(ts; kwargs..., strategy=FitStep(:noop, identity))
        @test result.loss ≈ 9.0
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
            output = ["signal"],
            value = [(t = [1.0, 2.0], y = [3.0, 5.0])],
        );
            condition = :dose,
            variable = :output => Dict("signal" => :signal),
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
