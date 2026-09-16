using Test
using ConfigKit
using OrdinaryDiffEq
using SciMLBase
using ModelingToolkitBase

@testset "Performance Regression Check" begin
    @independent_variables t
    @parameters α=2.0 β=1.0 γ=3.0
    @variables x(t) y(t)
    D = Differential(t)

    eqs = [
        D(x) ~ -α * x + β * y,
        D(y) ~ γ * x - α * y,
    ]

    @named sys = System(eqs, t)
    csys = mtkcompile(sys)
    prob = ODEProblem(csys, [csys.x => 1.0, csys.y => 0.0], (0.0, 10.0))

    N = 100

    # Warm up (first call compiles)
    update(prob, [csys.α => 5.0])
    remake(prob; p = [csys.α => 5.0])

    # ConfigKit.update with parameter object path
    t_update = @elapsed for _ in 1:N
        update(prob, [csys.α => 5.0])
    end

    # Naive symbolic map remake (the slow path)
    t_naive = @elapsed for _ in 1:N
        remake(prob; p = [csys.α => 5.0])
    end

    speedup = t_naive / t_update
    @info "Performance: update=$(round(t_update/N * 1e6, digits=1))μs, " *
          "naive remake=$(round(t_naive/N * 1e6, digits=1))μs, " *
          "speedup=$(round(speedup, digits=1))x"

    # update should be at least 10x faster than naive symbolic remake.
    # Typical speedup is 100-400x; 10x is a very conservative floor.
    @test speedup > 10
end
