using CondaR
using Documenter

makedocs(
    modules=[CondaR],
    sitename="CondaR.jl",
    remotes=nothing,
    format=Documenter.HTML(edit_link=nothing),
    pages=[
        "Home" => "index.md",
        "API" => "api.md",
    ],
    warnonly=[:missing_docs],
)
