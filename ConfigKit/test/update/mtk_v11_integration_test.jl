using Test
using QSPKit.ConfigKit
using OrdinaryDiffEq

@testset "MTK v11 Integration" begin

    # -------------------------------------------------------------
    # 1. Setup: Define a Mock System & Keyfile
    # -------------------------------------------------------------
    @independent_variables t
    @parameters CL V k_el
    @variables Central(t)
    D = Differential(t)

    # Simple elimination model: dCentral/dt = -k_el * Central
    # Note: k_el will be defined as "CL / V" in the keyfile (Locked Dependency)
    eqs = [
        D(Central) ~ -k_el * Central
    ]

    @named sys = System(eqs, t)

    # Create a temporary keyfile with:
    # - Locked dependency (k_el)
    # - Static value (CL, V)
    # - Guess (Central)
    path, io = mktemp()
    close(io)

    yaml_content = """
    Parameters:
      CL:
        value: 10.0
        unit: L/hr
      V:
        value: 100.0
        unit: L
      k_el:
        value: CL / V
        unit: 1/hr
    Variables:
      Central:
        initial: 100.0
        guess: 99.0
        unit: mg
    """
    write(path, yaml_content)
    keyfile = load_keyfile(path)

    # -------------------------------------------------------------
    # 2. Test populate() - Structural Population
    # -------------------------------------------------------------
    @testset "populate(sys, keyfile)" begin
        # populate returns a NEW, completed system
        sys_pop = populate(sys, keyfile)

        # A. Check Initial Conditions (CL, V, Central)
        # Note: In MTK v11, we check defaults/initial_conditions
        ics = MTK.initial_conditions(sys_pop)

        # We need to map the symbols back to the system's parameters
        # (Using string matching for robustness in tests)
        ic_dict = Dict(string(k) => v for (k,v) in ics)

        # Verify static values
        # Depending on MTK version, parameters might be in defaults or just bounds.
        # But 'populate' sets them as defaults/ICs.
        @test ic_dict["Central(t)"] == 100.0

        # B. Check Guesses
        # guesses(sys) should contain Central => 99.0
        guesses = MTK.guesses(sys_pop)
        guess_dict = Dict(string(k) => v for (k,v) in guesses)
        @test guess_dict["Central(t)"] == 99.0

        # C. Check Bindings (Locked Dependencies)
        # k_el should be bound to CL/V symbolic expression, NOT a number
        # bindings(sys) returns a Dict{Symbolic, Any}
        # In v11, structural_simplify will eliminate k_el if it's observed
        sys_simp = structural_simplify(sys_pop)

        # k_el should NOT be a tunable parameter in the simplified system
        # because it is defined by CL and V
        simp_params = parameters(sys_simp)
        @test !any(x -> string(x) == "k_el", simp_params)

        # CL and V SHOULD be parameters
        @test any(x -> string(x) == "CL", simp_params)
        @test any(x -> string(x) == "V", simp_params)

        # k_el should be an observed variable
        @test any(x -> occursin("k_el", string(x)), observed(sys_simp))
    end

    # -------------------------------------------------------------
    # 3. Test ODEProblem & Update
    # -------------------------------------------------------------
    @testset "ODEProblem & update()" begin
        sys_pop = populate(sys, keyfile)
        sys_simp = structural_simplify(sys_pop)
        prob = ODEProblem(sys_simp, [], (0.0, 10.0))

        # Baseline Solve
        # k_el = 10/100 = 0.1. Half-life ~ 6.93. At t=10, should be ~ 100 * exp(-1)
        sol = solve(prob, Tsit5())
        @test sol.retcode == ReturnCode.Success
        val_end = sol[Central][end]
        @test val_end ≈ 100.0 * exp(-0.1 * 10.0) atol=0.1

        # A. Update via Dictionary (Convenience Wrapper)
        # Change CL to 50.0 -> k_el becomes 0.5 -> Faster decay
        # We need the symbolic object for CL from the SIMPLIFIED system
        # (ConfigKit.update handles symbol-to-parameter mapping if possible,
        #  but providing Pair{Num, Val} is safest)

        @parameters CL_sym
        # We have to find the actual parameter object in the problem or system
        # For this test, we rely on the fact that `populate` mapped keyfile "CL" to system @parameters CL
        new_prob = update(prob, [CL => 50.0])

        sol_fast = solve(new_prob, Tsit5())
        val_fast = sol_fast[Central][end]

        # Should be 100 * exp(-0.5 * 10) ≈ 0.67
        @test val_fast < val_end
        @test val_fast ≈ 100.0 * exp(-0.5 * 10.0) atol=0.1
    end

    # Cleanup
    rm(path, force=true)
end
