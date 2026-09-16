using Test
using ConfigKit

@testset "Bulk Accessor Functions" begin
    # Create a self-contained test keyfile with bounds
    keyfile_path = joinpath(mktempdir(), "test_bulk_accessors.yml")
    write(keyfile_path, """
    Parameters:
      CL:
        value: 5.0
        unit: "L/hr"
        desc: "Systemic clearance"
        bounds: [0.1, 100.0]
      V1:
        value: 50.0
        unit: L
        desc: "Central volume"
        bounds: [1.0, 500.0]
      Q:
        value: 10.0
        unit: "L/hr"
        desc: "Intercompartmental clearance"
      V2:
        value: 100.0
        unit: L
        desc: "Peripheral volume"
        bounds: [10.0, 1000.0]
      k_el:
        value: "CL / V1"
        desc: "Elimination rate constant"
        unit: "hr^-1"
    Variables:
      Central:
        initial: 0.0
        unit: mg
    Constants:
      MW:
        value: 450.0
        unit: "g/mol"
    """)

    kf = load_keyfile(keyfile_path)

    @testset "get_values" begin
        # Basic extraction
        vals = get_values(kf, [:CL, :V1])
        @test vals == [5.0, 50.0]
        @test vals isa Vector{Float64}

        # Order preserved
        vals2 = get_values(kf, [:V1, :CL])
        @test vals2 == [50.0, 5.0]

        # Single parameter
        vals3 = get_values(kf, [:Q])
        @test vals3 == [10.0]

        # Empty list
        vals4 = get_values(kf, Symbol[])
        @test vals4 == Float64[]

        # Missing parameter throws
        @test_throws Exception get_values(kf, [:NonExistent])
    end

    @testset "get_bounds" begin
        # Basic extraction
        bounds = get_bounds(kf, [:CL, :V1])
        @test bounds.lb == [0.1, 1.0]
        @test bounds.ub == [100.0, 500.0]
        @test bounds.lb isa Vector{Float64}
        @test bounds.ub isa Vector{Float64}

        # Order preserved
        bounds2 = get_bounds(kf, [:V2, :CL])
        @test bounds2.lb == [10.0, 0.1]
        @test bounds2.ub == [1000.0, 100.0]

        # Single parameter
        bounds3 = get_bounds(kf, [:CL])
        @test bounds3.lb == [0.1]
        @test bounds3.ub == [100.0]

        # Empty list
        bounds4 = get_bounds(kf, Symbol[])
        @test bounds4.lb == Float64[]
        @test bounds4.ub == Float64[]

        # Parameter without bounds throws
        @test_throws ErrorException get_bounds(kf, [:Q])

        # Missing parameter throws
        @test_throws Exception get_bounds(kf, [:NonExistent])
    end

    @testset "get_all_values" begin
        all_vals = get_all_values(kf)
        @test all_vals isa Dict{Symbol, Float64}

        # Numeric parameters included
        @test all_vals[:CL] == 5.0
        @test all_vals[:V1] == 50.0
        @test all_vals[:Q] == 10.0
        @test all_vals[:V2] == 100.0

        # Expression-valued parameter excluded
        @test !haskey(all_vals, :k_el)

        # Variables and constants not included (Parameters only)
        @test !haskey(all_vals, :Central)
        @test !haskey(all_vals, :MW)
    end
end
