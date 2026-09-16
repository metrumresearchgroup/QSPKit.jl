push!(LOAD_PATH,"../src/")
using Documenter
using InjecKit

DocMeta.setdocmeta!(InjecKit, :DocTestSetup, :(using InjecKit, ModelingToolkit, DifferentialEquations, DataFrames); recursive=true)

makedocs(;
    modules=[InjecKit],
    authors="Tim Knab <knabt@metrumrg.com> and contributors",
    sitename="InjecKit.jl",
    checkdocs=:none,
    doctest=true,
    format=Documenter.HTML(;
        edit_link=nothing,
        repolink=nothing,
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Tutorials" => [
            "Getting Started" => "tutorials/getting_started.md",
            "Continuous Infusions" => "tutorials/continuous_infusions.md",
            "Advanced Usage" => "tutorials/advanced_usage.md",
        ],
        "Event Composition" => "event_composition.md",
        "Examples" => "examples.md",
        "API Reference" => "api.md",
    ],
    remotes=nothing,
)
