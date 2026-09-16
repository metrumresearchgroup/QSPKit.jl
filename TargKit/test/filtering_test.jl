using Test
using TargKit
using DataFrames

@testset "where() — TargetSet filtering" begin
    # Create a TargetSet with metadata columns
    df = DataFrame(
        name = [:a_eos, :a_feno, :b_eos, :b_feno],
        value = [2.0, 40.0, 4.0, 30.0],
        lower = [1.0, 25.0, 3.0, 20.0],
        upper = [3.0, 55.0, 5.0, 40.0],
        condition = [:a, :a, :b, :b],
        variable = [:eos, :feno, :eos, :feno],
    )
    ts = TargetSet(df)

    @testset "scalar filter" begin
        filtered = where(ts, :condition => :a)
        @test nrow(filtered) == 2
        @test all(filtered.df.condition .== :a)
        @test filtered.loss == ts.loss
        @test filtered.metadata === ts.metadata
    end

    @testset "vector filter" begin
        filtered = where(ts, :variable => [:eos])
        @test nrow(filtered) == 2
        @test all(filtered.df.variable .== :eos)
    end

    @testset "no matches" begin
        filtered = where(ts, :condition => :c)
        @test nrow(filtered) == 0
    end

    @testset "curried form" begin
        filtered = ts |> where(:condition => :b)
        @test nrow(filtered) == 2
        @test all(filtered.df.condition .== :b)
    end

    @testset "chained filtering" begin
        filtered = ts |> where(:condition => :a) |> where(:variable => :eos)
        @test nrow(filtered) == 1
        @test filtered.df.name[1] == :a_eos
    end
end
