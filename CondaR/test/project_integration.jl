# Opt-in clean consumer check, run from the CondaR/test Julia environment.
using Pkg, Test
root = realpath(mktempdir())
Pkg.activate(root)
Pkg.develop(path=dirname(@__DIR__))
Pkg.instantiate()
cp(joinpath(@__DIR__, "fixtures", "mpn", "pkgr.yml"), joinpath(root, "pkgr.yml"))
using QSPKit.CondaR

@testset "MPN policy with current compatible native packages" begin
    @test CondaR._R_MODULE[] === nothing
    # Ordinary R use must perform all setup without a configure!/setup call.
    @test rcopy(Int, reval("1L + 1L")) == 2
    @test rcopy(String, reval("as.character(packageVersion('ggplot2'))")) == "4.0.3"
    @test rcopy(String, reval("as.character(packageVersion('pdftools'))")) == "3.9.0"
    @test rcopy(String, reval("as.character(packageVersion('mrggsave'))")) == "0.4.7"
    @test !isdir(joinpath(CondaR.r_libdir(), "not-a-showkit-dependency"))
    @test realpath(first(rcopy(Vector{String}, reval(".libPaths()")))) == realpath(CondaR.r_libdir())
    plan = read(joinpath(CondaR.r_libdir(), "condar-plan.rds.tsv"), String)
    @test occursin("\t\"binary\"\t", plan)
    @test occursin("\t\"MPN\"\t", plan)
    plot = reval("ggplot2::ggplot(data.frame(x=1:3, y=3:1), ggplot2::aes(x,y)) + ggplot2::geom_point()")
    rcall(reval("mrggsave::mrggsave"), plot; stem="managed", dir=root,
          dev=["png"], type="cairo-png", script="project_integration.jl",
          var"path.type"="none")
    @test filesize(joinpath(root, "managed.png")) > 100
end

# Exercise policy ordering, source checksum checks, overrides and resumption
# in separate R workers, including expected failures with visible diagnostics.
runtime = CondaR._ACTIVE[].runtime
resolution = CondaR.TOML.parsefile(joinpath(runtime, "condar-native.toml"))
@test CondaR._validate_resolution(resolution) == resolution
# Ordinary reuse starts no installer/validation workers, even in another session.
logs = joinpath(dirname(dirname(CondaR.r_libdir())), "logs")
previous_logs = readdir(logs)
empty!(CondaR._PREPARED)
@test CondaR._prepare(root, :project) == CondaR._ACTIVE[]
@test readdir(logs) == previous_logs
worker = joinpath(dirname(pathof(CondaR)), "provision.R")
fixture = joinpath(@__DIR__, "provisioning.R")
command = CondaR._micromamba_cmd(`--no-rc run -p $runtime $(CondaR._rscript(runtime)) --vanilla $fixture $worker`)
CondaR._run_logged(addenv(command, CondaR._r_environment(runtime, "")), joinpath(root, "policy-tests.log"); label="Repository policy tests")

# The same runtime must support selected sources not present in its binary
# catalog, including the xml2 link regression. Run in another Julia process.
run(`$(Base.julia_cmd()) --startup-file=no --project=$root $(joinpath(@__DIR__, "native_builds.jl")) $runtime https://mpn.metworx.com/snapshots/stable/2026-08-24`)
