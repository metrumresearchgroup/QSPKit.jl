# The root-prefix CLI flag is not inherited by micromamba calls made by shell
# activation/post-link scripts. Keep their root consistent with the parent.
function _micromamba_cmd(args)
    root = MicroMamba.root_dir()
    mkpath(root)
    addenv(MicroMamba.cmd(args), "MAMBA_ROOT_PREFIX" => root)
end

function _installer_line(line)
    startswith(line, "CondaR:") && return line
    startswith(line, "Linking ") && return "CondaR: " * line
    # Never hide native installer errors, even if its exit status is zero.
    occursin(r"^(critical |error |ERROR|Error)", line) && return line
    nothing
end

struct InstallationError <: Exception
    stage::String
    logfile::String
    cause::Union{Nothing,ProcessFailedException}
end

function Base.showerror(io::IO, err::InstallationError)
    print(io, "CondaR: ", err.stage, " failed")
    if err.cause !== nothing
        print(io, " (exit ", join([p.exitcode for p in err.cause.procs], ", "), ")")
    end
    print(io, ". Full installer log: ", err.logfile)
end

_transport_failure(err) = err isa ProcessFailedException && any(p.exitcode == 75 for p in err.procs)
_transport_failure(err::InstallationError) = _transport_failure(err.cause)

"""Run an installer with complete logs, concise progress, and visible failures."""
function _run_logged(command, logfile; verbose=false, label="Installing", io=stderr, heartbeat_seconds=15, fail_on_critical=false)
    mkpath(dirname(logfile))
    println(io, "CondaR: $label. Full log: $logfile")
    started = time()
    last_output = Ref(started)
    stage = Ref(label)
    recent = String[]
    critical = false
    output = Pipe()
    process = nothing
    heartbeat = nothing
    try
        open(logfile, "w") do log
            process = run(pipeline(ignorestatus(command); stdout=output, stderr=output); wait=false)
            close(output.in)
            if heartbeat_seconds > 0
                heartbeat = Timer(heartbeat_seconds; interval=heartbeat_seconds) do _
                    if time() - last_output[] >= heartbeat_seconds
                        println(io, "CondaR: $(stage[]) — still working ($(round(Int, time() - started)) s elapsed)")
                        last_output[] = time()
                    end
                end
            end
            for line in eachline(output)
                critical |= startswith(line, "critical libmamba")
                println(log, line)
                flush(log)
                push!(recent, line)
                length(recent) > 40 && popfirst!(recent)
                progress = _installer_line(line)
                if verbose || progress !== nothing
                    println(io, verbose ? line : progress)
                    last_output[] = time()
                    progress !== nothing && startswith(progress, "CondaR: ") &&
                        (stage[] = replace(progress, r"^CondaR: " => ""))
                end
            end
            wait(process)
        end
        if !success(process) || (fail_on_critical && critical)
            println(io, "CondaR: $label failed. Full log: $logfile")
            if !verbose
                println(io, "CondaR: last $(length(recent)) log lines:")
                foreach(line -> println(io, line), recent)
            end
            throw(InstallationError(stage[], logfile, success(process) ? nothing : ProcessFailedException(process)))
        end
    finally
        heartbeat !== nothing && close(heartbeat)
        if process !== nothing && process_running(process)
            kill(process)
            wait(process)
        end
        close(output)
    end
    nothing
end

_installer_log(directory, action) = joinpath(directory, "logs", "$action-$(time_ns()).log")
