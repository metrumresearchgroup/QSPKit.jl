using Documenter
using SpecKit

makedocs(
    modules=[SpecKit],
    sitename="SpecKit.jl",
    remotes=nothing,
    format=Documenter.HTML(edit_link=nothing),
    pages=[
        "Home" => "index.md",
        "API" => "api.md",
    ],
    warnonly=[:missing_docs],
)
