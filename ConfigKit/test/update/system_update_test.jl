using Test
using QSPKit.ConfigKit

@testset "System Level Updates" begin
    @independent_variables t
    @parameters α = 2.0 β = 1.0
    @variables x(t) = 1.0
    D = Differential(t)

    eqs = [D(x) ~ -α * x + β]
    @named sys = System(eqs, t)
    sys = complete(sys)

    @testset "update(sys, pairs)" begin
        # Should return a NEW system with updated defaults/ICs
        new_sys = update(sys, [α => 5.0])

        # Verify defaults changed
        # Note: In V11, we check initial_conditions or defaults depending on exact version
        defs = MTK.defaults(new_sys)
        @test defs[α] == 5.0
        @test defs[β] == 1.0 # Unchanged
    end
end
