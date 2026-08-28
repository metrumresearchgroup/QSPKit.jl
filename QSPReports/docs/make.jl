using Documenter
using QSPReports

makedocs(;
    modules=[QSPReports],
    authors="QSPKit contributors",
    sitename="QSPReports.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link=nothing,
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Actions and options" => "actions.md",
        "Parameter tables" => "parameters.md",
        "API" => "api.md",
    ],
    remotes=nothing,
)
