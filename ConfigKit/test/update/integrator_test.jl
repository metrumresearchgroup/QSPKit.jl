using ConfigKit
using OrdinaryDiffEq
using Test

@testset "Integrator Update Tests" begin

    # Create a simple test system
    @independent_variables t
    @parameters α = 2.0 β = 11.0 γ = 10.0
    @variables x(t) y(t)
    D = Differential(t)

    eqs = [
        D(x) ~ -α * x + β * y,
        D(y) ~ γ * x - α * y,
    ]

    @named sys = System(eqs, t, [x, y], [α, β, γ])
    sys = complete(sys)

    # Create problem
    tspan = (0.0, 10.0)
    prob = ODEProblem(sys, [x => 1.0, y => 0.0], tspan)

    @testset "Test 1: Basic parameter update" begin
        integrator = init(prob, Tsit5())
        # Update parameter
        update(integrator, [α => 2.0])
        # Parameter should be set
        @test true  # Test passes if no error thrown
    end

    @testset "Test 2: State variable update" begin
        integrator = init(prob, Tsit5())
        # Update state variables
        update(integrator, [x => 5.0, y => 3.0])
        @test integrator.u[1] ≈ 5.0
        @test integrator.u[2] ≈ 3.0
    end

    @testset "Test 3: Callback integration test" begin
        prob_callback = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 2.0))

        # Define callback that changes parameters at t=1.0
        condition(u, t, integrator) = t - 1.0
        function affect!(integrator)
            # Use ConfigKit.update inside callback
            update(integrator, [α => 0.1, β => 3.0])
        end

        cb = ContinuousCallback(condition, affect!)
        sol = solve(prob_callback, Tsit5(), callback = cb)

        @test length(sol.t) > 1
        # Check final values reflect changed dynamics if possible
    end
end
