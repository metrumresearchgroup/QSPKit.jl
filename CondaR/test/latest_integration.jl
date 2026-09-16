# Opt-in live current-upstream check, with no dependence on the caller's policy.
using CondaR, Test
mktempdir() do root
    write(joinpath(root, "Project.toml"), "[deps]\n")
    write(joinpath(root, "pkgr.yml"), "invalid YAML: [must be ignored")
    @test CondaR._R_MODULE[] === nothing
    prepared = CondaR._prepare(root, :latest)
    @test prepared.effective_mode == :latest
    plan = CondaR.JSON.parsefile(joinpath(prepared.library, "condar-plan.rds.json"))
    @test all(p -> p["Repository"] == "CRAN" || p["Repository"] == "GitHub", plan)
    @test all(p -> !isempty(p["Commit"]), filter(p -> p["Repository"] == "GitHub", plan))
    @test !occursin("MPN", read(joinpath(prepared.library, "condar-plan.rds.tsv"), String))
    previous = read(joinpath(prepared.runtime, "condar-native.toml"))
    refreshed = CondaR._prepare(root, :latest; refresh=true)
    # Upstream can change during the test. Reuse is required when the solutions match.
    if read(joinpath(refreshed.runtime, "condar-native.toml")) == previous &&
       read(joinpath(refreshed.library, "condar-plan.rds.tsv")) == read(joinpath(prepared.library, "condar-plan.rds.tsv"))
        @test refreshed.library == prepared.library && refreshed.runtime == prepared.runtime
    end
    @test read(joinpath(prepared.runtime, "condar-native.toml")) == previous
    @test CondaR._R_MODULE[] === nothing
    println("Latest native/R policy and explicit refresh verified")
end
