@testset "Installer progress and diagnostics" begin
    mktempdir() do directory
        script = "println(\"CondaR: [1/2] Installing fixture\"); println(\"compiler details\"); println(stderr, \"build stderr details\")"
        command = `$(Base.julia_cmd()) --startup-file=no -e $script`
        log = joinpath(directory, "install.log")
        display = IOBuffer()
        CondaR._run_logged(command, log; io=display, heartbeat_seconds=0)
        shown = String(take!(display))
        @test occursin("[1/2] Installing fixture", shown)
        @test !occursin("compiler details", shown)
        @test !occursin("build stderr details", shown)
        @test occursin(log, shown)
        @test occursin("compiler details", read(log, String))
        @test occursin("build stderr details", read(log, String))
        CondaR._run_logged(command, log; io=display, verbose=true, heartbeat_seconds=0)
        @test occursin("compiler details", String(take!(display)))
        failure = `$(Base.julia_cmd()) --startup-file=no -e $("println(stderr, \"specific build failure\"); exit(75)")`
        error = try
            CondaR._run_logged(failure, log; io=display, heartbeat_seconds=0)
        catch e
            e
        end
        @test error isa CondaR.InstallationError
        @test only(error.cause.procs).exitcode == 75
        @test CondaR._transport_failure(error) # preserves offline fallback classification
        @test occursin(log, sprint(showerror, error))
        @test !occursin("setenv", sprint(showerror, error))
        shown = String(take!(display))
        @test occursin("specific build failure", shown)
        @test occursin(log, shown)
        slow = `$(Base.julia_cmd()) --startup-file=no -e $("sleep(0.2)")`
        CondaR._run_logged(slow, log; io=display, heartbeat_seconds=0.05)
        @test occursin("still working", String(take!(display)))
        @test CondaR._installer_line("critical libmamba activation failed") !== nothing
        @test CondaR._installer_line("Linking gtk3-version") == "CondaR: Linking gtk3-version"
        critical = `$(Base.julia_cmd()) --startup-file=no -e $("println(stderr, \"critical libmamba Cannot activate\")")`
        @test_throws CondaR.InstallationError CondaR._run_logged(critical, log; io=display, heartbeat_seconds=0, fail_on_critical=true)
    end
end

@testset "Micromamba root reaches nested activation" begin
    parent = get(ENV, "MAMBA_ROOT_PREFIX", nothing)
    command = CondaR._micromamba_cmd(`--version`)
    root = CondaR.MicroMamba.root_dir()
    @test "MAMBA_ROOT_PREFIX=$root" in command.env
    @test get(ENV, "MAMBA_ROOT_PREFIX", nothing) == parent
    if !Sys.iswindows()
        # This call has NO -r argument, just like the shell hook's nested call.
        # It must select the Julia wrapper's root rather than ~/.local/share/mamba.
        nested = setenv(`$(CondaR.MicroMamba.executable()) --no-rc shell activate -s bash`, command.env)
        @test occursin(root, read(nested, String))
    end
end
