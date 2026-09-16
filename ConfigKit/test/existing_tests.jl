using Test
using ConfigKit
import DynamicQuantities as DQ

# FIXTURES_DIR is defined relative to this file's location
const TEST_DIR = @__DIR__
const FIXTURES_DIR = joinpath(TEST_DIR, "fixtures")

@testset "Original ConfigKit Fixture Tests" begin

    @testset "Keyfile Loading" begin
        @testset "Basic Parameters" begin
            keyfile = load_keyfile(joinpath(FIXTURES_DIR, "basic_params.yml"))

            # Test parameter access
            @test keyfile.Parameters.CL.value == 5.0
            @test keyfile.Parameters.V1.value == 50.0
            @test keyfile.Parameters.Q.value == 10.0

            # Test units (DynamicQuantities)
            @test keyfile.Parameters.CL.unit isa DQ.AbstractQuantity
            @test keyfile.Parameters.V1.unit isa DQ.AbstractQuantity

            # Test descriptions (via metadata)
            @test get(keyfile.Parameters.CL.metadata, :description, "") == "Systemic clearance"

            # Test simple format
            @test keyfile.Parameters.ka.value == 1.5

            # Test Variables
            @test keyfile.Variables.Central.value == 0.0
            @test keyfile.Variables.Central.unit isa DQ.AbstractQuantity
        end

        @testset "Variants" begin
            # Test default variant
            keyfile_default = load_keyfile(joinpath(FIXTURES_DIR, "variants.yml"), variant="default")
            @test keyfile_default.Parameters.CL.value == 5.0
            @test keyfile_default.Parameters.V1.value == 50.0

            # Test human variant
            keyfile_human = load_keyfile(joinpath(FIXTURES_DIR, "variants.yml"), variant="human")
            @test keyfile_human.Parameters.CL.value == 5.0

            # Test mouse variant
            keyfile_mouse = load_keyfile(joinpath(FIXTURES_DIR, "variants.yml"), variant="mouse")
            @test keyfile_mouse.Parameters.CL.value == 50.0
            @test keyfile_mouse.Parameters.V1.value == 0.025

            # Test fallback to value when no variant specified
            @test keyfile_mouse.Parameters.Q.value == 10.0

            # Test variable with variant
            keyfile_bolus = load_keyfile(joinpath(FIXTURES_DIR, "variants.yml"), variant="bolus")
            @test keyfile_bolus.Variables.Central.value == 100.0
        end

        @testset "Dependencies" begin
            keyfile = load_keyfile(joinpath(FIXTURES_DIR, "dependencies.yml"))

            # Test base parameters
            @test keyfile.Parameters.CL.value == 10.0
            @test keyfile.Parameters.V.value == 100.0

            # Test expression-valued parameters are marked as expressions in metadata
            @test haskey(keyfile.Parameters.k_el.metadata, :expression)
            @test keyfile.Parameters.k_el.metadata[:expression] == "CL / V"
        end
    end

    @testset "Variant Utilities" begin
        @testset "get_variant_diff" begin
            keyfile_path = joinpath(FIXTURES_DIR, "variants.yml")
            diff = get_variant_diff(:mouse, :human; keyfile=keyfile_path)
            @test length(diff) > 0
            for entry in diff
                @test hasproperty(entry, :name)
                @test hasproperty(entry, :value_a)
                @test hasproperty(entry, :value_b)
            end
        end

        @testset "list_available_variants" begin
            keyfile_path = joinpath(FIXTURES_DIR, "variants.yml")
            variants = list_available_variants(keyfile_path)
            @test :default in variants
            @test :human in variants
            @test :mouse in variants
        end
    end

end
