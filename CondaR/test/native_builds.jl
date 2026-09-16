# Opt-in, real source-build regression on the host OS/CPU. See README.
using CondaR, Test
C = CondaR
cache = mktempdir()
resolution = isempty(ARGS) ? C._resolve_native(cache) : C.TOML.parsefile(joinpath(abspath(ARGS[1]), "condar-native.toml"))
runtime = isempty(ARGS) ? C._runtime_path(cache, resolution) : abspath(ARGS[1])
repo = length(ARGS) >= 2 ? ARGS[2] : "https://cloud.r-project.org"
C._ensure_runtime(runtime, resolution)
C._ensure_build_tools(runtime)

@testset "Managed native source builds" begin
    mktempdir() do directory
        # Missing development files must fail before any compiler or host
        # pkg-config can accidentally make an incomplete runtime look usable.
        check = joinpath(dirname(pathof(C)), "native_check.R")
        command = C._micromamba_cmd(`--no-rc run -p $runtime $(C._rscript(runtime)) --vanilla $check $directory`)
        log = joinpath(directory, "missing.log")
        @test_throws C.InstallationError C._run_logged(addenv(command, C._r_environment(runtime, "")), log)
        @test occursin("libxml2", read(log, String))
        @test occursin("runtime packaging failure", read(log, String))

        config = Dict("suggests" => false, "repos" => [Dict("name" => "test", "url" => repo)],
            "packages" => ["xml2", "pdftools"], "package_options" => Dict(),
            "repo_options" => Dict(), "github_packages" => String[])
        config_file = joinpath(directory, "config.R")
        write(config_file, "config <- " * C._r_literal(config) * "\n")
        plan = joinpath(directory, "plan.rds")
        library = mkpath(joinpath(directory, "library"))
        C._run_worker(runtime, library, "resolve", config_file, plan)
        C._run_worker(runtime, library, "install", config_file, plan)
        C._run_worker(runtime, library, "validate", config_file, plan)
        @test isfile(joinpath(library, "xml2", "DESCRIPTION"))
        @test isfile(joinpath(library, "pdftools", "DESCRIPTION"))
        C._run_worker(runtime, library, "install", config_file, plan)
        logs = [joinpath(directory, "logs", f) for f in readdir(joinpath(directory, "logs")) if startswith(f, "install-")]
        @test any(f -> occursin("Reusing xml2", read(f, String)), logs)
        @test any(f -> occursin("Reusing pdftools", read(f, String)), logs)
    end
end
