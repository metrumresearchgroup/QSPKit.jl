using Test
using ConfigKit
using OrdinaryDiffEq
using SciMLBase
using Symbolics
using ModelingToolkitBase
using Unitful
@testset "Update Engine Tests" begin

    # =================================================================
    # SETUP: Create a reusable test system
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
        # Return namespaced symbols from the compiled system
        return csys, csys.α, csys.β, csys.γ, csys.x, csys.y
    end

    # =================================================================
    # TEST 1: update(ODEProblem, pairs) - Basic Parameter Update
    # =================================================================
    @testset "ODEProblem Parameter Update" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))

        # Update α to a new value
        new_prob = update(prob, [α => 5.0])

        # Should return a new problem
        @test new_prob isa SciMLBase.ODEProblem
        @test new_prob !== prob  # Different object

        # Solve both and verify different dynamics
        sol_orig = solve(prob, Tsit5())
        sol_new = solve(new_prob, Tsit5())

        @test sol_orig.retcode == ReturnCode.Success
        @test sol_new.retcode == ReturnCode.Success

        # With different α, the solutions should differ
        @test sol_orig[x][end] != sol_new[x][end]
    end

    @testset "Cached setter is problem scoped" begin
        sys1, α1, β1, γ1, x1, y1 = create_test_system()
        prob1 = ODEProblem(sys1, [x1 => 1.0, y1 => 0.0], (0.0, 10.0))

        sys2, α2, β2, γ2, x2, y2 = create_test_system()
        prob2 = ODEProblem(sys2, [x2 => 2.0, y2 => 0.0], (0.0, 10.0))

        # The key names are the same, but the symbolic indexing layout belongs
        # to different compiled problems. Reusing the same cached setp closure
        # across those problems would make a fast path incorrect.
        @test ConfigKit._cache_key(prob1, [:α]) != ConfigKit._cache_key(prob2, [:α])

        prob1b = update(prob1, (; α = 5.0); strict=false)
        prob2b = update(prob2, (; α = 7.0); strict=false)

        sol1 = solve(prob1b, Tsit5())
        sol2 = solve(prob2b, Tsit5())
        @test sol1.retcode == ReturnCode.Success
        @test sol2.retcode == ReturnCode.Success
    end


    @testset "UpdateCache parameter workspace" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))
        cache = UpdateCache(prob, (; α = 0.0, β = 0.0); strict=false)

        prob1 = update!(cache, (; α = 4.0, β = 1.5); build_initializeprob=false)
        @test prob1.ps[α] ≈ 4.0
        @test prob1.ps[β] ≈ 1.5
        @test prob.ps[α] ≈ 2.0
        @test prob.ps[β] ≈ 1.0

        prob2 = update!(cache, [6.0, 2.5]; build_initializeprob=false)
        @test prob2.ps[α] ≈ 6.0
        @test prob2.ps[β] ≈ 2.5

        pair_cache = UpdateCache(prob, [α => 0.0, β => 0.0]; strict=false)
        prob3 = update!(pair_cache, [α => 7.0, β => 3.5];
            validate_units=false, convert_units=false, build_initializeprob=false)
        @test prob3.ps[α] ≈ 7.0
        @test prob3.ps[β] ≈ 3.5

        @test_throws ArgumentError update!(cache, (; β = 1.0, α = 2.0))
    end

    # =================================================================
    # TEST 2: update(ODEProblem, pairs) - State Variable Update
    # =================================================================
    @testset "ODEProblem State Variable Update" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))
        x0_key = ModelingToolkitBase.Initial(x)
        y0_key = ModelingToolkitBase.Initial(y)

        # Update initial conditions
        new_prob = update(prob, [x => 10.0, y => 5.0])

        # Verify initial conditions changed (use symbolic indexing, not positional)
        @test new_prob[x] ≈ 10.0
        @test new_prob[y] ≈ 5.0
        @test new_prob.ps[x0_key] ≈ 10.0
        @test new_prob.ps[y0_key] ≈ 5.0

        # Updating initials must not mutate the source problem's MTKParameters.
        @test prob[x] ≈ 1.0
        @test prob[y] ≈ 0.0
        @test prob.ps[x0_key] ≈ 1.0
        @test prob.ps[y0_key] ≈ 0.0

        nt_prob = update(prob, (; x = 7.0); strict=false)
        @test nt_prob[x] ≈ 7.0
        @test nt_prob.ps[x0_key] ≈ 7.0
        @test prob[x] ≈ 1.0
        @test prob.ps[x0_key] ≈ 1.0
    end

    @testset "State update writes solver initial condition" begin
        @independent_variables t
        @parameters k=0.2 dose=0.0 volume=10.0
        @variables concentration(t)=dose / volume
        D = Differential(t)
        @mtkcompile sys = System([D(concentration) ~ -k * concentration], t)
        @mtkcompile sibling_sys = System([D(concentration) ~ -k * concentration], t)
        sibling_concentration = ModelingToolkitBase.parse_variable(sibling_sys, "concentration")

        prob = ODEProblem(sys, Dict(), (0.0, 2.0))
        concentration0 = ModelingToolkitBase.Initial(concentration)

        updated = update(prob, [sibling_concentration => 5.0])
        @test updated[concentration] ≈ 5.0
        @test updated.ps[concentration0] ≈ 5.0

        sol = solve(updated, Tsit5(); saveat=[0.0, 2.0], abstol=1e-10, reltol=1e-10)
        @test sol.retcode == ReturnCode.Success
        @test sol(0.0; idxs=concentration) ≈ 5.0 atol=1e-10
        @test sol(2.0; idxs=concentration) ≈ 5.0 * exp(-0.4) rtol=1e-8
    end


    @testset "UpdateCache state workspace syncs Initial parameters" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))
        x0_key = ModelingToolkitBase.Initial(x)
        y0_key = ModelingToolkitBase.Initial(y)
        cache = UpdateCache(prob, (:x, :y); strict=false)

        prob1 = update!(cache, (; x = 8.0, y = 3.0))
        @test prob1[x] ≈ 8.0
        @test prob1[y] ≈ 3.0
        @test prob1.ps[x0_key] ≈ 8.0
        @test prob1.ps[y0_key] ≈ 3.0
        @test prob[x] ≈ 1.0
        @test prob.ps[x0_key] ≈ 1.0
    end

    @testset "Symbolic initial conditions stay synchronized" begin
        @independent_variables t
        @parameters k a
        @variables x(t)=a
        D = Differential(t)
        @mtkcompile sys = System([D(x) ~ -k * x], t)

        prob = ODEProblem(sys, Dict(k => 0.1, a => 1.0), (0.0, 1.0))
        x0_key = ModelingToolkitBase.Initial(x)

        pair_prob = update(prob, [a => 2.0, k => 0.5]; strict=false)
        @test pair_prob[x] ≈ 2.0
        @test pair_prob.ps[x0_key] ≈ 2.0
        @test pair_prob.ps[a] ≈ 2.0
        @test pair_prob.ps[k] ≈ 0.5
        pair_sol = solve(pair_prob, Tsit5(); saveat=[0.0, 1.0], abstol=1e-10, reltol=1e-10)
        @test pair_sol.retcode == ReturnCode.Success
        @test pair_sol(0.0)[1] ≈ 2.0 atol=1e-10
        @test pair_sol(1.0)[1] ≈ 2.0 * exp(-0.5) rtol=1e-8

        nt_prob = update(prob, (; a = 3.0, k = 0.25); strict=false)
        @test nt_prob[x] ≈ 3.0
        @test nt_prob.ps[x0_key] ≈ 3.0
        @test nt_prob.ps[a] ≈ 3.0
        @test nt_prob.ps[k] ≈ 0.25
        nt_sol = solve(nt_prob, Tsit5(); saveat=[0.0, 1.0], abstol=1e-10, reltol=1e-10)
        @test nt_sol.retcode == ReturnCode.Success
        @test nt_sol(0.0)[1] ≈ 3.0 atol=1e-10
        @test nt_sol(1.0)[1] ≈ 3.0 * exp(-0.25) rtol=1e-8

        @test prob[x] ≈ 1.0
        @test prob.ps[x0_key] ≈ 0.0
        @test prob.ps[a] ≈ 1.0
        orig_sol = solve(prob, Tsit5(); saveat=[0.0, 1.0], abstol=1e-10, reltol=1e-10)
        @test orig_sol.retcode == ReturnCode.Success
        @test orig_sol(0.0)[1] ≈ 1.0 atol=1e-10
        @test orig_sol(1.0)[1] ≈ exp(-0.1) rtol=1e-8

        tasks = map(1:8) do i
            Threads.@spawn begin
                ai = 1.0 + 0.25 * i
                ki = 0.05 + 0.02 * i
                prob_i = update(prob, (; a = ai, k = ki); strict=false)
                sol_i = solve(prob_i, Tsit5(); saveat=[0.0, 0.5], abstol=1e-10, reltol=1e-10)
                (
                    retcode = sol_i.retcode,
                    u0 = sol_i(0.0)[1],
                    uhalf = sol_i(0.5)[1],
                    expected_u0 = ai,
                    expected_uhalf = ai * exp(-ki * 0.5),
                    initial = prob_i.ps[x0_key],
                    a = prob_i.ps[a],
                    k = prob_i.ps[k],
                )
            end
        end
        for result in fetch.(tasks)
            @test result.retcode == ReturnCode.Success
            @test result.u0 ≈ result.expected_u0 atol=1e-10
            @test result.uhalf ≈ result.expected_uhalf rtol=1e-8
            @test result.initial ≈ result.expected_u0
            @test result.a ≈ result.expected_u0
        end
        @test prob[x] ≈ 1.0
        @test prob.ps[x0_key] ≈ 0.0
        @test prob.ps[a] ≈ 1.0
        @test prob.ps[k] ≈ 0.1
    end

    @testset "Nested dependent initial conditions stay synchronized" begin
        @independent_variables t
        @parameters dose scale offset k I0 J0
        @variables Central(t)=I0 Peripheral(t)=J0
        D = Differential(t)
        @named sys = System([
            D(Central) ~ -k * Central,
            D(Peripheral) ~ -k * Peripheral,
        ], t)

        yaml_content = """
        Parameters:
          dose:
            value: 100.0
          scale:
            value: 2.0
          offset:
            value: 5.0
          k:
            value: 0.1
          I0:
            value: dose / scale
          J0:
            value: I0 + offset
        Variables:
          Central:
            initial: I0
          Peripheral:
            initial: J0
        """
        path = tempname() * ".yml"
        write(path, yaml_content)

        try
            sys_pop = populate(sys, load_keyfile(path); strict=false)
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 1.0))
            central = MTK.parse_variable(sys_simp, "Central")
            peripheral = MTK.parse_variable(sys_simp, "Peripheral")
            central0 = ModelingToolkitBase.Initial(central)
            peripheral0 = ModelingToolkitBase.Initial(peripheral)

            pair_prob = update(prob, [:dose => 300.0, :scale => 3.0, :offset => 11.0]; strict=false)
            @test pair_prob[central] ≈ 100.0
            @test pair_prob[peripheral] ≈ 111.0
            @test pair_prob.ps[central0] ≈ 100.0
            @test pair_prob.ps[peripheral0] ≈ 111.0

            nt_prob = update(prob, (; dose = 80.0, scale = 4.0, offset = 2.5); strict=false)
            @test nt_prob[central] ≈ 20.0
            @test nt_prob[peripheral] ≈ 22.5
            @test nt_prob.ps[central0] ≈ 20.0
            @test nt_prob.ps[peripheral0] ≈ 22.5

            cache = UpdateCache(prob, (; dose = 0.0, scale = 0.0, offset = 0.0); strict=false)
            cached_prob = update!(cache, (; dose = 120.0, scale = 6.0, offset = 9.0))
            @test cached_prob[central] ≈ 20.0
            @test cached_prob[peripheral] ≈ 29.0
            @test cached_prob.ps[central0] ≈ 20.0
            @test cached_prob.ps[peripheral0] ≈ 29.0

            @test prob[central] ≈ 50.0
            @test prob[peripheral] ≈ 55.0
        finally
            rm(path, force=true)
        end
    end

    @testset "UpdateCache nested equivalence across repeated threaded updates" begin
        @independent_variables t
        @parameters dose scale offset k I0 J0
        @variables Central(t)=I0 Peripheral(t)=J0
        D = Differential(t)
        @named sys = System([
            D(Central) ~ -k * Central,
            D(Peripheral) ~ -k * Peripheral,
        ], t)

        yaml_content = """
        Parameters:
          dose:
            value: 100.0
          scale:
            value: 2.0
          offset:
            value: 5.0
          k:
            value: 0.1
          I0:
            value: dose / scale
          J0:
            value: I0 + offset
        Variables:
          Central:
            initial: I0
          Peripheral:
            initial: J0
        """
        path = tempname() * ".yml"
        write(path, yaml_content)

        try
            sys_pop = populate(sys, load_keyfile(path); strict=false)
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 1.0))
            central = MTK.parse_variable(sys_simp, "Central")
            peripheral = MTK.parse_variable(sys_simp, "Peripheral")
            central0 = ModelingToolkitBase.Initial(central)
            peripheral0 = ModelingToolkitBase.Initial(peripheral)
            tracked_params = (central0, peripheral0,
                MTK.parse_variable(sys_simp, "dose"),
                MTK.parse_variable(sys_simp, "scale"),
                MTK.parse_variable(sys_simp, "offset"),
                MTK.parse_variable(sys_simp, "k"))

            values_for(i) = (;
                dose = 60.0 + 3.0 * i,
                scale = 1.5 + 0.1 * (i % 5),
                offset = -2.0 + 0.25 * i,
                k = 0.05 + 0.01 * (i % 7),
            )
            snapshot(prob_i) = (prob_i[central], prob_i[peripheral],
                Tuple(prob_i.ps[k] for k in tracked_params)...)

            cache = UpdateCache(prob, values_for(0); strict=false)
            for i in 1:30
                vals = values_for(i)
                ref = update(prob, vals; strict=false)
                got = update!(cache, vals)
                @test all(isapprox.(snapshot(got), snapshot(ref); rtol=1e-10, atol=1e-10))
                @test got[central] ≈ vals.dose / vals.scale
                @test got[peripheral] ≈ vals.dose / vals.scale + vals.offset
                @test got.ps[central0] ≈ got[central]
                @test got.ps[peripheral0] ≈ got[peripheral]
                @test prob[central] ≈ 50.0
                @test prob[peripheral] ≈ 55.0
            end

            tasks = map(1:Threads.nthreads()) do worker
                Threads.@spawn begin
                    local_cache = UpdateCache(prob, values_for(worker); strict=false)
                    ok = true
                    for i in 1:20
                        vals = values_for(100 * worker + i)
                        ref = update(prob, vals; strict=false)
                        got = update!(local_cache, vals)
                        ok &= all(isapprox.(snapshot(got), snapshot(ref); rtol=1e-10, atol=1e-10))
                        ok &= got.ps[central0] ≈ got[central]
                        ok &= got.ps[peripheral0] ≈ got[peripheral]
                    end
                    ok
                end
            end
            @test all(fetch, tasks)

            shared_cache = UpdateCache(prob, values_for(0); strict=false)
            shared_tasks = map(1:Threads.nthreads()) do worker
                Threads.@spawn begin
                    ok = true
                    for i in 1:10
                        vals = values_for(1000 * worker + i)
                        ref = update(prob, vals; strict=false)
                        got_snapshot = with_update_cache(shared_cache, vals) do got
                            ok &= got.ps[central0] ≈ got[central]
                            ok &= got.ps[peripheral0] ≈ got[peripheral]
                            snapshot(got)
                        end
                        ok &= all(isapprox.(got_snapshot, snapshot(ref); rtol=1e-10, atol=1e-10))
                    end
                    ok
                end
            end
            @test all(fetch, shared_tasks)
            @test prob[central] ≈ 50.0
            @test prob[peripheral] ≈ 55.0
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 3: update(ODEProblem, pairs) - Mixed Update
    # =================================================================
    @testset "ODEProblem Mixed Update" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))
        x0_key = ModelingToolkitBase.Initial(x)

        # Update both parameters and state variables
        new_prob = update(prob, [α => 3.0, x => 5.0])

        # State should be updated (use symbolic indexing)
        @test new_prob[x] ≈ 5.0
        @test new_prob.ps[x0_key] ≈ 5.0
        @test prob.ps[α] ≈ 2.0
        @test prob[x] ≈ 1.0
        @test prob.ps[x0_key] ≈ 1.0

        # Should solve successfully
        sol = solve(new_prob, Tsit5())
        @test sol.retcode == ReturnCode.Success
    end

    # =================================================================
    # TEST 4: update(System, pairs)
    # =================================================================
    @testset "System Update" begin
        # Use the shared test system (completed via mtkcompile workflow)
        sys, α, β, γ, x, y = create_test_system()

        # Update system-level values
        new_sys = update(sys, [α => 10.0])

        # Should return a completed system
        @test new_sys isa MTK.AbstractSystem

        # Create problem from updated system and solve
        prob = ODEProblem(new_sys, [x => 1.0, y => 0.0], (0.0, 5.0))
        sol = solve(prob, Tsit5())
        @test sol.retcode == ReturnCode.Success
    end

    # =================================================================
    # TEST 5: update(Integrator, pairs)
    # =================================================================
    @testset "Integrator Update" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))

        integrator = init(prob, Tsit5())

        # Update parameter mid-integration
        update(integrator, [α => 5.0])

        # Should not throw - test passes if we get here
        @test true

        # Step and verify it works
        step!(integrator)
        @test integrator.t > 0.0
    end

    # =================================================================
    # TEST 6: Integrator State Update
    # =================================================================
    @testset "Integrator State Update" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))

        integrator = init(prob, Tsit5())

        # Update state variables
        update(integrator, [x => 10.0, y => 5.0])

        # Use symbolic indexing (state order may differ from positional)
        @test integrator[x] ≈ 10.0
        @test integrator[y] ≈ 5.0
    end

    # =================================================================
    # TEST 7: BindingUpdateError for Bound Parameters
    # =================================================================
    @testset "BindingUpdateError" begin
        # Create a system with a binding via populate
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
        path = tempname() * ".yml"
        write(path, yaml_content)

        try
            keyfile = load_keyfile(path)
            sys_pop = populate(sys, keyfile; strict=false)
            sys_simp = mtkcompile(sys_pop)
            prob = ODEProblem(sys_simp, [], (0.0, 10.0))

            # Attempting to update k_el (a binding) should throw BindingUpdateError
            # when strict=true (default)
            @test_throws ConfigKit.BindingUpdateError update(prob, [k_el => 0.5])

            # With strict=false, should not throw (silently skip)
            new_prob = update(prob, [k_el => 0.5]; strict=false)
            @test new_prob isa SciMLBase.ODEProblem
        finally
            rm(path, force=true)
        end
    end

    # =================================================================
    # TEST 8: Ghost Parameters (Structural Simplify removes them)
    # =================================================================
    @testset "Ghost Parameters Skipped" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))

        # Try to update a parameter that doesn't exist
        # This should be silently skipped (ghost parameter behavior)
        @parameters ghost_param

        # Should not throw - ghost parameters are silently ignored
        new_prob = update(prob, [ghost_param => 999.0])
        @test new_prob isa SciMLBase.ODEProblem
    end

    # =================================================================
    # TEST 9: String Key Resolution
    # =================================================================
    @testset "String Key Resolution" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))

        # Update using string keys
        new_prob = update(prob, ["α" => 5.0])

        # Should work and produce different results
        sol_orig = solve(prob, Tsit5())
        sol_new = solve(new_prob, Tsit5())

        @test sol_orig[x][end] != sol_new[x][end]
    end

    # =================================================================
    # TEST 10: Symbol Key Resolution
    # =================================================================
    @testset "Symbol Key Resolution" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))

        # Update using symbol keys
        new_prob = update(prob, [:α => 5.0])

        # Should work and produce different results
        sol_orig = solve(prob, Tsit5())
        sol_new = solve(new_prob, Tsit5())

        @test sol_orig[x][end] != sol_new[x][end]
    end

    # =================================================================
    # TEST 11: Integrator Callback Integration
    # =================================================================
    @testset "Integrator Callback" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 5.0))

        # Define callback that uses ConfigKit.update
        condition(_u, t, _integrator) = t - 1.0
        function affect!(integrator)
            update(integrator, [α => 10.0])
        end

        cb = ContinuousCallback(condition, affect!)
        sol = solve(prob, Tsit5(), callback=cb)

        @test sol.retcode == ReturnCode.Success
        @test length(sol.t) > 1
    end

    # =================================================================
    # TEST 12: Multiple Parameter Updates
    # =================================================================
    @testset "Multiple Parameters" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))

        # Update multiple parameters at once
        new_prob = update(prob, [α => 1.0, β => 2.0, γ => 4.0])

        sol = solve(new_prob, Tsit5())
        @test sol.retcode == ReturnCode.Success
    end

    # =================================================================
    # TEST 13: BindingUpdateError Message
    # =================================================================
    @testset "BindingUpdateError Message" begin
        err = ConfigKit.BindingUpdateError(:k_el, :(CL / V))

        # Test showerror
        io = IOBuffer()
        showerror(io, err)
        msg = String(take!(io))

        @test occursin("k_el", msg)
        @test occursin("bound parameter", msg)
        @test occursin("CL / V", msg)
    end

    # =================================================================
    # TEST 14-19: Unit Handling Design Matrix
    # =================================================================
    # Tests all scenarios from the design matrix:
    # validate_units | convert_units | Behavior
    # true (default) | true (default) | Validate units and convert to system units (safest)
    # true          | false          | Validate units but require exact match (validate only)
    # false         | false          | Strip units without validation (fastest)
    # false         | true           | NOT ALLOWED (unsafe combination)

    @testset "Unit Handling - Model Without Unit Metadata" begin
        sys, α, β, γ, x, y = create_test_system()
        prob = ODEProblem(sys, [x => 1.0, y => 0.0], (0.0, 10.0))

        @testset "Default Behavior (true, true) - No Metadata" begin
            # Model has no unit metadata, so unitful values should be stripped (lenient)
            new_prob = update(prob, [α => 2.0u"s"])
            sol = solve(new_prob, Tsit5())
            @test sol.retcode == ReturnCode.Success

            # Unitless values should work fine
            new_prob2 = update(prob, [α => 3.0, β => 4.0])
            @test new_prob2 isa SciMLBase.ODEProblem
        end

        @testset "Validate Only (true, false) - No Metadata" begin
            # With no metadata, unitful values are stripped
            new_prob = update(prob, [α => 2.0u"hr^-1"], validate_units=true, convert_units=false)
            @test new_prob isa SciMLBase.ODEProblem

            # Unitless values should work
            new_prob2 = update(prob, [α => 2.0, γ => 5.0], validate_units=true, convert_units=false)
            @test new_prob2 isa SciMLBase.ODEProblem
        end

        @testset "No Validation (false, false) - Fastest" begin
            # This should always work - strips units without any validation
            new_prob1 = update(prob, [α => 2.0u"hr^-1", γ => 5.0], validate_units=false, convert_units=false)
            @test new_prob1 isa SciMLBase.ODEProblem

            # Test with incompatible units (should still work - no validation)
            new_prob2 = update(prob, [α => 3.0u"kg", γ => 7.0u"m"], validate_units=false, convert_units=false)
            @test new_prob2 isa SciMLBase.ODEProblem

            # Test with no units (should work)
            new_prob3 = update(prob, [α => 4.0, γ => 8.0], validate_units=false, convert_units=false)
            @test new_prob3 isa SciMLBase.ODEProblem
        end

        @testset "Disallowed Combination (false, true)" begin
            # This combination is not allowed for safety
            @test_throws ArgumentError update(prob, [α => 2.0u"hr^-1"], validate_units=false, convert_units=true)

            # Test error message is informative
            try
                update(prob, [α => 2.0u"hr^-1"], validate_units=false, convert_units=true)
                @test false  # Should not reach here
            catch e
                @test isa(e, ArgumentError)
                @test occursin("not allowed for safety", string(e))
            end
        end

        @testset "Empty Updates" begin
            # Test empty updates with different unit settings
            @test_nowarn update(prob, [], validate_units=true, convert_units=true)
            @test_nowarn update(prob, [], validate_units=true, convert_units=false)
            @test_nowarn update(prob, [], validate_units=false, convert_units=false)
            @test_nowarn update(prob, [])  # Default
        end
    end

    @testset "Unit Handling - Model With Unit Metadata" begin
        # Create a system with unit metadata on parameters
        @independent_variables t_u [unit = u"s"]
        @parameters α_u [unit = u"s^-1"] γ_u [unit = u"mg"]
        @variables x_u(t_u) [unit = u"mg"]
        D_u = Differential(t_u)

        eqs_u = [D_u(x_u) ~ -α_u * x_u + γ_u]
        @named sys_u = System(eqs_u, t_u)
        csys_u = mtkcompile(sys_u)

        prob_u = ODEProblem(csys_u, [csys_u.x_u => 1.0], (0.0, 10.0), [csys_u.α_u => 0.1, csys_u.γ_u => 0.5])

        @testset "Default Behavior - Compatible Units" begin
            # Update with compatible units - should validate and convert
            new_prob = update(prob_u, [csys_u.α_u => 0.2u"s^-1", csys_u.γ_u => 1.0u"mg"])
            @test new_prob.ps[csys_u.α_u] ≈ 0.2
            @test new_prob.ps[csys_u.γ_u] ≈ 1.0
        end

        @testset "Unit Conversion" begin
            # Test unit conversion (hr^-1 to s^-1)
            # 1 hr^-1 = 1/3600 s^-1
            new_prob = update(prob_u, [csys_u.α_u => 1.0u"hr^-1"])
            @test new_prob.ps[csys_u.α_u] ≈ 1.0/3600.0 rtol=1e-10

            # Test reverse: provide s^-1 when model uses s^-1 (no conversion needed)
            new_prob2 = update(prob_u, [csys_u.α_u => 0.5u"s^-1"])
            @test new_prob2.ps[csys_u.α_u] ≈ 0.5
        end

        @testset "Dimension Mismatch Error" begin
            # Try to update with incompatible dimensions (mass vs time^-1)
            @test_throws ArgumentError update(prob_u, [csys_u.α_u => 2.0u"mg"])

            # Try to update with incompatible dimensions (length vs time^-1)
            @test_throws ArgumentError update(prob_u, [csys_u.α_u => 2.0u"m"])
        end

        @testset "Unitless Value to Unit Model Error" begin
            # Model expects units but got unitless value - should error with validate_units=true
            @test_throws ArgumentError update(prob_u, [csys_u.α_u => 0.2])
        end

        @testset "Validate Only Mode (true, false)" begin
            # With exact matching units - should work
            new_prob = update(prob_u, [csys_u.α_u => 0.2u"s^-1"], validate_units=true, convert_units=false)
            @test new_prob.ps[csys_u.α_u] ≈ 0.2

            # With convertible but non-matching units - should error (no conversion)
            @test_throws ArgumentError update(prob_u, [csys_u.α_u => 3600.0u"hr^-1"], validate_units=true, convert_units=false)
        end

        @testset "No Validation Mode (false, false)" begin
            # Even with unit mismatch, should work (units just stripped)
            new_prob = update(prob_u, [csys_u.α_u => 0.3u"kg"], validate_units=false, convert_units=false)
            @test new_prob.ps[csys_u.α_u] ≈ 0.3

            # Unitless values should work
            new_prob2 = update(prob_u, [csys_u.α_u => 0.4], validate_units=false, convert_units=false)
            @test new_prob2.ps[csys_u.α_u] ≈ 0.4
        end
    end

end
