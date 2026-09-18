using Test
using QSPKit.SpecKit

const FIXTURES = joinpath(@__DIR__, "fixtures")

@testset verbose=true "SpecKit" begin

    # ============================================================
    # Native Parser — baseline spec
    # ============================================================
    @testset "Native Parser — baseline spec" begin
        meta = load_yspec(joinpath(FIXTURES, "baseline_spec.yml"); backend=:native)

        @test meta.description == "Baseline Biomarker Levels"
        @test haskey(meta.flags, :inflammatory)
        @test meta.flags[:inflammatory] == [:blood_eos, :feno]
        @test haskey(meta.columns, :name)
        @test haskey(meta.columns, :value)

        # Check values/decode on name column
        name_col = meta.columns[:name]
        @test !isnothing(name_col.values)
    end

    # ============================================================
    # Native Parser — drug response spec
    # ============================================================
    @testset "Native Parser — drug response spec" begin
        meta = load_yspec(joinpath(FIXTURES, "drug_response_spec.yml"); backend=:native)

        @test meta.description == "Drug Response Endpoints (Gadkar Fig 4)"

        # Endpoint column has values
        ep = meta.columns[:endpoint]
        @test ep.short == "biomarker endpoint"
        @test !isnothing(ep.values)

        # Drug column has values
        drug = meta.columns[:drug]
        @test drug.short == "treatment"
        @test !isnothing(drug.values)

        # Flags
        @test :biomarker in keys(meta.flags)
        @test :efficacy in keys(meta.flags)
    end

    # ============================================================
    # Native Parser — lookup resolution
    # ============================================================
    @testset "Native Parser — lookup resolution" begin
        meta = load_yspec(joinpath(FIXTURES, "with_lookup_spec.yml"); backend=:native)

        @test meta.description == "Targets with lookup"

        # blood_eos should have been resolved from lookup
        be = meta.columns[:blood_eos]
        @test be.short == "Blood Eosinophils"
        @test be.unit == "cells/uL"
        @test !isnothing(be.range)
        @test be.range == (0.0, 200.0)
        @test be.from_lookup == true

        # feno should also be resolved
        feno = meta.columns[:feno]
        @test feno.short == "Fractional Exhaled Nitric Oxide"
        @test feno.unit == "ppb"

        # fev1 with dots
        fev1 = meta.columns[:fev1]
        @test fev1.short == "Forced Expiratory Volume in 1s"
        @test haskey(fev1.dots, :weight)
        @test fev1.dots[:weight] == 2.0
    end

    # ============================================================
    # Native Parser — glue interpolation
    # ============================================================
    @testset "Native Parser — glue interpolation" begin
        meta = load_yspec(joinpath(FIXTURES, "with_lookup_spec.yml"); backend=:native)
        be = meta.columns[:blood_eos]

        # blood_eos has unit.tex: <<cellsul>> which should resolve
        @test haskey(be.namespaces, "tex")
        @test be.namespaces["tex"][:unit] == "cells/uL (LaTeX)"
    end

    # ============================================================
    # Helpers — namespace switching
    # ============================================================
    @testset "Helpers — namespace switching" begin
        meta = load_yspec(joinpath(FIXTURES, "with_lookup_spec.yml"); backend=:native)

        # Before namespace switch
        @test meta.columns[:blood_eos].unit == "cells/uL"

        # After namespace switch
        tex_meta = namespace(meta, "tex")
        @test tex_meta.columns[:blood_eos].unit == "cells/uL (LaTeX)"

        # feno has no tex namespace — should be unchanged
        @test tex_meta.columns[:feno].unit == "ppb"
    end

    # ============================================================
    # Helpers — decodes
    # ============================================================
    @testset "Helpers — decodes" begin
        meta = load_yspec(joinpath(FIXTURES, "drug_response_spec.yml"); backend=:native)

        d = decodes(meta, :drug)
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
        condar = getfield(parentmodule(SpecKit), :CondaR)
        @test !isdefined(@__MODULE__, :CondaR)
        @test SpecKit._rcopy_fn[] === condar.rcopy
        @test SpecKit._reval_fn[] === condar.reval

        # Exercise the public status API without provisioning R in this unit test.
        checked = SpecKit._YSPEC_CHECKED[]
        available = SpecKit._YSPEC_AVAILABLE[]
        try
            SpecKit._YSPEC_CHECKED[] = true
            SpecKit._YSPEC_AVAILABLE[] = false
            @test r_available() === false
        finally
            SpecKit._YSPEC_CHECKED[] = checked
            SpecKit._YSPEC_AVAILABLE[] = available
        end
    end

end
