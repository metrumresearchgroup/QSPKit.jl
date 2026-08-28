using Test
using TargKit
using DataFrames

@testset "where() — TargetSet filtering" begin
    # Create a TargetSet with metadata columns
    df = DataFrame(
        name = [:bench_a_gain, :bench_a_lag, :bench_b_gain, :bench_b_lag],
        value = [0.35, 1.7, 0.8, 2.6],
        lower = [0.1, 1.2, 0.5, 2.0],
        upper = [0.7, 2.2, 1.1, 3.4],
        condition = [:bench_a, :bench_a, :bench_b, :bench_b],
        variable = [:gain, :lag, :gain, :lag],
    )
    ts = TargetSet(df)

    @testset "scalar filter" begin
        filtered = where(ts, :condition => :bench_a)
        @test nrow(filtered) == 2
        @test all(filtered.df.condition .== :bench_a)
        @test filtered.loss == ts.loss
        @test filtered.metadata === ts.metadata
    end

    @testset "vector filter" begin
        filtered = where(ts, :variable => [:gain])
        @test nrow(filtered) == 2
        @test all(filtered.df.variable .== :gain)
    end

    @testset "no matches" begin
        filtered = where(ts, :condition => :missing_bench)
        @test nrow(filtered) == 0
    end

    @testset "curried form" begin
        filtered = ts |> where(:condition => :bench_b)
        @test nrow(filtered) == 2
        @test all(filtered.df.condition .== :bench_b)
    end

    @testset "chained filtering" begin
        filtered = ts |> where(:condition => :bench_a) |> where(:variable => :gain)
        @test nrow(filtered) == 1
        @test filtered.df.name[1] == :bench_a_gain
    end
end
