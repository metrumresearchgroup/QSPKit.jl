using Test, QSPKit.SimKit

@testset "Simulation keyword resolution" begin
    defaults = (abstol=1e-8, reltol=1e-6)
    ss = SteadyStateOptions(reltol=1e-5)
    options = simulation_options(defaults; abstol=1e-10, reltol=nothing,
        ss_options=ss, maxiters=1000)
    @test options.solver == (abstol=1e-10, reltol=1e-6, maxiters=1000)
    @test options.steady_state === ss
    @test defaults == (abstol=1e-8, reltol=1e-6)
    @test simulation_options(defaults).solver == defaults
    @test simulation_options().solver == NamedTuple()
    @test simulation_options().steady_state == SteadyStateOptions()
    @test simulation_options(; abstol=nothing, reltol=nothing).solver == NamedTuple()
    @test_throws ArgumentError simulation_options(; ss_options=:invalid)
    for tolerance in (:abstol, :reltol), value in (0, -1, Inf, NaN, "1e-6")
        @test_throws ArgumentError simulation_options(; NamedTuple{(tolerance,)}((value,))...)
    end
end
