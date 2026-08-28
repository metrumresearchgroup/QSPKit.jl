using BookKit
using Documenter

makedocs(;
    modules=[BookKit],
    authors="Tim Knab",
    sitename="BookKit.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link=nothing,
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Decision Files" => "decisions.md",
        "Staleness Detection" => "staleness.md",
        "Lineage Graphs" => "lineage.md",
        "API Reference" => "api_reference.md",
    ],
    warnonly=[:missing_docs],
    remotes=nothing,
)
