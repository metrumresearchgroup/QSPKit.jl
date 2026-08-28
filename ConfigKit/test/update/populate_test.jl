using Test
using ConfigKit
using ModelingToolkitBase
using OrdinaryDiffEq
using SciMLBase
using Symbolics
using DynamicQuantities

@testset "Populate Tests" begin

    # =================================================================
    # HELPER: Create a temporary keyfile
    # =================================================================
    function with_temp_keyfile(yaml_content)
        path = tempname() * ".yml"
        write(path, yaml_content)
        try
            return path
        catch
            rm(path, force=true)
            rethrow()
        end
    end

    # =================================================================
    # TEST 1: Basic Population
    # =================================================================
    @testset "Basic Population" begin
        # Define a simple PK model
        @independent_variables t
        @parameters CL V
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -CL/V * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
        Variables:
          Central:
            initial: 50.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Check that it returns a completed system
            @test sys_pop isa MTK.AbstractSystem

            # Check initial conditions
            ics = MTK.get_initial_conditions(sys_pop)
            @test !isempty(ics)

            # Check that the system can be compiled and solved
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    @testset "Observed-only parameters are retained" begin
        @independent_variables t
        @parameters k = 0.1 dose_nmol
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -k * x]
        @named sys = System(eqs, t; observed = @observed begin
            dose_scaled ~ x / dose_nmol
        end)

        yaml_content = """
        Parameters:
          k:
            value: 0.1
        Variables:
          x:
            initial: 1.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)
            sys_simp = mtkcompile(sys_pop)

            param_names = [MTK.getname(p) for p in MTK.parameters(sys_simp)]
            @test :dose_nmol in param_names

            err = try
                ODEProblem(sys_simp, [], (0.0, 1.0))
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            err_msg = sprint(showerror, err)
            @test occursin("ConfigKit: Missing required runtime parameter 'dose_nmol'", err_msg)
            @test occursin("dose_scaled", err_msg)
            @test occursin("sys.dose_nmol => value", err_msg)

            dose_sym = MTK.getvar(sys_simp, :dose_nmol; namespace=false)
            prob = ODEProblem(sys_simp, [dose_sym => 10.0], (0.0, 1.0))
            sol = solve(prob, Tsit5(); saveat=[0.0, 1.0])

            @test sol.retcode == ReturnCode.Success
            @test sol[:dose_scaled][1] ≈ 0.1
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 2: Locked Dependencies (Bindings)
    # =================================================================
    @testset "Locked Dependencies" begin
        @independent_variables t
        @parameters CL V k_el
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -k_el * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
          k_el:
            value: CL / V
        Variables:
          Central:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Check bindings contain k_el (expression-valued params become bindings)
            bindings = MTK.get_bindings(sys_pop)
            binding_names = [string(MTK.getname(k)) for (k,v) in bindings]
            @test "k_el" in binding_names

            # k_el binding should be symbolic (CL/V), not a number
            for (k, v) in bindings
                if string(MTK.getname(k)) == "k_el"
                    @test v isa Symbolics.Num || Symbolics.iscall(Symbolics.unwrap(v))
                    break
                end
            end

            # After mtkcompile, k_el should be eliminated
            sys_simp = mtkcompile(sys_pop)
            simp_params = MTK.parameters(sys_simp)
            simp_param_names = [string(MTK.getname(p)) for p in simp_params]

            # CL and V should remain as tunable parameters
            @test "CL" in simp_param_names
            @test "V" in simp_param_names

            # k_el should NOT be a parameter (it's derived)
            @test !("k_el" in simp_param_names)
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 3: Guesses
    # =================================================================
    @testset "Guesses" begin
        @independent_variables t
        @parameters k
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -k * x]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          k:
            value: 0.1
        Variables:
          x:
            initial: 100.0
            guess: 99.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Check guesses
            guesses = MTK.get_guesses(sys_pop)
            @test !isempty(guesses)

            # There should be a guess for x
            guess_names = [string(MTK.getname(k)) for (k,v) in guesses]
            @test any(n -> occursin("x", n), guess_names)
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 4: Overrides
    # =================================================================
    @testset "Overrides" begin
        @independent_variables t
        @parameters CL V
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -CL/V * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
        Variables:
          Central:
            initial: 50.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)

            # Override CL to 20.0
            sys_pop = populate(sys, keyfile; overrides=Dict("CL" => 20.0), strict=false)

            # Verify override worked by compiling and solving
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))

            # With CL=20, V=100: k_el = 0.2
            # Central(t) = 50 * exp(-0.2 * t)
            # At t=10: ~50 * exp(-2) ≈ 6.77
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success

            # Compare with expected result using CL=20 (not 10)
            expected_with_override = 50.0 * exp(-20.0/100.0 * 10.0)
            expected_without_override = 50.0 * exp(-10.0/100.0 * 10.0)
            final_val = sol[Central][end]

            # Should be closer to overridden value
            @test abs(final_val - expected_with_override) < abs(final_val - expected_without_override)
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 5: Cannot Override Locked Parameter
    # =================================================================
    @testset "Cannot Override Locked Parameter" begin
        @independent_variables t
        @parameters CL V k_el
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -k_el * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
          k_el:
            value: CL / V
        Variables:
          Central:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)

            # Attempting to override an expression-valued parameter should error
            @test_throws ErrorException populate(sys, keyfile; overrides=Dict("k_el" => 0.5), strict=false)
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 6: Invalid Override Key
    # =================================================================
    @testset "Invalid Override Key" begin
        @independent_variables t
        @parameters CL V
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -CL/V * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
        Variables:
          Central:
            initial: 50.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)

            # Override with invalid key should error
            @test_throws ErrorException populate(sys, keyfile; overrides=Dict("INVALID_KEY" => 999.0), strict=false)
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 7: String Path Convenience Method
    # =================================================================
    @testset "String Path Convenience" begin
        @independent_variables t
        @parameters k
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -k * x]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          k:
            value: 0.1
        Variables:
          x:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            # Can call populate directly with path string
            sys_pop = populate(sys, path; strict=false)
            @test sys_pop isa MTK.AbstractSystem
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 8: populate! (In-Place Update)
    # =================================================================
    @testset "populate! In-Place" begin
        @independent_variables t
        @parameters CL V
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -CL/V * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
        Variables:
          Central:
            initial: 50.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            # First create an ODEProblem with default values
            sys_complete = mtkcompile(complete(sys))
            prob = ODEProblem(sys_complete, [Central => 1.0, CL => 1.0, V => 1.0], (0.0, 10.0))

            # Now populate! to update with keyfile values
            keyfile = load_keyfile(path)
            new_prob = populate!(prob, keyfile)

            # Verify parameters were updated
            @test new_prob isa SciMLBase.ODEProblem

            # Solve to verify it works
            sol = solve(new_prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 9: Ghost Parameters (CL/V referenced but k_el defined)
    # =================================================================
    @testset "Ghost Parameter Injection" begin
        # System only has k_el as parameter, but keyfile defines CL and V
        @independent_variables t
        @parameters k_el
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -k_el * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
          k_el:
            value: CL / V
        Variables:
          Central:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            # CL and V are "ghost" parameters - not in original system
            # but needed for the k_el binding
            sys_pop = populate(sys, keyfile; strict=false)

            # After populate, CL and V should be injected as parameters
            sys_simp = mtkcompile(sys_pop)
            param_names = [string(MTK.getname(p)) for p in MTK.parameters(sys_simp)]

            # Ghost parameters should have been injected
            @test "CL" in param_names
            @test "V" in param_names

            # k_el should be eliminated (it's a binding)
            @test !("k_el" in param_names)

            # Should solve correctly
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 10: Constants Block
    # =================================================================
    @testset "Constants Block" begin
        @independent_variables t
        @parameters k unit_scale
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -k * x]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          k:
            value: 0.1
        Constants:
          unit_scale:
            value: 7.0
        Variables:
          x:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Constants should be set as non-tunable parameters
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 10b: Constants Used in Parameter Expressions
    # =================================================================
    @testset "Constants in Expressions" begin
        # This tests the scenario where a constant is used in a parameter expression
        # e.g., scaled_rate = raw_rate / unit_scale where unit_scale is a constant
        @independent_variables t
        @parameters scaled_rate raw_rate
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -scaled_rate * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          raw_rate:
            value: 1000.0
            description: "Raw rate"
          scaled_rate:
            value: raw_rate / unit_scale
            description: "Rate computed from a conversion constant"
        Constants:
          unit_scale:
            value: 1.0e6
            description: "Synthetic unit conversion factor"
        Variables:
          Central:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Verify the constant is in the system's parameters
            param_names = [string(MTK.getname(p)) for p in MTK.parameters(sys_pop)]
            @test "unit_scale" in param_names

            # The system should compile and solve successfully
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success

            # Verify the computed value: scaled_rate = 1000 / 1e6 = 0.001
            # Access the parameter value from the solution
            scaled_rate_val = prob.ps[MTK.parse_variable(sys_simp, "scaled_rate")]
            @test isapprox(scaled_rate_val, 0.001; rtol=1e-6)
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 11: Variant Support in Populate
    # =================================================================
    @testset "Variant Support" begin
        @independent_variables t
        @parameters CL V
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -CL/V * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            variants:
              human: {value: 10.0}
              mouse: {value: 0.1}
          V:
            variants:
              human: {value: 100.0}
              mouse: {value: 0.01}
        Variables:
          Central:
            variants:
              human: {initial: 50.0}
              mouse: {initial: 0.5}
        """
        path = with_temp_keyfile(yaml_content)

        try
            # Load with human variant
            keyfile_human = load_keyfile(path; variant=:human)
            sys_pop_human = populate(sys, keyfile_human; strict=false)
            sys_simp = mtkcompile(sys_pop_human)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success

            # Load with mouse variant
            keyfile_mouse = load_keyfile(path; variant=:mouse)
            sys_pop_mouse = populate(sys, keyfile_mouse; strict=false)
            sys_simp_mouse = mtkcompile(sys_pop_mouse)
            prob_mouse = ODEProblem(sys_simp_mouse, [], (0.0, 10.0))
            sol_mouse = solve(prob_mouse, Tsit5())
            @test sol_mouse.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 12: Strict Mode - Missing Parameter
    # =================================================================
    @testset "Strict Mode Missing Parameter" begin
        @independent_variables t
        @parameters CL V extra_param
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -CL/V * Central - extra_param]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
        Variables:
          Central:
            initial: 50.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)

            # With strict=true (default), should warn/error about missing extra_param
            # With strict=false, should still work
            sys_pop = populate(sys, keyfile; strict=false)
            @test sys_pop isa MTK.AbstractSystem
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 13: Numeric Locked Dependency (Resolves to Number)
    # =================================================================
    @testset "Numeric Locked Dependency" begin
        @independent_variables t
        @parameters k_el
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -k_el * x]
        @named sys = System(eqs, t)

        # k_el is an expression that evaluates to a number (becomes binding)
        yaml_content = """
        Parameters:
          k_el:
            value: 2.0 * 0.05
        Variables:
          x:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Since 2.0 * 0.05 = 0.1 is just a number, k_el should be a regular parameter
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success

            # x(t) = 100 * exp(-0.1 * t), at t=10: ~36.79
            expected = 100.0 * exp(-0.1 * 10.0)
            @test sol[x][end] ≈ expected atol=0.1
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 14: Strict Mode Validation (strict=true)
    # =================================================================
    @testset "Strict Mode Validation" begin
        @independent_variables t
        @parameters CL V
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -CL/V * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
        Variables:
          Central:
            initial: 50.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            # Use strict=true (default) - should run validation
            sys_pop = populate(sys, keyfile; strict=true)
            @test sys_pop isa MTK.AbstractSystem

            # Verify it can be compiled and solved
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 15: Multiple Locked Dependencies (Chain)
    # =================================================================
    @testset "Chained Locked Dependencies" begin
        @independent_variables t
        @parameters CL V1 V2 k_el Vss
        @variables Central(t) Peripheral(t)
        D = Differential(t)

        eqs = [
            D(Central) ~ -k_el * Central,
            D(Peripheral) ~ 0.0
        ]
        @named sys = System(eqs, t)

        # Vss = V1 + V2, k_el = CL / Vss (chained dependency)
        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V1:
            value: 50.0
          V2:
            value: 50.0
          Vss:
            value: V1 + V2
          k_el:
            value: CL / Vss
        Variables:
          Central:
            initial: 100.0
          Peripheral:
            initial: 0.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Check that both Vss and k_el are bindings
            bindings = MTK.get_bindings(sys_pop)
            binding_names = [string(MTK.getname(k)) for (k,v) in bindings]
            @test "k_el" in binding_names
            @test "Vss" in binding_names

            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 16: Description Metadata
    # =================================================================
    @testset "Description Metadata" begin
        @independent_variables t
        @parameters CL V
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -CL/V * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
            description: "Systemic clearance"
          V:
            value: 100.0
            desc: "Volume of distribution"
        Variables:
          Central:
            initial: 50.0
            description: "Central compartment amount"
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)

            # Check descriptions are loaded
            @test get(keyfile.Parameters.CL.metadata, :description, "") == "Systemic clearance"
            @test get(keyfile.Parameters.V.metadata, :description, "") == "Volume of distribution"

            sys_pop = populate(sys, keyfile; strict=false)
            @test sys_pop isa MTK.AbstractSystem
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 17: solve_for - Uses Initialization System
    # =================================================================
    @testset "solve_for - Initialization System" begin
        @independent_variables t
        @parameters CL V k_el
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -k_el * Central]
        @named sys = System(eqs, t)

        # k_el = CL/V is an expression in keyfile
        # Using solve_for to opt into initialization system:
        # - k_el, CL, V all bound to missing
        # - CL and V have guesses (10.0, 100.0)
        # - initialization_eqs contains k_el ~ CL/V
        # - The init solver computes k_el = 0.1 at t=0
        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
          k_el:
            value: CL / V
        Variables:
          Central:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false, solve_for=[:k_el => [:CL, :V]])
            sys_pop_from_path = populate(
                sys, path; strict=false, solve_for=[:k_el => [:CL, :V]])
            @test !isempty(MTK.get_initialization_eqs(sys_pop_from_path))

            # k_el (the solve_for target) should be bound to missing
            bindings = MTK.get_bindings(sys_pop)
            binding_vals = Dict(string(MTK.getname(k)) => v for (k,v) in bindings)
            @test haskey(binding_vals, "k_el")
            # Note: MTK stores missing as a symbolic value, need to unwrap
            @test ismissing(Symbolics.value(binding_vals["k_el"]))

            # CL and V have numeric values - they should have guesses for the init system
            guesses = MTK.get_guesses(sys_pop)
            guess_vals = Dict(string(MTK.getname(k)) => Symbolics.value(v) for (k,v) in guesses)
            @test haskey(guess_vals, "CL")
            @test haskey(guess_vals, "V")
            @test guess_vals["CL"] ≈ 10.0
            @test guess_vals["V"] ≈ 100.0

            # initialization_eqs should contain k_el ~ CL/V
            init_eqs = MTK.get_initialization_eqs(sys_pop)
            @test length(init_eqs) >= 1

            # Should solve correctly - init system computes k_el = 10/100 = 0.1
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success

            # Verify k_el was 0.1 by checking solution dynamics
            final_val = sol[Central][end]
            expected = 100.0 * exp(-0.1 * 10.0)
            @test final_val ≈ expected atol=0.1
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 18: Expression Bindings (without solve_for)
    # =================================================================
    @testset "Expression Bindings Without solve_for" begin
        # Test that expression-valued parameters become symbolic bindings
        # when solve_for is NOT used.
        @independent_variables t
        @parameters CL V k_el
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -k_el * Central]
        @named sys = System(eqs, t)

        # k_el = CL/V is an expression - becomes a binding (computed on the fly)
        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
          k_el:
            value: CL / V
        Variables:
          Central:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            # NO solve_for - k_el should be a symbolic binding
            sys_pop = populate(sys, keyfile; strict=false)
            @test sys_pop isa MTK.AbstractSystem

            # k_el should be a binding (expression, NOT missing)
            bindings = MTK.get_bindings(sys_pop)
            binding_vals = Dict(string(MTK.getname(k)) => v for (k,v) in bindings)
            @test haskey(binding_vals, "k_el")
            # The binding should NOT be missing (it's the symbolic expression)
            @test !ismissing(binding_vals["k_el"])

            # Should solve correctly - k_el = CL/V = 0.1
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            @test_throws BindingUpdateError populate!(prob, keyfile; strict=true)
            relaxed_prob = populate!(prob, keyfile; strict=false)
            @test relaxed_prob isa SciMLBase.ODEProblem
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success

            final_val = sol[Central][end]
            expected = 100.0 * exp(-0.1 * 10.0)
            @test final_val ≈ expected atol=0.1
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 19: Full Integration - Solve and Verify
    # =================================================================
    @testset "Full Integration" begin
        @independent_variables t
        @parameters CL V k_el
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -k_el * Central]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
          k_el:
            value: CL / V
        Variables:
          Central:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))

            # Solve
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success

            # k_el = CL/V = 10/100 = 0.1
            # Central(t) = 100 * exp(-0.1 * t)
            # At t=10: Central ≈ 100 * exp(-1) ≈ 36.79
            final_val = sol[Central][end]
            expected = 100.0 * exp(-0.1 * 10.0)
            @test final_val ≈ expected atol=0.1
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 20: LockDependency in YAML Throws Error
    # =================================================================
    @testset "LockDependency in YAML Throws Error" begin
        yaml_content = """
        Parameters:
          k_el:
            value: 0.1
            LockDependency: true
        """
        path = with_temp_keyfile(yaml_content)

        try
            # Should throw an error - LockDependency is no longer valid
            @test_throws ErrorException load_keyfile(path)
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 21: solve_for with Custom Equation
    # =================================================================
    @testset "solve_for - Custom Equation" begin
        @independent_variables t
        @parameters CL V k_el
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -k_el * Central]
        # Explicitly include CL and V as parameters even though they don't appear in equations
        # They are used by the solve_for custom equation: k_el ~ CL / V
        @named sys = System(eqs, t, [Central], [CL, V, k_el])

        # k_el has numeric value, but we can override with custom equation
        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
          k_el:
            value: 0.5
        Variables:
          Central:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            # Use custom equation instead of keyfile expression
            sys_pop = populate(sys, keyfile; strict=false,
                              solve_for=["k_el ~ CL / V" => [:CL, :V]])
            @test sys_pop isa MTK.AbstractSystem

            # initialization_eqs should contain k_el ~ CL/V
            init_eqs = MTK.get_initialization_eqs(sys_pop)
            @test length(init_eqs) >= 1

            # Should solve correctly - init system computes k_el = 0.1
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success

            final_val = sol[Central][end]
            expected = 100.0 * exp(-0.1 * 10.0)
            @test final_val ≈ expected atol=0.1
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 22: solve_for - Error When Target Has No Expression
    # =================================================================
    @testset "solve_for - Error When Target Has No Expression" begin
        @independent_variables t
        @parameters CL V k_el
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -k_el * x]
        @named sys = System(eqs, t)

        # CL has numeric value (no expression)
        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
          k_el:
            value: 0.1
        Variables:
          x:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            # Should throw - CL has no expression to solve
            @test_throws ErrorException populate(sys, keyfile; strict=false,
                                                  solve_for=[:CL => [:V]])
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 23: solve_for - Error When Adjustable Has Expression
    # =================================================================
    @testset "solve_for - Error When Adjustable Has Expression" begin
        @independent_variables t
        @parameters CL V k_el
        @variables Central(t)
        D = Differential(t)

        eqs = [D(Central) ~ -k_el * Central]
        @named sys = System(eqs, t)

        # Both k_el and V have expressions
        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: CL * 10
          k_el:
            value: CL / V
        Variables:
          Central:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            # Should throw - V has expression, can't be adjustable
            @test_throws ErrorException populate(sys, keyfile; strict=false,
                                                  solve_for=[:k_el => [:CL, :V]])
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 24: solve_for - Multiple Targets
    # =================================================================
    @testset "solve_for - Multiple Targets" begin
        @independent_variables t
        @parameters a b k1 k2
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -(k1 + k2) * x]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          a:
            value: 2.0
          b:
            value: 3.0
          k1:
            value: a * 2
          k2:
            value: b * 3
        Variables:
          x:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            # Multiple solve_for targets sharing some adjustable params
            sys_pop = populate(sys, keyfile; strict=false,
                              solve_for=[:k1 => [:a], :k2 => [:b]])
            @test sys_pop isa MTK.AbstractSystem

            # Both should be in initialization equations
            init_eqs = MTK.get_initialization_eqs(sys_pop)
            @test length(init_eqs) >= 2

            # a and b should have guesses
            guesses = MTK.get_guesses(sys_pop)
            guess_vals = Dict(string(MTK.getname(k)) => Symbolics.value(v) for (k,v) in guesses)
            @test guess_vals["a"] ≈ 2.0
            @test guess_vals["b"] ≈ 3.0

            # Should solve correctly
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 25: solve_for - Adjustable Param Not Found Error
    # =================================================================
    @testset "solve_for - Adjustable Param Not Found" begin
        @independent_variables t
        @parameters CL V k_el
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -k_el * x]
        @named sys = System(eqs, t)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
          k_el:
            value: CL / V
        Variables:
          x:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            # Should throw - :nonexistent doesn't exist
            @test_throws ErrorException populate(sys, keyfile; strict=false,
                                                  solve_for=[:k_el => [:CL, :nonexistent]])
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 26: Unit Conversion with 'convert' field
    # =================================================================
    @testset "Unit Conversion with convert field" begin
        @independent_variables t
        @parameters Thalf k_el
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -k_el * x]
        # Explicitly include Thalf as a parameter even though it's not in equations
        @named sys = System(eqs, t, [x], [Thalf, k_el])

        # Thalf is specified in hours but should be converted to seconds
        # k_el is specified in hr^-1 but should be converted to s^-1
        yaml_content = """
        Parameters:
          Thalf:
            value: 2.0
            unit: hr
            convert: s
          k_el:
            value: 0.1
            unit: hr^-1
            convert: s^-1
        Variables:
          x:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)
            @test sys_pop isa MTK.AbstractSystem

            # Verify conversion: 2.0 hr = 7200 s
            ics = MTK.get_initial_conditions(sys_pop)
            thalf_val = nothing
            k_el_val = nothing
            for (k, v) in ics
                name = string(MTK.getname(k))
                if name == "Thalf"
                    thalf_val = Symbolics.value(v)
                elseif name == "k_el"
                    k_el_val = Symbolics.value(v)
                end
            end

            @test thalf_val ≈ 7200.0 atol=0.1  # 2.0 hr * 3600 s/hr = 7200 s
            @test k_el_val ≈ 0.1/3600.0 atol=1e-8  # 0.1 hr^-1 / 3600 = 2.78e-5 s^-1
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 27: Unit Conversion without original unit should warn
    # =================================================================
    @testset "Unit Conversion without original unit" begin
        @independent_variables t
        @parameters k
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -k * x]
        @named sys = System(eqs, t)

        # k has convert but no unit - should warn but not error
        yaml_content = """
        Parameters:
          k:
            value: 0.1
            convert: s^-1
        Variables:
          x:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            # Should warn but not error - value stays as-is
            sys_pop = populate(sys, keyfile; strict=false)
            @test sys_pop isa MTK.AbstractSystem

            # Value should be unchanged since no conversion possible
            ics = MTK.get_initial_conditions(sys_pop)
            k_val = nothing
            for (k_sym, v) in ics
                name = string(MTK.getname(k_sym))
                if name == "k"
                    k_val = Symbolics.value(v)
                end
            end
            @test k_val ≈ 0.1 atol=1e-10  # No conversion applied
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 28: Unit Conversion on expression-valued parameter should warn
    # =================================================================
    @testset "Unit Conversion on expression warns" begin
        @independent_variables t
        @parameters CL V k_el
        @variables x(t)
        D = Differential(t)

        eqs = [D(x) ~ -k_el * x]
        @named sys = System(eqs, t, [x], [CL, V, k_el])

        # k_el is an expression (CL/V) with convert - should warn but not error
        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
          k_el:
            value: CL / V
            unit: hr^-1
            convert: s^-1
        Variables:
          x:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            # Should warn but not error - expression binding preserved
            sys_pop = populate(sys, keyfile; strict=false)
            @test sys_pop isa MTK.AbstractSystem

            # k_el should be a binding, not a numeric value
            bindings = MTK.get_bindings(sys_pop)
            has_k_el_binding = any(string(MTK.getname(k)) == "k_el" for (k, v) in bindings)
            @test has_k_el_binding  # Expression binding should be preserved
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 29: Parameters/Variables Not In Keyfile Are Preserved
    # =================================================================
    @testset "Parameters/Variables Not In Keyfile Are Preserved" begin
        @independent_variables t
        @parameters CL V extra_param
        @variables Central(t) extra_var(t)
        D = Differential(t)

        # extra_param and extra_var are in the model but NOT in the keyfile
        eqs = [
            D(Central) ~ -CL/V * Central + extra_param,
            D(extra_var) ~ -0.1 * extra_var
        ]
        @named sys = System(eqs, t)

        # Keyfile only defines CL, V, and Central - NOT extra_param or extra_var
        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
        Variables:
          Central:
            initial: 50.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Check that extra_param is still in the system's parameters
            param_names = [string(MTK.getname(p)) for p in MTK.parameters(sys_pop)]
            @test "extra_param" in param_names
            @test "CL" in param_names
            @test "V" in param_names

            # Check that extra_var is still in the system's unknowns
            unknown_names = [string(MTK.getname(v)) for v in MTK.unknowns(sys_pop)]
            @test "extra_var" in unknown_names
            @test "Central" in unknown_names

            # System should still be valid
            @test sys_pop isa MTK.AbstractSystem
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 30: Model Metadata Takes Precedence Over Keyfile Metadata
    # =================================================================
    @testset "Model Metadata Takes Precedence Over Keyfile" begin
        @independent_variables t
        # Define parameter with unit and description in the MODEL
        @parameters CL [description = "Model Clearance"]
        @parameters V
        @variables Central(t) [description = "Model Central Amount"]
        D = Differential(t)

        # Use simple equation to avoid unit validation issues at System creation time
        # The test is about metadata precedence, not PK math
        eqs = [D(Central) ~ -CL/V * Central]
        @named sys = System(eqs, t)

        # Keyfile tries to set different unit and description
        yaml_content = """
        Parameters:
          CL:
            value: 10.0
            unit: mL/s
            description: "Keyfile Clearance"
          V:
            value: 100.0
            unit: L
            description: "Keyfile Volume"
        Variables:
          Central:
            initial: 50.0
            unit: g
            description: "Keyfile Central Amount"
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Find CL in populated system and check its metadata
            cl_param = nothing
            for p in MTK.parameters(sys_pop)
                if string(MTK.getname(p)) == "CL"
                    cl_param = p
                    break
                end
            end
            @test cl_param !== nothing

            # CL should have MODEL's description (not keyfile's)
            cl_desc = Symbolics.getmetadata(cl_param, MTK.VariableDescription, nothing)
            @test cl_desc == "Model Clearance"

            # Find Central in populated system and check its metadata
            central_var = nothing
            for v in MTK.unknowns(sys_pop)
                if string(MTK.getname(v)) == "Central"
                    central_var = v
                    break
                end
            end
            @test central_var !== nothing

            # Central should have MODEL's description (not keyfile's)
            central_desc = Symbolics.getmetadata(central_var, MTK.VariableDescription, nothing)
            @test central_desc == "Model Central Amount"

            # V should have KEYFILE's description (since model didn't define one)
            v_param = nothing
            for p in MTK.parameters(sys_pop)
                if string(MTK.getname(p)) == "V"
                    v_param = p
                    break
                end
            end
            @test v_param !== nothing
            v_desc = Symbolics.getmetadata(v_param, MTK.VariableDescription, nothing)
            @test v_desc == "Keyfile Volume"
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 31: Model Unit Metadata Takes Precedence Over Keyfile
    # =================================================================
    @testset "Model Unit Takes Precedence Over Keyfile" begin
        @independent_variables t
        # Define parameters with units in the MODEL
        # CL: L/hr in model, keyfile tries mL/s → model should win
        # V: L in model, keyfile tries mL → model should win
        @parameters CL [unit = DynamicQuantities.u"L/hr"]
        @parameters V [unit = DynamicQuantities.u"L"]
        @variables Central(t)
        D = Differential(t)

        # Simple equation to avoid unit validation complexities
        # The test is about metadata precedence, not PK math
        eqs = [D(Central) ~ -CL/V * Central]
        @named sys = System(eqs, t; checks=false)

        # Keyfile tries to set different unit for CL
        yaml_content = """
        Parameters:
          CL:
            value: 10.0
            unit: mL/s
          V:
            value: 100.0
            unit: mL
        Variables:
          Central:
            initial: 50.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Find CL and check its unit metadata
            cl_param = nothing
            for p in MTK.parameters(sys_pop)
                if string(MTK.getname(p)) == "CL"
                    cl_param = p
                    break
                end
            end
            @test cl_param !== nothing

            # CL should have MODEL's unit (L/hr), not keyfile's (mL/s)
            cl_unit = Symbolics.getmetadata(cl_param, MTK.VariableUnit, nothing)
            @test cl_unit !== nothing
            # Check dimension matches L/hr (volume/time)
            @test string(DynamicQuantities.dimension(cl_unit)) == string(DynamicQuantities.dimension(DynamicQuantities.u"L/hr"))

            # V should have MODEL's unit (L), not keyfile's (mL)
            v_param = nothing
            for p in MTK.parameters(sys_pop)
                if string(MTK.getname(p)) == "V"
                    v_param = p
                    break
                end
            end
            @test v_param !== nothing
            v_unit = Symbolics.getmetadata(v_param, MTK.VariableUnit, nothing)
            @test v_unit !== nothing
            # V should keep model's unit (L)
            @test string(DynamicQuantities.dimension(v_unit)) == string(DynamicQuantities.dimension(DynamicQuantities.u"L"))
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 32: Algebraic Variables Get Guesses, Not Initial Conditions
    # =================================================================
    @testset "Algebraic Variables Don't Get ICs" begin
        @independent_variables t
        @parameters CL V
        @variables Central(t) concentration(t)
        D = Differential(t)

        # Central has a differential equation (state variable)
        # concentration is algebraic (observed equation, no D(concentration))
        eqs = [D(Central) ~ -CL/V * Central]
        obs = [concentration ~ Central / V]
        @named sys = System(eqs, t; observed=obs)

        yaml_content = """
        Parameters:
          CL:
            value: 10.0
          V:
            value: 100.0
        Variables:
          Central:
            initial: 50.0
          concentration:
            initial: 0.5
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Check initial conditions - Central should be there, concentration should NOT
            # Algebraic variables are computed from their equations, not from Initial()
            ics = MTK.get_initial_conditions(sys_pop)
            ic_names = [string(MTK.getname(k)) for (k,v) in ics]
            @test any(n -> endswith(n, "Central"), ic_names)  # Differential variable gets IC
            @test !any(n -> endswith(n, "concentration"), ic_names)  # Algebraic variable should NOT get IC

            # System should compile and solve successfully
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 33: Mixed Differential and Algebraic Variables
    # =================================================================
    @testset "Mixed Differential and Algebraic Variables" begin
        @independent_variables t
        @parameters k
        @variables x(t) y(t) z(t)
        D = Differential(t)

        # x and y are differential (state) variables
        # z is algebraic (observed, no D(z))
        eqs = [
            D(x) ~ -k * x,
            D(y) ~ k * x - k * y
        ]
        obs = [z ~ x + y]
        @named sys = System(eqs, t; observed=obs)

        yaml_content = """
        Parameters:
          k:
            value: 0.1
        Variables:
          x:
            initial: 100.0
          y:
            initial: 0.0
          z:
            initial: 100.0
        """
        path = with_temp_keyfile(yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)

            # Check initial conditions - x and y should be there, z should NOT
            # Algebraic variables are computed from their equations, not from Initial()
            ics = MTK.get_initial_conditions(sys_pop)
            ic_names = [string(MTK.getname(k)) for (k,v) in ics]
            @test any(n -> endswith(n, "x"), ic_names)  # Differential variable
            @test any(n -> endswith(n, "y"), ic_names)  # Differential variable
            @test !any(n -> endswith(n, "z"), ic_names)  # Algebraic variable should NOT get IC

            # System should compile and solve successfully
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 34: mtkcompile() BEFORE populate() - User's Workflow
    # =================================================================
    @testset "mtkcompile Before populate - Algebraic Variables" begin
        # This test mimics the user's workflow:
        # 1. Build system with ALL equations in eqs (NO explicit observed)
        # 2. mtkcompile() - INFERS observed from algebraic equations
        # 3. populate() - must handle namespaced algebraic variables correctly
        # 4. ODEProblem() - should not fail with Initial() errors

        @independent_variables t34
        @parameters CL34 V34
        @variables Drug34(t34) conc34(t34)
        D34 = Differential(t34)

        eqs34 = [
            D34(Drug34) ~ -CL34/V34 * Drug34,
            conc34 ~ Drug34 / V34  # algebraic equation, no D()
        ]
        @named sys34 = System(eqs34, t34)

        yaml_content = """
        Parameters:
          CL34:
            value: 10.0
          V34:
            value: 100.0
        Variables:
          Drug34:
            initial: 50.0
          conc34:
            initial: 0.5
        """
        path = with_temp_keyfile(yaml_content)

        try
            # mtkcompile BEFORE populate - moves conc34 to observed
            sys34_compiled = mtkcompile(sys34)

            keyfile = load_keyfile(path)
            sys34_pop = populate(sys34_compiled, keyfile; strict=false)

            # conc34 should NOT be in ICs (it's observed/algebraic)
            ics = MTK.get_initial_conditions(sys34_pop)
            ic_names = [string(MTK.getname(k)) for (k,v) in ics]
            @test !any(n -> occursin("conc34", n), ic_names)

            # ODEProblem should not fail
            prob = ODEProblem(sys34_pop, nothing, (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 35: populate() BEFORE mtkcompile() - User's Actual Workflow
    # =================================================================
    @testset "populate Before mtkcompile - Algebraic Variables" begin
        # This test mimics the user's ACTUAL workflow:
        # 1. Build system with ALL equations in eqs (NO explicit observed)
        # 2. populate() FIRST - must detect algebraic vars from equations
        # 3. mtkcompile() - moves algebraic vars to observed
        # 4. ODEProblem() - should not fail with Initial() errors

        @independent_variables t35
        @parameters CL35 V35
        @variables Drug35(t35) conc35(t35)
        D35 = Differential(t35)

        eqs35 = [
            D35(Drug35) ~ -CL35/V35 * Drug35,
            conc35 ~ Drug35 / V35  # algebraic equation, no D()
        ]
        @named sys35 = System(eqs35, t35)

        yaml_content = """
        Parameters:
          CL35:
            value: 10.0
          V35:
            value: 100.0
        Variables:
          Drug35:
            initial: 50.0
          conc35:
            initial: 0.5
        """
        path = with_temp_keyfile(yaml_content)

        try
            # populate BEFORE mtkcompile
            # conc35 is still in unknowns but its equation is algebraic
            keyfile = load_keyfile(path)
            sys35_pop = populate(sys35, keyfile; strict=false)

            # mtkcompile moves conc35 to observed
            sys35_compiled = mtkcompile(sys35_pop)

            # conc35 should NOT be in ICs (it's algebraic)
            ics = MTK.get_initial_conditions(sys35_compiled)
            ic_names = [string(MTK.getname(k)) for (k,v) in ics]
            @test !any(n -> occursin("conc35", n), ic_names)

            # ODEProblem should not fail
            prob = ODEProblem(sys35_compiled, nothing, (0.0, 10.0))
            sol = solve(prob, Tsit5())
            @test sol.retcode == ReturnCode.Success
        finally
            rm(path, force=true)
        end
    end

end
