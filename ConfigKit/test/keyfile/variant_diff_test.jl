using Test
using ConfigKit
using OrderedCollections
using YAML

@testset "get_variant_diff() Tests" begin

    # Create a test keyfile on the fly
    TEST_KEYFILE_CONTENT = """
    Parameters:
      CL:
        value: 5.0
        variants:
          healthy: {value: 5.0}
          disease: {value: 2.5}
      V:
        value: 50.0
        variants:
          healthy: {value: 50.0}
          disease: {value: 50.0}
      k_growth:
        value: 0.1
        variants:
          healthy: {value: 0.08}
          disease: {value: 0.15}
    Variables:
      tumor_burden:
        initial: 0.0
        variants:
          healthy: {initial: 0.0}
          disease: {initial: 100.0}
    """
    
    mktempdir() do tmpdir
        keyfile_path = joinpath(tmpdir, "diff_test.yml")
        write(keyfile_path, TEST_KEYFILE_CONTENT)

        @testset "Comparison modes" begin
            # Variant vs Variant
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:healthy, variant_b=:disease)
            
            # k_growth differs
            @test haskey(result, :k_growth)
            entry = result[:k_growth]
            @test entry.value_a == 0.08
            @test entry.value_b == 0.15
            @test entry.difference ≈ 0.07 atol=1e-10
            
            # CL differs
            @test haskey(result, :CL)
            
            # V is same, should be excluded by default (only_different=true)
            @test !haskey(result, :V)
        end

        @testset "Filtering (only_different=false)" begin
            result = ConfigKit.get_variant_diff(keyfile_path; 
                variant_a=:healthy, variant_b=:disease, only_different=false)
            
            # V should now be included
            @test haskey(result, :V)
            @test result[:V].value_a == 50.0
        end

        @testset "Variables category" begin
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:healthy, variant_b=:disease)
            @test haskey(result, :tumor_burden)
            @test result[:tumor_burden].category == :Variables
        end

        @testset "VariantDiffResult iteration interface" begin
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:healthy, variant_b=:disease)

            # length
            @test length(result) >= 3  # At least CL, k_growth, tumor_burden

            # iterate
            count = 0
            for entry in result
                count += 1
                @test entry isa ConfigKit.VariantDiffEntry
            end
            @test count == length(result)
        end

        @testset "VariantDiffResult indexing" begin
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:healthy, variant_b=:disease)

            # Bracket access
            entry = result[:CL]
            @test entry isa ConfigKit.VariantDiffEntry
            @test entry.name == :CL

            # KeyError for missing
            @test_throws KeyError result[:NonExistent]
        end

        @testset "VariantDiffEntry show method" begin
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:healthy, variant_b=:disease)
            entry = result[:CL]

            io = IOBuffer()
            @test_nowarn show(io, entry)
            output = String(take!(io))
            @test contains(output, "CL")
            @test contains(output, "→")  # Arrow between values
        end

        @testset "VariantDiffResult show method" begin
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:healthy, variant_b=:disease)

            io = IOBuffer()
            @test_nowarn show(io, result)
            output = String(take!(io))
            @test contains(output, "VariantDiffResult")
            @test contains(output, "healthy")
            @test contains(output, "disease")
        end
    end
end
