using Documenter
using QSPKitCore

makedocs(;
    modules=[QSPKitCore],
    authors="QSPKit contributors",
    sitename="QSPKitCore.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link=nothing,
        assets=String[],
    ),
    pages=["Home" => "index.md"],
    remotes=nothing,
)
