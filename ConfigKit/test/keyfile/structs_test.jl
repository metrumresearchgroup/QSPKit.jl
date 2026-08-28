using Test
using ConfigKit

@testset "Struct Utilities" begin
    @testset "_scientific_string formatting" begin
        # Zero
        @test ConfigKit._scientific_string(0) == "0.0"
        @test ConfigKit._scientific_string(0.0) == "0.0"

        # Small numbers (should use scientific notation)
        @test contains(ConfigKit._scientific_string(0.0001), "e") || contains(ConfigKit._scientific_string(0.0001), "1")

        # Large numbers (should use scientific notation)
        @test contains(ConfigKit._scientific_string(10000.0), "e") || contains(ConfigKit._scientific_string(10000.0), "1")

        # Normal range numbers
        result = ConfigKit._scientific_string(1.234567)
        @test contains(result, "1.23")

        # Non-numeric types return string representation
        @test ConfigKit._scientific_string("hello") == "hello"
        @test ConfigKit._scientific_string(:symbol) == "symbol"

        # Custom digits parameter
        result_5 = ConfigKit._scientific_string(1.23456789; digits=5)
        @test length(split(result_5, ".")[2]) <= 6  # At most digits+1 after decimal
    end

    @testset "ParameterEntry construction and fields" begin
        entry = ConfigKit.ParameterEntry(
            :test_param,
            42.0,
            nothing,  # unit
            42.0,     # value_original
            Dict{Symbol,Any}(:description => "Test parameter"),
            nothing   # equation
        )

        @test entry.name == :test_param
        @test entry.value == 42.0
        @test entry.unit === nothing
        @test entry.value_original == 42.0
        @test entry.metadata[:description] == "Test parameter"
        @test entry.equation === nothing
    end

    @testset "ParameterEntry show with expression" begin
        # Test expression-valued parameter display
        entry = ConfigKit.ParameterEntry(
            :k_el,
            "CL / V",  # Expression as string
            nothing,
            "CL / V",
            Dict{Symbol,Any}(),
            nothing
        )

        io = IOBuffer()
        show(io, entry)
        output = String(take!(io))
        @test contains(output, "k_el")
        @test contains(output, "Expr")  # Expression indicator
    end

    @testset "ParametersView with empty data" begin
        empty_view = ConfigKit.ParametersView(OrderedCollections.OrderedDict{Symbol, ConfigKit.ParameterEntry}())

        @test length(empty_view) == 0
        @test collect(keys(empty_view)) == Symbol[]
        @test !haskey(empty_view, :anything)

        # Show method should work for empty view
        io = IOBuffer()
        @test_nowarn show(io, empty_view)
        output = String(take!(io))
        @test contains(output, "0 entries")
    end

    @testset "VariantDiffEntry fields" begin
        entry = ConfigKit.VariantDiffEntry(
            :CL,
            :Parameters,
            5.0,
            10.0,
            5.0,     # difference
            2.0,     # ratio
            "L/hr",  # unit
            "Clearance"  # description
        )

        @test entry.name == :CL
        @test entry.category == :Parameters
        @test entry.value_a == 5.0
        @test entry.value_b == 10.0
        @test entry.difference == 5.0
        @test entry.ratio == 2.0
        @test entry.unit == "L/hr"
        @test entry.description == "Clearance"
    end

    @testset "VariantDiffEntry with nothing fields" begin
        # Test with non-numeric values that result in nothing for difference/ratio
        entry = ConfigKit.VariantDiffEntry(
            :param,
            :Parameters,
            "expr_a",
            "expr_b",
            nothing,  # difference
            nothing,  # ratio
            nothing,  # unit
            nothing   # description
        )

        @test entry.difference === nothing
        @test entry.ratio === nothing
        @test entry.unit === nothing
        @test entry.description === nothing

        # Show should still work
        io = IOBuffer()
        @test_nowarn show(io, entry)
    end

    @testset "VariantDiffResult with many entries (show truncation)" begin
        # Create result with more than 10 entries to test truncation
        entries = [
            ConfigKit.VariantDiffEntry(
                Symbol("param_$i"),
                :Parameters,
                Float64(i),
                Float64(i * 2),
                Float64(i),
                2.0,
                nothing,
                nothing
            )
            for i in 1:15
        ]

        result = ConfigKit.VariantDiffResult(:variant_a, :variant_b, entries, nothing)

        @test length(result) == 15

        # Show should truncate after 10
        io = IOBuffer()
        show(io, result)
        output = String(take!(io))
        @test contains(output, "and 5 more")  # 15 - 10 = 5
    end

    @testset "VariantDiffResult empty" begin
        result = ConfigKit.VariantDiffResult(:a, :b, ConfigKit.VariantDiffEntry[], nothing)

        @test length(result) == 0

        io = IOBuffer()
        show(io, result)
        output = String(take!(io))
        @test contains(output, "0 differences")
    end
end
