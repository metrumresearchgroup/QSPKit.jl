using Test
using ConfigKit
using Symbolics: @variables

@testset "Keyfile value resolution" begin
    keyfile_path = joinpath(mktempdir(), "test_keyfile_values.yml")
    write(keyfile_path, """
    Parameters:
      CL:
        value: 3600.0
        unit: "L/hr"
        convert: "L/s"
      V:
        value: 10.0
        unit: "L"
      k_el:
        value: "CL / V"
        unit: "s^-1"
      half_life:
        value: "log(2) / k_el"
      pure_expr:
        value: "2.0 * 0.05"
      dose_per_mw:
        value: "dose / MW"
    Variables:
      Central:
        initial: 5.0
      DerivedVar:
        initial: "Central + dose"
    Constants:
      dose:
        value: 100.0
      MW:
        value: 50.0
    """)

    kf = load_keyfile(keyfile_path)

    @testset "numeric entries" begin
        @test value(kf, :CL) ≈ 1.0
        @test value(kf, :CL; convert=false) ≈ 3600.0
        @test value(kf.Parameters, :CL) ≈ 1.0
        @test value(kf.Parameters[:CL]) ≈ 1.0
        @test value(kf.Parameters[:CL]; convert=false) ≈ 3600.0
        @test value(kf, "V") ≈ 10.0
    end

    @testset "expression entries" begin
        @test value(kf, :k_el) ≈ 0.1
        @test value(kf, :k_el; convert=false) ≈ 360.0
        @test value(kf, :half_life) ≈ log(2) / 0.1
        @test value(kf, :half_life; convert=false) ≈ log(2) / 360.0
        @test value(kf, :dose_per_mw) ≈ 2.0
        @test value(kf, :DerivedVar) ≈ 105.0
        @test value(kf.Parameters, :k_el) ≈ 0.1
        @test value(kf.Parameters, :dose_per_mw) ≈ 2.0
        @test value(kf.Variables, :DerivedVar) ≈ 105.0
        @test value(kf.Parameters[:pure_expr]) ≈ 0.1
        @test value(kf.Parameters[:k_el]) ≈ 0.1
        @test value(kf.Variables[:DerivedVar]) ≈ 105.0
    end

    @testset "bulk values use resolved values" begin
        @test get_values(kf, [:CL, :k_el]) ≈ [1.0, 0.1]
        @test get_values(kf, [:CL, :k_el]; convert=false) ≈ [3600.0, 360.0]
    end

    @testset "symbolic keys" begin
        @variables CL
        @test value(kf, CL) ≈ 1.0
    end

    @testset "ambiguous names require block scope" begin
        ambiguous_path = joinpath(mktempdir(), "ambiguous_values.yml")
        write(ambiguous_path, """
        Parameters:
          shared:
            value: 1.0
        Constants:
          shared:
            value: 2.0
        """)
        ambiguous = load_keyfile(ambiguous_path)

        @test_throws ArgumentError value(ambiguous, :shared)
        @test value(ambiguous.Parameters, :shared) == 1.0
        @test value(ambiguous.Constants, :shared) == 2.0
    end

    @testset "dependency errors" begin
        bad_path = joinpath(mktempdir(), "bad_values.yml")
        write(bad_path, """
        Parameters:
          A:
            value: "B + 1"
          B:
            value: "A + 1"
          missing_dep:
            value: "not_in_keyfile + 1"
        """)
        bad = load_keyfile(bad_path)

        cycle_err = try
            value(bad, :A)
            nothing
        catch err
            err
        end
        @test cycle_err isa ArgumentError
        @test occursin("Cyclic", sprint(showerror, cycle_err))

        missing_err = try
            value(bad, :missing_dep)
            nothing
        catch err
            err
        end
        @test missing_err isa ArgumentError
        @test occursin("Unresolved symbol", sprint(showerror, missing_err))
    end
end
