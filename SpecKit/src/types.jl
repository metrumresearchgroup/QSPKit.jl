# ============================================================
# Types — yspec metadata
# ============================================================

# ============================================================
# ColumnSpec — metadata for a single yspec column
# ============================================================

"""
    ColumnSpec

Metadata for a single column from a yspec YAML file.
"""
struct ColumnSpec
    name::Symbol
    short::Union{String, Nothing}
    label::Union{String, Nothing}
    long::Union{String, Nothing}
    unit::Union{String, Nothing}
    type::Symbol                                    # :numeric, :integer, :character
    range::Union{Tuple{Float64, Float64}, Nothing}  # validation range
    values::Union{Vector, Dict, Nothing}            # valid values / decode map
    source::Union{String, Nothing}
    comment::Union{String, Nothing}
    dots::Dict{Symbol, Any}
    namespaces::Dict{String, Dict{Symbol, String}}  # "tex" => Dict(:unit => "...")
    from_lookup::Bool
end

function ColumnSpec(name::Symbol;
    short=nothing, label=nothing, long=nothing, unit=nothing,
    type=:numeric, range=nothing, values=nothing,
    source=nothing, comment=nothing,
    dots=Dict{Symbol,Any}(), namespaces=Dict{String,Dict{Symbol,String}}(),
    from_lookup=false,
)
    ColumnSpec(name, short, label, long, unit, type, range, values,
              source, comment, dots, namespaces, from_lookup)
end

# ============================================================
# YspecMetadata — parsed yspec file
# ============================================================

"""
    YspecMetadata

Complete metadata from a parsed yspec YAML file.
"""
struct YspecMetadata
    description::Union{String, Nothing}
    sponsor::Union{String, Nothing}
    projectnumber::Union{String, Nothing}
    data_stem::Union{String, Nothing}
    data_path::Union{String, Nothing}
    columns::OrderedDict{Symbol, ColumnSpec}
    flags::Dict{Symbol, Vector{Symbol}}
    glue::Dict{String, String}
    lookup_files::Vector{String}
    extend_files::Vector{String}
end

function YspecMetadata(;
    description=nothing, sponsor=nothing, projectnumber=nothing,
    data_stem=nothing, data_path=nothing,
    columns=OrderedDict{Symbol, ColumnSpec}(),
    flags=Dict{Symbol, Vector{Symbol}}(),
    glue=Dict{String, String}(),
    lookup_files=String[], extend_files=String[],
)
    YspecMetadata(description, sponsor, projectnumber, data_stem, data_path,
                 columns, flags, glue, lookup_files, extend_files)
end
