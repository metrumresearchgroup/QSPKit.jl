using Test
using ConfigKit
using Accessors
using OrdinaryDiffEq
using SciMLBase
using ModelingToolkitBase


@testset "Optics (Accessors.jl) Tests" begin

    # =================================================================
    # SETUP: Reusable test system + keyfile
    # =================================================================

    function create_test_system()
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
        return csys, csys.α, csys.β, csys.γ, csys.x, csys.y
    end

    # =================================================================
    # TEST 1: @param creates MTKParamLens
    # =================================================================
    @testset "@param macro creates MTKParamLens" begin
        lens = @param(α)
        @test lens isa MTKParamLens
        @test lens.key === :α
    end

    # =================================================================
    # TEST 2: Callable lens reads parameter value
    # =================================================================
    @testset "Callable lens reads parameter value" begin
        csys, α_sym, β_sym, γ_sym, _, _ = create_test_system()
        prob = ODEProblem(csys, [csys.x => 1.0, csys.y => 0.0], (0.0, 1.0))

        lens = MTKParamLens(α_sym)
        val = lens(prob)
        @test val ≈ 2.0
    end

    # =================================================================
    # TEST 3: Accessors.set returns updated problem
    # =================================================================
    @testset "Accessors.set returns updated problem" begin
        csys, α_sym, β_sym, γ_sym, _, _ = create_test_system()
        prob = ODEProblem(csys, [csys.x => 1.0, csys.y => 0.0], (0.0, 1.0))

        lens = MTKParamLens(α_sym)
        prob2 = Accessors.set(prob, lens, 5.0)

        @test prob2 isa SciMLBase.ODEProblem
        @test lens(prob2) ≈ 5.0
        # Original unchanged
        @test lens(prob) ≈ 2.0
    end

    # =================================================================
    # TEST 4: modify (Accessors functional update)
    # =================================================================
    @testset "modify doubles parameter" begin
        csys, α_sym, β_sym, γ_sym, _, _ = create_test_system()
        prob = ODEProblem(csys, [csys.x => 1.0, csys.y => 0.0], (0.0, 1.0))

        lens = MTKParamLens(α_sym)
        prob2 = modify(v -> v * 2, prob, lens)
        @test lens(prob2) ≈ 4.0
    end

    # =================================================================
    # TEST 5: @param with Symbol key resolves against problem
    # =================================================================
    @testset "@param with Symbol key" begin
        csys, α_sym, β_sym, γ_sym, _, _ = create_test_system()
        prob = ODEProblem(csys, [csys.x => 1.0, csys.y => 0.0], (0.0, 1.0))

        lens = @param(α)
        prob2 = Accessors.set(prob, lens, 7.0)
        @test lens(prob2) ≈ 7.0
    end

    # =================================================================
    # TEST 6: bounds_from extracts correct bounds
    # =================================================================
    @testset "bounds_from extracts bounds from keyfile" begin
        keyfile_path = joinpath(mktempdir(), "test_optics.yml")
        write(keyfile_path, """
        Parameters:
          CL:
            value: 5.0
            unit: "L/hr"
            desc: "Clearance"
            bounds: [0.1, 100.0]
          V1:
            value: 50.0
            unit: L
            desc: "Volume"
            bounds: [1.0, 500.0]
          Q:
            value: 10.0
            desc: "No bounds param"
        """)

        kf = load_keyfile(keyfile_path)

        lb, ub = bounds_from(kf, :CL)
        @test lb ≈ 0.1
        @test ub ≈ 100.0

        lb2, ub2 = bounds_from(kf, :V1)
        @test lb2 ≈ 1.0
        @test ub2 ≈ 500.0

        # No bounds → error
        @test_throws ErrorException bounds_from(kf, :Q)
    end

    # =================================================================
    # TEST 7: Updated problem solves correctly
    # =================================================================
    @testset "Updated problem produces correct solution" begin
        csys, α_sym, β_sym, γ_sym, _, _ = create_test_system()
        prob = ODEProblem(csys, [csys.x => 1.0, csys.y => 0.0], (0.0, 1.0))

        # Solve original
        sol1 = solve(prob, Tsit5())

        # Update α via lens and solve again
        lens = MTKParamLens(α_sym)
        prob2 = Accessors.set(prob, lens, 10.0)
        sol2 = solve(prob2, Tsit5())

        # With higher α (damping), final values should differ
        @test sol1[end] != sol2[end]
    end

end
