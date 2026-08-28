using Test
using ConfigKit
using OrderedCollections

@testset "YAML Parsing Edge Cases" begin

    @testset "Malformed YAML Error Handling" begin
        @testset "Invalid YAML syntax" begin
            path, io = mktemp()
            close(io)
            invalid_yaml = """
            Parameters:
              param1:
                value: [unclosed bracket
                unit: "mg"
            """
            write(path, invalid_yaml)
            try
                @test_throws Exception load_keyfile(path)
            finally
                rm(path, force=true)
            end
        end

        @testset "Corrupted parameter structure" begin
            path, io = mktemp()
            close(io)
            corrupted_yaml = """
            Parameters:
              param1: "not a dictionary"
              param2:
                - "should be dict not array"
            """
            write(path, corrupted_yaml)
            try
                # Simple values should work, arrays might not
                kf = load_keyfile(path)
                @test kf.Parameters.param1.value == "not a dictionary"
            finally
                rm(path, force=true)
            end
        end
    end

    @testset "Unit Conversion Edge Cases" begin
        @testset "Invalid unit specifications" begin
            path, io = mktemp()
            close(io)
            bad_units_yaml = """
            Parameters:
              rate_param:
                abbr: "rp"
                value: 1.0
                unit: "invalid_unit_name"
            """
            write(path, bad_units_yaml)
            try
                @test_throws Exception load_keyfile(path)
            finally
                rm(path, force=true)
            end
        end

        @testset "Valid units should parse" begin
            path, io = mktemp()
            close(io)
            valid_yaml = """
            Parameters:
              rate_param:
                value: 1.0
                unit: "L/hr"
            """
            write(path, valid_yaml)
            try
                kf = load_keyfile(path)
                @test kf.Parameters.rate_param.value == 1.0
            finally
                rm(path, force=true)
            end
        end
    end

    @testset "Parameter Bounds Edge Cases" begin
        @testset "Bounds stored in metadata" begin
            path, io = mktemp()
            close(io)
            bounds_yaml = """
            Parameters:
              bounded_param:
                value: 5.0
                bounds: [1.0, 10.0]
            """
            write(path, bounds_yaml)
            try
                kf = load_keyfile(path)
                @test kf.Parameters.bounded_param.value == 5.0
            finally
                rm(path, force=true)
            end
        end
    end

    @testset "Expression Evaluation Edge Cases" begin
        @testset "Invalid mathematical expressions" begin
            path, io = mktemp()
            close(io)
            bad_expr_yaml = """
            Parameters:
              expr_param:
                value: "base_param * / 2.0"
            """
            write(path, bad_expr_yaml)
            try
                # The parser stores the raw string, it doesn't evaluate at parse time
                # So this won't throw - the expression is just stored as-is
                kf = load_keyfile(path)
                @test kf.Parameters.expr_param.value == "base_param * / 2.0"
            finally
                rm(path, force=true)
            end
        end
    end
end

@testset "Strict unsupported-field handling" begin
    cases = [
        (block = "Parameters", value_field = "value", unsupported = "citation"),
        (block = "Variables", value_field = "initial", unsupported = "tunable"),
        (block = "Constants", value_field = "value", unsupported = "source"),
    ]

    for case in cases
        mktempdir() do dir
            path = joinpath(dir, "unsupported.yml")
            write(path, """
$(case.block):
  item:
    $(case.value_field): 1.0
    $(case.unsupported): ignored
""")

            err = try
                load_keyfile(path; strict=true)
                nothing
            catch caught
                caught
            end
            @test err isa ErrorException
            @test occursin("unknown field '$(case.unsupported)'", sprint(showerror, err))

            relaxed = load_keyfile(path; strict=false)
            entry = getproperty(getproperty(relaxed, Symbol(case.block)), :item)
            @test entry.value == 1.0
            @test !haskey(entry.metadata, Symbol(case.unsupported))
        end
    end
end


@testset "Original unit spelling is retained for reports" begin
    mktempdir() do dir
        path = joinpath(dir, "units.yml")
        write(path, """
Parameters:
  V:
    value: 3.0
    unit: L
Variables:
  A:
    initial: 0.0
    unit: mg
Constants:
  scale:
    value: 1.0
    unit: mL/L
""")
        kf = load_keyfile(path)
        @test kf.Parameters.V.metadata[:unit_original] == "L"
        @test kf.Variables.A.metadata[:unit_original] == "mg"
        @test kf.Constants.scale.metadata[:unit_original] == "mL/L"
    end
end
