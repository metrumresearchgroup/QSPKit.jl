# ============================================================
# mrggsave — Plot Saving with Provenance Annotation
# ============================================================

# Frames under this prefix are ShowKit's own source and are skipped when
# detecting the caller's script (trailing separator avoids matching siblings).
const _SHOWKIT_SRC_PREFIX = joinpath(normpath(joinpath(@__DIR__, "..")), "")

# A stack frame names a real script when its file ends in `.jl`. Interactive
# pseudo-files — `none` (`julia -e`/piped stdin/fallback REPL), `REPL[1]` (TTY
# REPL), IJulia `In[3]`, Pluto `nb.jl#==#<uuid>` — do not, so they map to
# `nothing` and force the caller to pass `script` explicitly.
_script_name(file::AbstractString) = endswith(file, ".jl") ? basename(file) : nothing

"""
    _caller_script() -> Union{String, Nothing}

Best-effort detection of the `.jl` script that called into ShowKit, used to
auto-populate the `script` ("Source code") provenance annotation. Walks the
current stack outward, skips ShowKit's own frames, and inspects the first
remaining frame — the direct caller. Returns that file's `basename` when it is a
real script, or `nothing` for an interactive session (REPL, `julia -e`, notebook
cell), where there is no script file to name.
"""
function _caller_script()
    for frame in stacktrace()
        file = String(frame.file)
        isempty(file) && continue
        startswith(normpath(file), _SHOWKIT_SRC_PREFIX) && continue
        # First non-ShowKit frame is the direct caller; inspect only it. Going
        # deeper would hit Base frames (boot.jl/client.jl) and misreport those
        # as the script in interactive sessions.
        return _script_name(file)
    end
    return nothing
end

# Resolve the `script` annotation: an explicit value wins; otherwise auto-detect
# the calling script, and refuse (rather than silently mislabel) when called
# interactively.
function _resolve_script(script::Union{String, Nothing})
    script !== nothing && return script
    detected = _caller_script()
    detected === nothing && throw(ArgumentError(
        "mrggsave: no `script` given and the calling script could not be " *
        "identified — this looks like an interactive session (REPL, `julia -e`, " *
        "or a notebook cell). Pass `script=\"<name>.jl\"` to set the 'Source code' " *
        "annotation."))
    return detected
end

"""
    mrggsave(plot::GGPlot, stem::String; dir=".", script=nothing,
             dev=["pdf"], width=5.0, height=4.0, kwargs...)

Save a ggplot with provenance annotation via mrggsave R package.

When `script` is omitted, the "Source code" annotation is auto-detected from the
`.jl` file that called `mrggsave`. Called from the REPL or another interactive
session (where there is no script file), it errors and asks for an explicit
`script`.

# Example
```julia
mrggsave(p, "dv-pred"; dir="deliv/figure", script="analysis.jl", dev=["pdf", "png"])
```
"""
function mrggsave(plot::GGPlot, stem::String;
                  dir::String=".",
                  script::Union{String, Nothing}=nothing,
                  dev::Union{String, Vector{String}}=["pdf"],
                  width::Real=5.0,
                  height::Real=4.0,
                  kwargs...)
    _require_mrggsave()
    r_fn = _reval("mrggsave::mrggsave")

    dev_vec = dev isa String ? [dev] : dev

    r_kwargs = Pair{Symbol, Any}[
        :stem => stem,
        :dir => dir,
        :dev => _robject(dev_vec),
        :width => Float64(width),
        :height => Float64(height),
        Symbol("path.type") => "none",
    ]
    push!(r_kwargs, :script => _resolve_script(script))
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => _convert_value(v))
    end
    _rcall(r_fn, plot.robject; r_kwargs...)
    # Close any stray R graphics devices (mrggsave can open RPlots.pdf)
    _reval("while(grDevices::dev.cur() > 1) grDevices::dev.off()")
    # Clean up the RPlots.pdf if it got created
    if isfile("Rplots.pdf"); rm("Rplots.pdf"; force=true); end
    nothing
end

"""
    mrggsave_list(plots::Vector{GGPlot}; stems=nothing, dir=".", script=nothing,
                  dev=["pdf"], width=5.0, height=4.0, kwargs...)

Save a list of ggplot objects, each to its own file. Like [`mrggsave`](@ref),
an omitted `script` is auto-detected from the calling `.jl` file and errors when
called interactively.

# Example
```julia
mrggsave_list([p1, p2, p3];
    stems=["dv-pred", "cwres-time", "eta-cont"],
    dir="deliv/figure", dev=["pdf", "png"])
```
"""
function mrggsave_list(plots::Vector{GGPlot};
                       stems::Union{Nothing, Vector{String}}=nothing,
                       dir::String=".",
                       script::Union{String, Nothing}=nothing,
                       dev::Union{String, Vector{String}}=["pdf"],
                       width::Real=5.0,
                       height::Real=4.0,
                       kwargs...)
    _require_mrggsave()

    # Build R list of plots
    r_list = _reval("list()")
    for (i, p) in enumerate(plots)
        r_list = _rcall(Symbol("[[<-"), r_list, i, p.robject)
    end

    # If stems provided, set names on the list
    if !isnothing(stems)
        _rcall(Symbol("names<-"), r_list, _robject(stems))
    end

    dev_vec = dev isa String ? [dev] : dev

    r_fn = _reval("mrggsave::mrggsave_list")
    r_kwargs = Pair{Symbol, Any}[
        :dir => dir,
        :dev => _robject(dev_vec),
        :width => Float64(width),
        :height => Float64(height),
        Symbol("path.type") => "none",
    ]
    push!(r_kwargs, :script => _resolve_script(script))
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        push!(r_kwargs, rname => _convert_value(v))
    end
    _rcall(r_fn, r_list; r_kwargs...)
    _reval("while(grDevices::dev.cur() > 1) grDevices::dev.off()")
    if isfile("Rplots.pdf"); rm("Rplots.pdf"; force=true); end
    nothing
end
