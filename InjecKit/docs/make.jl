using Documenter
using InjecKit

makedocs(;
    modules=[InjecKit],
    authors="Tim Knab and contributors",
    sitename="InjecKit.jl",
    format=Documenter.HTML(;
        edit_link=nothing,
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Event Composition" => "event_composition.md",
        "Event Examples" => "examples.md",
        "API Reference" => "api.md",
    ],
    warnonly=[:missing_docs],
    remotes=nothing,
)
