# .decision.md generation

"""
    _write_decision_md(store_dir, name, status, rationale, fit_quality, result, files)

Generate a `.decision.md` file summarizing the booked result.
"""
function _write_decision_md(store_dir::String, name::String, status::Symbol,
                            rationale::String, fit_quality, result, files)
    decisions_dir = joinpath(store_dir, ".provenance", "decisions")
    mkpath(decisions_dir)

    timestamp = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    slug = replace(lowercase(name), r"[^a-z0-9]+" => "_")
    filename = "$(slug).md"
    filepath = joinpath(decisions_dir, filename)

    io = IOBuffer()
    println(io, "# Decision: $name")
    println(io)
    println(io, "**Status:** $status")
    println(io, "**Timestamp:** $timestamp")
    println(io)

    if !isempty(rationale)
        println(io, "## Rationale")
        println(io)
        println(io, rationale)
        println(io)
    end

    if fit_quality !== nothing
        println(io, "## Fit Quality")
        println(io)
        if fit_quality isa AbstractDict
            for (k, v) in pairs(fit_quality)
                println(io, "- **$k:** $v")
            end
        else
            println(io, fit_quality)
        end
        println(io)
    end

    # Summarize result if it has fitted_params
    if result !== nothing
        try
            fp = result.fitted_params
            if fp !== nothing
                println(io, "## Fitted Parameters")
                println(io)
                if fp isa AbstractDict
                    for (k, v) in pairs(fp)
                        println(io, "- `$k` = $v")
                    end
                else
                    println(io, fp)
                end
                println(io)
            end
        catch
            # result doesn't have fitted_params, skip
        end

        # loss / score
        try
            loss = result.loss
            if loss !== nothing
                println(io, "## Score")
                println(io)
                println(io, "- **Loss:** $loss")
                println(io)
            end
        catch; end
    end

    if !isempty(files)
        println(io, "## Attributed Files")
        println(io)
        for f in sort(collect(files))
            println(io, "- `$f`")
        end
        println(io)
    end

    write(filepath, take!(io))
    return filepath
end
