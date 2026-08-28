using ShowKit
using Documenter

makedocs(;
    modules=[ShowKit],
    authors="Tim Knab",
    sitename="ShowKit.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link=nothing,
        assets=String[],
    ),
    remotes=nothing,
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "ggplot2" => "ggplot2.md",
        "pmplots" => "pmplots.md",
        "pmtables" => "pmtables.md",
        "mrggsave" => "mrggsave.md",
        "SpecKit Integration" => "yspec.md",
        "API Reference" => "api_reference.md",
    ],
    warnonly=[:missing_docs],
)
