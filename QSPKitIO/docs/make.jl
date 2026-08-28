using Documenter
using QSPKitIO

makedocs(;
    modules=[QSPKitIO],
    authors="QSPKit contributors",
    sitename="QSPKitIO.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link=nothing,
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Archive format" => "archive_format.md",
        "API" => "api.md",
    ],
    remotes=nothing,
)
