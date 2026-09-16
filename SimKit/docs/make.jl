using SimKit
using Documenter

makedocs(;
    modules=[SimKit],
    authors="Tim Knab",
    sitename="SimKit.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link=nothing,
        repolink=nothing,
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Pipeline API" => "pipeline.md",
        "Branching & Sweeps" => "branching.md",
        "Caching" => "caching.md",
        "TargKit Integration" => "targkit.md",
        "Examples" => "examples.md",
        "API Reference" => "api_reference.md",
    ],
    checkdocs=:none,
    remotes=nothing,
)
