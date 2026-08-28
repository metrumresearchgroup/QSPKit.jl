# ═══ Global File I/O Tracking via Method Specialization ═══
#
# Adds a String-specific method to Base.open that logs file paths,
# then invokes the original AbstractString method. This catches ALL
# file reads from any library (CSV.jl, YAML.jl, JLD2.jl, include(),
# plain read()) globally in all execution modes. Zero TTFX.
#
# How it works: Julia dispatches open(f, "myfile.csv", "r") to our
# String-specific method first (more specific than AbstractString).
# We log, then invoke the original AbstractString method for actual I/O.

"""
    FILE_READS

Global log of file opens. Each entry records the absolute path, the
expression ID that was active when the file was opened (set by the
session log's ast_transforms hook in interactive mode), and the open
`mode` string (e.g. `"r"`, `"w"`). The mode lets attribution drop files
that were *written* (outputs) rather than *read* (inputs); see
[`_is_read_mode`](@ref). Despite the name, this log includes write opens
too — they are recorded but excluded from dependency attribution.
"""
const FILE_READS = Vector{NamedTuple{(:path, :expr_id, :mode), Tuple{String, Int, String}}}()

"""
    _CURRENT_EXPR_ID

Ref holding the current expression ID, set by the session log's
`_recording_transform` before each REPL expression evaluates.
File reads during that expression are tagged with this ID.
"""
const _CURRENT_EXPR_ID = Ref{Int}(0)

"""
    Base.open(f::Function, path::String, mode::String; kwargs...)
    Base.open(f::Function, path::String; kwargs...)

Method specialization on `String` (more specific than `AbstractString`)
that logs every file open, then delegates to the original method.
"""
function _record_file_open(path::String, mode::String)
    lock(_STOREKIT_LOCK) do
        push!(FILE_READS, (path=abspath(path), expr_id=_CURRENT_EXPR_ID[], mode=mode))
    end
    return nothing
end

function _keyword_open_mode(kwargs)
    enabled(key) = haskey(kwargs, key) && kwargs[key] === true
    reads = enabled(:read)
    if enabled(:append)
        return reads ? "a+" : "a"
    elseif enabled(:write) || enabled(:create) || enabled(:truncate)
        return reads ? "r+" : "w"
    end
    return "r"
end

function Base.open(f::Function, path::String, mode::String; kwargs...)
    _record_file_open(path, mode)
    return invoke(Base.open, Tuple{Function, AbstractString, AbstractString}, f, path, mode; kwargs...)
end

function Base.open(f::Function, path::String; kwargs...)
    _record_file_open(path, _keyword_open_mode(kwargs))
    return invoke(Base.open, Tuple{Function, AbstractString}, f, path; kwargs...)
end

"""
    _is_read_mode(mode::AbstractString) -> Bool

True if an open `mode` denotes a pure read (and is therefore a dependency
*input* worth attributing). Write/append modes (`"w"`, `"a"`, …) and
read-write modes (anything containing `+`, e.g. `"r+"`) return `false`,
because a file the computation may have *written* must not be snapshotted
as an input — doing so causes false-positive staleness when the output is
later regenerated. An empty/default mode is treated as read (`open`'s
default is `"r"`). This predicate is the single source of truth; consumers
must call it rather than comparing `mode == "r"` (which would mishandle
`"rb"`/`"rt"`).
"""
function _is_read_mode(mode::AbstractString)
    m = lowercase(strip(mode))
    isempty(m) && return true
    return startswith(m, "r") && !occursin('+', m)
end

"""
    get_file_reads()

Return a copy of the current file read log.
"""
get_file_reads() = lock(_STOREKIT_LOCK) do
    copy(FILE_READS)
end

"""
    clear_file_reads!()

Clear the file read log. Useful for testing.
"""
clear_file_reads!() = lock(_STOREKIT_LOCK) do
    empty!(FILE_READS)
end

"""
    truncate_file_reads!(n)

Drop file-read entries beyond the first `n`. Used by callers (e.g. `book!`) to
remove their OWN internal file reads — captured `n = length(FILE_READS)` before
doing any reading — so those reads don't pollute later attribution.
"""
truncate_file_reads!(n::Integer) = lock(_STOREKIT_LOCK) do
    n < length(FILE_READS) && resize!(FILE_READS, n)
    nothing
end
