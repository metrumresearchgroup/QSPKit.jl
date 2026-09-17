using Test
using QSPKit.ConfigKit
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

    function elapsed_update()
        return @elapsed for _ in 1:N
            update(prob, [csys.α => 5.0])
        end
    end

    function elapsed_naive()
        return @elapsed for _ in 1:N
            remake(prob; p = [csys.α => 5.0])
        end
    end

    # Use the median of several paired samples so a scheduler interruption or
    # one GC cycle cannot determine the result.
    update_samples = [elapsed_update() for _ in 1:3]
    naive_samples = [elapsed_naive() for _ in 1:3]
    t_update = sort!(update_samples)[2]
    t_naive = sort!(naive_samples)[2]

    speedup = t_naive / t_update
    @info "Performance: update=$(round(t_update/N * 1e6, digits=1))μs, " *
          "naive remake=$(round(t_naive/N * 1e6, digits=1))μs, " *
          "speedup=$(round(speedup, digits=1))x"

    if Base.JLOptions().code_coverage == 0
        # update should be at least 10x faster than naive symbolic remake.
        # Typical uninstrumented speedup is 100-400x; 10x is conservative.
        @test speedup > 10
    else
        # Coverage instrumentation changes the relative cost of the two code
        # paths, so it is unsuitable for a performance gate. Keep the scorecard
        # run as a finite-measurement smoke check; ordinary CI/Pkg.test enforces
        # the actual threshold above.
        @test isfinite(speedup) && speedup > 0
    end
end
