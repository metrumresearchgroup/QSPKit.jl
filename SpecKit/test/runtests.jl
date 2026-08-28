using Test
using SpecKit

const FIXTURES = joinpath(@__DIR__, "fixtures")

@testset verbose=true "SpecKit" begin

    # ============================================================
    # Native Parser — baseline spec
    # ============================================================
    @testset "Native Parser — baseline spec" begin
        meta = load_yspec(joinpath(FIXTURES, "baseline_spec.yml"); backend=:native)

        @test meta.description == "Synthetic Controller Checks"
        @test haskey(meta.flags, :required)
        @test meta.flags[:required] == [:setpoint, :measured]
        @test haskey(meta.columns, :check)
        @test haskey(meta.columns, :reading)

        # Check values/decode on the check-name column.
        check_col = meta.columns[:check]
        @test !isnothing(check_col.values)
    end

    # ============================================================
    # Native Parser — synthetic device-mode spec
    # ============================================================
    @testset "Native Parser — synthetic device-mode spec" begin
        meta = load_yspec(joinpath(FIXTURES, "device_channels_spec.yml"); backend=:native)

        @test meta.description == "Synthetic Device Modes"

        # Channel column has values.
        channel = meta.columns[:channel]
        @test channel.short == "controller output"
        @test !isnothing(channel.values)

        # Operating mode column has values.
        mode = meta.columns[:mode]
        @test mode.short == "synthetic operating mode"
        @test !isnothing(mode.values)

        # Flags
        @test :required in keys(meta.flags)
        @test :diagnostic in keys(meta.flags)
    end

    # ============================================================
    # Native Parser — lookup resolution
    # ============================================================
    @testset "Native Parser — lookup resolution" begin
        meta = load_yspec(joinpath(FIXTURES, "with_lookup_spec.yml"); backend=:native)

        @test meta.description == "Controller channels with lookup"

        # input_level should have been resolved from lookup
        input_level = meta.columns[:input_level]
        @test input_level.short == "Input level"
        @test input_level.unit == "volt"
        @test !isnothing(input_level.range)
        @test input_level.range == (-5.0, 5.0)
        @test input_level.from_lookup == true

        # response_gain should also be resolved
        response_gain = meta.columns[:response_gain]
        @test response_gain.short == "Response gain"
        @test response_gain.unit == "ratio"

        # residual carries an extra weight field.
        residual = meta.columns[:residual]
        @test residual.short == "Residual error"
        @test haskey(residual.dots, :weight)
        @test residual.dots[:weight] == 0.35
    end

    # ============================================================
    # Native Parser — glue interpolation
    # ============================================================
    @testset "Native Parser — glue interpolation" begin
        meta = load_yspec(joinpath(FIXTURES, "with_lookup_spec.yml"); backend=:native)
        input_level = meta.columns[:input_level]

        # input_level has unit.tex: <<input_unit>> which should resolve
        @test haskey(input_level.namespaces, "tex")
        @test input_level.namespaces["tex"][:unit] == "volt (formatted)"
    end

    # ============================================================
    # Helpers — namespace switching
    # ============================================================
    @testset "Helpers — namespace switching" begin
        meta = load_yspec(joinpath(FIXTURES, "with_lookup_spec.yml"); backend=:native)

        # Before namespace switch
        @test meta.columns[:input_level].unit == "volt"

        # After namespace switch
        tex_meta = namespace(meta, "tex")
        @test tex_meta.columns[:input_level].unit == "volt (formatted)"

        # response_gain has no tex namespace — should be unchanged
        @test tex_meta.columns[:response_gain].unit == "ratio"
    end

    # ============================================================
    # Helpers — decodes
    # ============================================================
    @testset "Helpers — decodes" begin
        meta = load_yspec(joinpath(FIXTURES, "device_channels_spec.yml"); backend=:native)

        d = decodes(meta, :mode)
        @test !isempty(d)
        @test d isa Dict
    end

    # ============================================================
    # Helpers — lookup_source
    # ============================================================
    @testset "Helpers — lookup_source" begin
        meta = load_yspec(joinpath(FIXTURES, "with_lookup_spec.yml"); backend=:native)

        audit = lookup_source(meta)
        @test audit isa Vector
        @test length(audit) > 0
        @test haskey(first(audit), :column)
        @test haskey(first(audit), :from_lookup)
    end

    # ============================================================
    # Types — ColumnSpec construction
    # ============================================================
    @testset "ColumnSpec construction" begin
        col = ColumnSpec(:test; short="Test Column", unit="mg/L")
        @test col.name == :test
        @test col.short == "Test Column"
        @test col.unit == "mg/L"
        @test col.type == :numeric
        @test isnothing(col.range)
        @test isnothing(col.values)
        @test col.from_lookup == false
    end

    # ============================================================
    # Types — YspecMetadata construction
    # ============================================================
    @testset "YspecMetadata construction" begin
        meta = YspecMetadata(; description="Test spec")
        @test meta.description == "Test spec"
        @test isempty(meta.columns)
        @test isempty(meta.flags)
    end

    # ============================================================
    # Backend — r_available
    # ============================================================
    @testset "Backend — r_available" begin
        # The fixed test environment intentionally has no CondaR dependency.
        # Native parsing must remain deterministic, while an explicit R request
        # must fail loudly instead of being silently skipped.
        @test r_available() === false
        err = try
            load_yspec(joinpath(FIXTURES, "baseline_spec.yml"); backend=:rcall)
            nothing
        catch caught
            caught
        end
        @test err isa ErrorException
        @test occursin("RCall backend not available", sprint(showerror, err))
    end

    @testset "Backend selection and errors" begin
        native = load_yspec(joinpath(FIXTURES, "baseline_spec.yml"); backend=:native)
        automatic = load_yspec(joinpath(FIXTURES, "baseline_spec.yml"); backend=:auto)
        @test automatic.description == native.description
        @test collect(keys(automatic.columns)) == collect(keys(native.columns))
        @test_throws ErrorException load_yspec(joinpath(FIXTURES, "missing.yml"))
        @test_throws ErrorException load_yspec(
            joinpath(FIXTURES, "baseline_spec.yml"); backend=:unknown)
    end

    @testset "R backend boundary contract" begin
        refs = (
            SpecKit._RCALL_AVAILABLE,
            SpecKit._YSPEC_AVAILABLE,
            SpecKit._YSPEC_CHECKED,
            SpecKit._rcopy_fn,
            SpecKit._reval_fn,
        )
        saved = map(ref -> ref[], refs)
        evaluated = String[]
        try
            SpecKit._RCALL_AVAILABLE[] = true
            SpecKit._YSPEC_AVAILABLE[] = true
            SpecKit._YSPEC_CHECKED[] = true
            SpecKit._reval_fn[] = code -> begin
                push!(evaluated, String(code))
                String(code)
            end
            SpecKit._rcopy_fn[] = function(args...)
                if length(args) == 2 && args[1] === Bool
                    return true
                elseif length(args) == 2 && args[1] === Vector{String}
                    return ["gain", "offset"]
                end

                code = only(args)
                occursin("attributes(.__yspec_tmp__)", code) && return Dict(
                    "description" => "Mock R controller spec",
                    "flags" => Dict("required" => ["gain"]),
                    "glue" => Dict("display_unit" => "ratio"),
                    "lookup_file" => ["channels.yml"],
                    "extend_file" => String[],
                )
                occursin("[['gain']]", code) && return Dict(
                    "short" => "Controller gain",
                    "unit" => "ratio",
                    "type" => "numeric",
                    "range" => [0.0, 1.5],
                    "values" => [0.25, 0.75],
                    "decode" => ["low", "nominal"],
                    "weight.display" => "relative",
                    "lookup" => true,
                )
                occursin("[['offset']]", code) && return Dict(
                    "short" => "Controller offset",
                    "type" => "numeric",
                    "range" => [-1.0, 1.0],
                )
                error("unexpected mock R conversion: $code")
            end

            meta = load_yspec(
                joinpath(FIXTURES, "baseline_spec.yml");
                backend=:rcall,
            )
            @test meta.description == "Mock R controller spec"
            @test meta.flags[:required] == [:gain]
            @test collect(keys(meta.columns)) == [:gain, :offset]
            @test meta.columns[:gain].range == (0.0, 1.5)
            @test meta.columns[:gain].from_lookup
            @test meta.columns[:gain].namespaces["display"][:weight] == "relative"
            @test meta.lookup_files == ["channels.yml"]
            @test any(code -> occursin("yspec::ys_load", code), evaluated)
            @test any(code -> occursin("rm(.__yspec_tmp__)", code), evaluated)
        finally
            for (ref, value) in zip(refs, saved)
                ref[] = value
            end
        end
    end

    @testset "Helpers are non-mutating and validate columns" begin
        meta = load_yspec(joinpath(FIXTURES, "with_lookup_spec.yml"); backend=:native)
        tex_meta = namespace(meta, "tex")
        @test tex_meta !== meta
        @test tex_meta.columns !== meta.columns
        @test meta.columns[:input_level].unit == "volt"
        @test tex_meta.columns[:input_level].unit == "volt (formatted)"
        @test_throws ErrorException decodes(meta, :not_a_column)

        plain = ColumnSpec(:arm; values=["A", "B"])
        plain_meta = YspecMetadata(columns=SpecKit.OrderedDict(:arm => plain))
        @test decodes(plain_meta, :arm) == Dict("A" => "A", "B" => "B")
    end

    @testset "Public API" begin
        expected = Set([
            :ColumnSpec,
            :YspecMetadata,
            :decodes,
            :load_yspec,
            :lookup_source,
            :namespace,
            :r_available,
        ])
        actual = Set(names(SpecKit; all=false, imported=false))
        delete!(actual, :SpecKit)
        @test actual == expected
    end

end
