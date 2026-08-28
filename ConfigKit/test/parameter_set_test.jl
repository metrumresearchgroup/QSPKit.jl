using Test
using ConfigKit

@testset "ParameterSet" begin
    # Create a self-contained test keyfile
    keyfile_path = joinpath(mktempdir(), "test_parameter_set.yml")
    write(keyfile_path, """
    Parameters:
      CL:
        value: 5.0
        unit: "L/hr"
        desc: "Systemic clearance"
        bounds: [0.1, 100.0]
      V1:
        value: 50.0
        unit: L
        desc: "Central volume"
        bounds: [1.0, 500.0]
      Q:
        value: 10.0
        unit: "L/hr"
        desc: "Intercompartmental clearance"
    Variables:
      Central:
        initial: 0.0
        unit: mg
    Constants:
      MW:
        value: 450.0
        unit: "g/mol"
    """)

    kf = load_keyfile(keyfile_path)

    @testset "construction from keyfile" begin
        ps = ParameterSet(kf, [:CL, :V1])
        @test ps isa ParameterSet
        @test ps.names == [:CL, :V1]
        @test ps.values == [5.0, 50.0]
        @test ps.bounds.lb == [0.1, 1.0]
        @test ps.bounds.ub == [100.0, 500.0]
    end

    @testset "order preserved" begin
        ps = ParameterSet(kf, [:V1, :CL])
        @test ps.names == [:V1, :CL]
        @test ps.values == [50.0, 5.0]
        @test ps.bounds.lb == [1.0, 0.1]
        @test ps.bounds.ub == [500.0, 100.0]
    end

    @testset "single parameter" begin
        ps = ParameterSet(kf, [:CL])
        @test length(ps.names) == 1
        @test ps.values == [5.0]
    end

    @testset "missing bounds throws" begin
        @test_throws ErrorException ParameterSet(kf, [:CL, :Q])
    end

    @testset "show" begin
        ps = ParameterSet(kf, [:CL, :V1])
        buf = IOBuffer()
        show(buf, ps)
        s = String(take!(buf))
        @test occursin("2 params", s)
        @test occursin("CL", s)
        @test occursin("V1", s)
    end
end
