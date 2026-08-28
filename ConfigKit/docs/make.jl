using ConfigKit
using Documenter

makedocs(;
    modules=[ConfigKit],
    authors="Tim Knab",
    sitename="ConfigKit.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link=nothing,
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Keyfile Format" => "keyfile_format.md",
        "Variants" => "variants.md",
        "Optics" => "optics.md",
        "Update Engine" => "update_engine.md",
        "API Reference" => "api_reference.md",
    ],
    warnonly=[:missing_docs],
    remotes=nothing,
)
