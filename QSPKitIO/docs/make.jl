using Documenter
using QSPKit.QSPKitIO

makedocs(;
    modules=[QSPKitIO],
    authors="QSPKit contributors",
    sitename="QSPKitIO.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link=nothing,
        repolink=nothing,
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Archive format" => "archive_format.md",
        "API" => "api.md",
    ],
    checkdocs=:none,
    remotes=nothing,
)
