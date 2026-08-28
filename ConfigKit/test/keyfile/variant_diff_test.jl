using Test
using ConfigKit
using OrderedCollections
using YAML

@testset "get_variant_diff() Tests" begin

    # Create a test keyfile on the fly
    TEST_KEYFILE_CONTENT = """
    Parameters:
      rate:
        value: 5.0
        variants:
          reference: {value: 5.0}
          alternative: {value: 2.5}
      volume:
        value: 50.0
        variants:
          reference: {value: 50.0}
          alternative: {value: 50.0}
      gain:
        value: 0.1
        variants:
          reference: {value: 0.08}
          alternative: {value: 0.15}
    Variables:
      response_state:
        initial: 0.0
        variants:
          reference: {initial: 0.0}
          alternative: {initial: 100.0}
    """

    mktempdir() do tmpdir
        keyfile_path = joinpath(tmpdir, "diff_test.yml")
        write(keyfile_path, TEST_KEYFILE_CONTENT)

        @testset "Comparison modes" begin
            # Variant vs Variant
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:reference, variant_b=:alternative)

            # gain differs
            @test haskey(result, :gain)
            entry = result[:gain]
            @test entry.value_a == 0.08
            @test entry.value_b == 0.15
            @test entry.difference ≈ 0.07 atol=1e-10

            # rate differs
            @test haskey(result, :rate)

            # volume is the same, so it is excluded by default (only_different=true)
            @test !haskey(result, :volume)
        end

        @testset "Filtering (only_different=false)" begin
            result = ConfigKit.get_variant_diff(keyfile_path;
                variant_a=:reference, variant_b=:alternative, only_different=false)

            # volume should now be included
            @test haskey(result, :volume)
            @test result[:volume].value_a == 50.0
        end

        @testset "Variables category" begin
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:reference, variant_b=:alternative)
            @test haskey(result, :response_state)
            @test result[:response_state].category == :Variables
        end

        @testset "VariantDiffResult iteration interface" begin
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:reference, variant_b=:alternative)

            # length
            @test length(result) >= 3  # At least rate, gain, response_state

            # iterate
            count = 0
            for entry in result
                count += 1
                @test entry isa ConfigKit.VariantDiffEntry
            end
            @test count == length(result)
        end

        @testset "VariantDiffResult indexing" begin
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:reference, variant_b=:alternative)

            # Bracket access
            entry = result[:rate]
            @test entry isa ConfigKit.VariantDiffEntry
            @test entry.name == :rate

            # KeyError for missing
            @test_throws KeyError result[:NonExistent]
        end

        @testset "VariantDiffEntry show method" begin
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:reference, variant_b=:alternative)
            entry = result[:rate]

            io = IOBuffer()
            @test_nowarn show(io, entry)
            output = String(take!(io))
            @test contains(output, "rate")
            @test contains(output, "→")  # Arrow between values
        end

        @testset "VariantDiffResult show method" begin
            result = ConfigKit.get_variant_diff(keyfile_path; variant_a=:reference, variant_b=:alternative)

            io = IOBuffer()
            @test_nowarn show(io, result)
            output = String(take!(io))
            @test contains(output, "VariantDiffResult")
            @test contains(output, "reference")
            @test contains(output, "alternative")
        end
    end
end
