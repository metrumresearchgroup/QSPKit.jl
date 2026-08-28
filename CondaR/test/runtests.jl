using Test
using CondaR

@testset verbose=true "CondaR" begin
    @testset "managed R paths" begin
        @test CondaR.r_home() == joinpath(CondaR.CondaPkg.envdir(), "lib", "R")
        @test CondaR.r_libdir() == joinpath(CondaR.r_home(), "library")
        @test isdir(CondaR.r_home())
        @test isdir(CondaR.r_libdir())
        configured = CondaR._rcall_configuration()
        @test configured.Rhome == CondaR.r_home()
        @test isfile(configured.libR)
    end

    @testset "RCall wrappers" begin
        @test CondaR._rcopy_fn[] !== nothing
        @test CondaR._reval_fn[] !== nothing
        @test CondaR._rcall_fn[] !== nothing
        @test CondaR._robject_fn[] !== nothing

        @test rcopy(Bool, reval("TRUE"))
        @test rcopy(Int, reval("1L + 1L")) == 2

        values = robject([1, 2, 3])
        @test rcopy(Vector{Int}, values) == [1, 2, 3]
        @test rcopy(Int, rcall(:sum, values)) == 6
    end

    @testset "serialized concurrent calls" begin
        tasks = [Threads.@spawn rcopy(Int, reval("40L + 2L")) for _ in 1:4]
        @test fetch.(tasks) == fill(42, 4)
    end

    @testset "public API" begin
        expected = Set([:rcall, :rcopy, :reval, :robject])
        actual = Set(names(CondaR; all=false, imported=false))
        delete!(actual, :CondaR)
        @test actual == expected
    end
end
