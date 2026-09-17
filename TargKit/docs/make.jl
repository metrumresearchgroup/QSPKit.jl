using Documenter
using QSPKit.TargKit

makedocs(;
    modules=[TargKit],
    authors="Tim Knab and contributors",
    sitename="TargKit.jl",
    format=Documenter.HTML(edit_link=nothing, repolink=nothing, assets=String[]),
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "API Reference" => "api_reference.md",
    ],
    checkdocs=:none,
    remotes=nothing,
)
