using StoreKit
using Documenter

makedocs(;
    modules=[StoreKit],
    authors="Tim Knab",
    sitename="StoreKit.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link=nothing,
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "File Tracking" => "file_tracking.md",
        "API Reference" => "api_reference.md",
    ],
    warnonly=[:missing_docs],
    remotes=nothing,
)
