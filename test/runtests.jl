using Test
using QSPKit

@testset "QSPKit unified package" begin
    @test pkgversion(QSPKit) == v"0.1.0"
    @test QSPKit.ConfigKit.load_keyfile === QSPKit.load_keyfile
    @test QSPKit.InjecKit.ev === QSPKit.ev
    @test QSPKit.SimKit.simulate === QSPKit.simulate
    @test QSPKit.SimKit.Population === QSPKit.Population

    exported = Set(names(QSPKit))
    @test :simulate in exported
    @test :ev in exported
    @test !(:fit in exported)
    @test !(:ggplot in exported)

    @test :fit in names(QSPKit.TargKit)
    @test :ggplot in names(QSPKit.ShowKit)
    @test :book! in names(QSPKit.BookKit)
end

include("namespace_audit.jl")

const COMPONENT_TEST_SUITES = [
    "QSPKitCore",
    "ConfigKit",
    "CondaR",
    "StoreKit",
    "QSPKitIO",
    "SpecKit",
    "InjecKit",
    "QSPReports",
    "ShowKit",
    "SimKit",
    "TargKit",
    "BookKit",
]

@testset "QSPKit component suites" begin
    for component in COMPONENT_TEST_SUITES
        @testset "$component" begin
            suite_name = Symbol(component, "Tests")
            suite_path = joinpath(@__DIR__, "..", component, "test", "runtests.jl")
            body = quote
                Base.include(@__MODULE__, $suite_path)
            end
            Core.eval(Main, Expr(:module, true, suite_name, body))
        end
    end
end
