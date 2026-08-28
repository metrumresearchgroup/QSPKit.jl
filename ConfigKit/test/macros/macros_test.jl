using Test
using ConfigKit
using ModelingToolkitBase
using Symbolics

@testset "Helper Macros" begin

    @testset "@common_constants" begin
        @testset "Creates expected parameters" begin
            # Use the macro in a local scope
            @common_constants

            # Verify all three constants are defined as symbolic parameters
            @test N_Av isa Symbolics.Num
            @test nmol_per_mol isa Symbolics.Num
            @test s_per_hr isa Symbolics.Num
        end

        @testset "Parameters have correct default values" begin
            @common_constants

            # Check default values using Symbolics.getdefaultval
            @test Symbolics.getdefaultval(N_Av) ≈ 6.022e23
            @test Symbolics.getdefaultval(nmol_per_mol) ≈ 1e9
            @test Symbolics.getdefaultval(s_per_hr) ≈ 3600
        end

        @testset "Works inside model function" begin
            function build_test_model(; name)
                @independent_variables t
                @common_constants

                @parameters k = 1.0
                @variables x(t)
                D = Differential(t)

                # Use the constants in an equation (MTK prunes unused parameters)
                flux = k * x / N_Av * nmol_per_mol * s_per_hr

                eqs = [D(x) ~ -flux]

                @named sys = System(eqs, t)
                return sys
            end

            sys = build_test_model(name = :test)

            # Verify constants are in the system's parameters
            # (only those used in equations are kept by MTK)
            params = ModelingToolkitBase.parameters(sys)
            param_names = [ModelingToolkitBase.getname(p) for p in params]

            @test :N_Av ∈ param_names
            @test :nmol_per_mol ∈ param_names
            @test :s_per_hr ∈ param_names
        end
    end

    @testset "@observed" begin
        @testset "Creates equation from local variable" begin
            @independent_variables t
            @parameters a = 1.0 b = 2.0
            @variables x(t) y(t)

            # Define a computed quantity
            ratio = x / y

            # Create observed equation
            obs_eq = @observed(ratio)

            # Should be an Equation
            @test obs_eq isa Symbolics.Equation

            # The RHS should be the expression
            @test isequal(obs_eq.rhs, ratio)

            # The LHS should be a variable named 'ratio'
            @test ModelingToolkitBase.getname(obs_eq.lhs) == :ratio
        end

        @testset "Works with multiple observed equations" begin
            @independent_variables t
            @parameters CL = 1.0 V = 10.0
            @variables central(t)

            # Multiple computed quantities
            conc = central / V
            clearance_rate = CL * conc

            # Create observed equations
            obs_eqs = [
                @observed(conc),
                @observed(clearance_rate)
            ]

            @test length(obs_eqs) == 2
            @test all(eq -> eq isa Symbolics.Equation, obs_eqs)

            # Verify names
            obs_names = [ModelingToolkitBase.getname(eq.lhs) for eq in obs_eqs]
            @test :conc ∈ obs_names
            @test :clearance_rate ∈ obs_names
        end

        @testset "Works in ODESystem observed argument" begin
            function build_pk_model(; name)
                @independent_variables t
                @parameters CL = 1.0 V = 10.0 dose = 100.0
                @variables central(t) = dose

                D = Differential(t)

                # Computed quantity to observe
                concentration = central / V

                eqs = [D(central) ~ -CL / V * central]

                @named sys = System(eqs, t; observed = [@observed(concentration)])
                return sys
            end

            sys = build_pk_model(name = :pk)

            # Verify the observed variable exists
            obs = ModelingToolkitBase.observed(sys)
            @test length(obs) == 1

            obs_names = [ModelingToolkitBase.getname(eq.lhs) for eq in obs]
            @test :concentration ∈ obs_names
        end

        @testset "Observed works with complex expressions" begin
            @independent_variables t
            @parameters ka = 0.5 ke = 0.1 V = 10.0
            @variables depot(t) central(t)

            # Complex expression
            total_drug = depot + central
            bioavailability = (1 - exp(-ka * t))

            obs_total = @observed(total_drug)
            obs_bio = @observed(bioavailability)

            @test ModelingToolkitBase.getname(obs_total.lhs) == :total_drug
            @test ModelingToolkitBase.getname(obs_bio.lhs) == :bioavailability
        end

        @testset "Creates equation with undeclared observed LHS" begin
            @independent_variables t
            @parameters V = 10.0
            @variables central(t)

            obs_eq = @observed(concentration ~ central / V)

            @test obs_eq isa Symbolics.Equation
            @test ModelingToolkitBase.getname(obs_eq.lhs) == :concentration
            @test isequal(obs_eq.rhs, central / V)
        end

        @testset "Creates block of observed equations" begin
            @independent_variables t
            @parameters CL = 1.0 V = 10.0
            @variables central(t) peripheral(t)

            obs_eqs = @observed begin
                concentration ~ central / V
                total_amount ~ central + peripheral
                clearance_rate ~ CL * central / V
            end

            @test length(obs_eqs) == 3
            @test all(eq -> eq isa Symbolics.Equation, obs_eqs)

            obs_names = [ModelingToolkitBase.getname(eq.lhs) for eq in obs_eqs]
            @test :concentration in obs_names
            @test :total_amount in obs_names
            @test :clearance_rate in obs_names
        end

        @testset "Block observed equations can reference earlier observed names" begin
            @independent_variables t
            @parameters V = 10.0
            @variables central(t) peripheral(t)

            obs_eqs = @observed begin
                total_amount ~ central + peripheral
                central_fraction ~ central / total_amount
            end

            total_amount_obs = obs_eqs[1].lhs
            @test ModelingToolkitBase.getname(total_amount_obs) == :total_amount
            @test isequal(obs_eqs[2].rhs, central / total_amount_obs)
        end

        @testset "Block RHS unresolved names fail at construction" begin
            @independent_variables t
            @variables central(t)

            err = try
                @observed begin
                    bad_output ~ central / missing_observed_parameter
                end
                nothing
            catch e
                e
            end

            @test err isa UndefVarError
            @test err.var == :missing_observed_parameter
        end

        @testset "Block RHS explicit parameters remain system parameters" begin
            function build_observed_parameter_model(; name)
                @independent_variables t
                @parameters k = 0.1 dose_nmol = 1.0
                @variables central(t) = 1.0
                D = Differential(t)

                eqs = [D(central) ~ -k * central]
                @named sys = System(eqs, t, [central], [k, dose_nmol]; observed = @observed begin
                    dose_scaled ~ central / dose_nmol
                end)
                return sys
            end

            sys = build_observed_parameter_model(name = :observed_param)
            param_names = [ModelingToolkitBase.getname(p) for p in ModelingToolkitBase.parameters(sys)]

            @test :dose_nmol in param_names
            @test ModelingToolkitBase.getvar(sys, :dose_nmol; namespace=false) !== nothing
        end

        @testset "Block form works in ODESystem observed argument" begin
            function build_pk_observed_block(; name)
                @independent_variables t
                @parameters CL = 1.0 V = 10.0 dose = 100.0
                @variables central(t) = dose

                D = Differential(t)
                eqs = [D(central) ~ -CL / V * central]

                @named sys = System(eqs, t; observed = @observed begin
                    concentration ~ central / V
                    amount_percent ~ 100 * central / dose
                end)
                return sys
            end

            sys = build_pk_observed_block(name = :pk_block)
            obs = ModelingToolkitBase.observed(sys)
            obs_names = [ModelingToolkitBase.getname(eq.lhs) for eq in obs]

            @test :concentration in obs_names
            @test :amount_percent in obs_names
        end
    end

    @testset "Integration: Both macros together" begin
        function build_scaled_signal_model(; name)
            @independent_variables t
            @common_constants

            @parameters begin
                input_level = 5.0
                gain = 2.0
            end

            @variables signal(t)
            D = Differential(t)

            # Exercise the legacy common constants in a dimensionless synthetic scale.
            # Constants must appear in equations to be retained by ModelingToolkit.
            reference_signal = input_level * gain / N_Av * nmol_per_mol

            normalized_signal = signal / reference_signal

            eqs = [D(signal) ~ -signal / N_Av * nmol_per_mol]

            @named sys = System(eqs, t; observed = [@observed(normalized_signal)])
            return sys
        end

        sys = build_scaled_signal_model(name = :scaled_signal)

        # Check that common constants are parameters (only used ones are kept by MTK)
        params = ModelingToolkitBase.parameters(sys)
        param_names = [ModelingToolkitBase.getname(p) for p in params]
        @test :N_Av ∈ param_names
        @test :nmol_per_mol ∈ param_names

        # Check that observed equation exists
        obs = ModelingToolkitBase.observed(sys)
        obs_names = [ModelingToolkitBase.getname(eq.lhs) for eq in obs]
        @test :normalized_signal ∈ obs_names
    end
end
