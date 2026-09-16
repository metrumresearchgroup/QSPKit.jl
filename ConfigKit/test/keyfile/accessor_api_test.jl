using Test
using ConfigKit
import DynamicQuantities as DQ

@testset "Keyfile Accessor API" begin
    # Create temporary keyfile for testing to ensure self-contained tests
    keyfile_path = joinpath(mktempdir(), "test_accessor.yml")
    write(keyfile_path, """
    Parameters:
      CL:
        abbr: CL
        description: "Systemic clearance"
        unit: "L/hr"
        variants:
          human: {value: 50.0}
          mouse: {value: 0.005}
      V1:
        abbr: V1
        variants:
          human: {value: 700.0}
          mouse: {value: 0.02}
      k_el:
        abbr: k_el
        value: "CL / V1"
        description: "Elimination rate constant"
        unit: "hr^-1"
    Variables:
      C_central:
        abbr: C
        unit: "mg/L"
        initial: 10.0
    Constants:
      MW:
        abbr: MW
        value: 100.0
    """)

    @testset "Basic Loading and Structure" begin
        keyfile = load_keyfile(keyfile_path, variant="human")
        @test keyfile isa ConfigKit.KeyfileAccessor

        @test keyfile.Parameters isa ConfigKit.ParametersView
        @test keyfile.Variables isa ConfigKit.ParametersView
        @test keyfile.Constants isa ConfigKit.ParametersView
    end

    @testset "Parameter Access" begin
        keyfile = load_keyfile(keyfile_path, variant="human")
        params = keyfile.Parameters

        CL = params.CL
        @test CL isa ConfigKit.ParameterEntry
        @test CL.value == 50.0

        # Units are DynamicQuantities
        @test CL.unit isa DQ.AbstractQuantity

        # Description is in metadata
        @test get(CL.metadata, :description, "") == "Systemic clearance"
    end

    @testset "Direct Value Access" begin
        keyfile = load_keyfile(keyfile_path, variant="human")
        @test keyfile.Parameters.CL.value == 50.0
        @test keyfile.Parameters.V1.value == 700.0
    end

    @testset "Variable Access" begin
        keyfile = load_keyfile(keyfile_path, variant="human")
        vars = keyfile.Variables

        C_central = vars.C_central
        @test C_central isa ConfigKit.ParameterEntry
        @test C_central.value == 10.0
        @test C_central.unit isa DQ.AbstractQuantity
    end

    @testset "Constants Access" begin
        keyfile = load_keyfile(keyfile_path, variant="human")
        consts = keyfile.Constants

        MW = consts.MW
        @test MW isa ConfigKit.ParameterEntry
        @test MW.value == 100.0
    end

    @testset "Expression Parameters" begin
        keyfile = load_keyfile(keyfile_path, variant="human")
        # Expression-valued parameters store the expression in metadata
        k_el = keyfile.Parameters.k_el
        @test haskey(k_el.metadata, :expression)
        @test k_el.metadata[:expression] == "CL / V1"
        @test k_el.unit isa DQ.AbstractQuantity
    end

    @testset "Variant Support" begin
        keyfile_human = load_keyfile(keyfile_path, variant="human")
        keyfile_mouse = load_keyfile(keyfile_path, variant="mouse")

        @test keyfile_human.Parameters.CL.value == 50.0
        @test keyfile_mouse.Parameters.CL.value == 0.005
    end

    @testset "Error Handling" begin
        keyfile = load_keyfile(keyfile_path, variant="human")

        # Missing parameter should throw
        @test_throws Exception keyfile.Parameters.NonExistent
    end

    @testset "Internal Structure Access" begin
        keyfile = load_keyfile(keyfile_path, variant="human")
        @test haskey(keyfile.parameter_defaults, :CL)
        @test keyfile.parameter_defaults[:CL] == 50.0
    end

    @testset "ParametersView Dictionary Interface" begin
        keyfile = load_keyfile(keyfile_path, variant="human")
        params = keyfile.Parameters

        # Bracket access with Symbol
        @test params[:CL] isa ConfigKit.ParameterEntry
        @test params[:CL].value == 50.0

        # Bracket access with String
        @test params["CL"] isa ConfigKit.ParameterEntry
        @test params["CL"].value == 50.0

        # length
        @test length(params) == 3  # CL, V1, k_el

        # keys
        k = keys(params)
        @test :CL in k
        @test :V1 in k
        @test :k_el in k

        # values
        v = values(params)
        @test length(collect(v)) == 3

        # haskey
        @test haskey(params, :CL) == true
        @test haskey(params, :NonExistent) == false

        # propertynames
        pn = propertynames(params)
        @test :CL in pn
        @test :V1 in pn

        # iterate
        count = 0
        for (name, entry) in params
            count += 1
            @test entry isa ConfigKit.ParameterEntry
        end
        @test count == 3
    end

    @testset "KeyfileAccessor variable_initials" begin
        keyfile = load_keyfile(keyfile_path, variant="human")

        # Test variable_initials computed property
        vi = keyfile.variable_initials
        @test haskey(vi, :C_central)
        @test vi[:C_central] == 10.0
    end

    @testset "ParameterEntry show method" begin
        keyfile = load_keyfile(keyfile_path, variant="human")
        CL = keyfile.Parameters.CL

        # Test that show doesn't throw
        io = IOBuffer()
        @test_nowarn show(io, CL)
        output = String(take!(io))
        @test contains(output, "CL")
    end

    @testset "ParametersView show method" begin
        keyfile = load_keyfile(keyfile_path, variant="human")
        params = keyfile.Parameters

        io = IOBuffer()
        @test_nowarn show(io, params)
        output = String(take!(io))
        @test contains(output, "ParametersView")
        @test contains(output, "3")  # 3 entries
    end

    @testset "KeyfileAccessor show method" begin
        keyfile = load_keyfile(keyfile_path, variant="human")

        io = IOBuffer()
        @test_nowarn show(io, keyfile)
        output = String(take!(io))
        @test contains(output, "KeyfileAccessor")
        @test contains(output, "Parameters")
    end
end
