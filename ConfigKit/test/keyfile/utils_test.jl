using Test
using ConfigKit
using OrderedCollections
import DynamicQuantities as DQ

@testset "Helper Utilities" begin
    @testset "load_yaml_ordered" begin
        # Create a temporary YAML file with ordered keys
        mktempdir() do tmpdir
            yaml_path = joinpath(tmpdir, "test_ordered.yml")
            write(yaml_path, """
            Parameters:
              first: 1
              second: 2
              third: 3
            """)

            result = ConfigKit.load_yaml_ordered(yaml_path)
            @test result isa OrderedDict
            @test haskey(result, "Parameters")

            # Keys should maintain insertion order
            params = result["Parameters"]
            @test params isa OrderedDict
            param_keys = collect(keys(params))
            @test param_keys[1] == "first"
            @test param_keys[2] == "second"
            @test param_keys[3] == "third"
        end
    end

    @testset "getMTKUnit parsing" begin
        # Test that getMTKUnit returns DynamicQuantities
        unit = ConfigKit.getMTKUnit("L/hr")
        @test unit isa DQ.AbstractQuantity

        # Test dimensionless
        unit_dimless = ConfigKit.getMTKUnit("")
        @test unit_dimless isa DQ.AbstractQuantity

        # Test "1" as dimensionless
        unit_one = ConfigKit.getMTKUnit("1")
        @test unit_one isa DQ.AbstractQuantity

        # Test "nothing" as dimensionless
        unit_nothing = ConfigKit.getMTKUnit("nothing")
        @test unit_nothing isa DQ.AbstractQuantity

        # Test with prefixes (milli, kilo, etc.)
        unit_ml = ConfigKit.getMTKUnit("mL")
        @test unit_ml isa DQ.AbstractQuantity

        unit_kg = ConfigKit.getMTKUnit("kg")
        @test unit_kg isa DQ.AbstractQuantity

        # Test complex units
        unit_complex = ConfigKit.getMTKUnit("mg/L/hr")
        @test unit_complex isa DQ.AbstractQuantity

        # Test whitespace handling
        unit_whitespace = ConfigKit.getMTKUnit("  L/hr  ")
        @test unit_whitespace isa DQ.AbstractQuantity

        # Test error on invalid unit
        @test_throws Exception ConfigKit.getMTKUnit("invalid_unit_xyz")
    end
end
