function native_fixture(version="4.5.3")
    Dict("format" => 1, "platform" => CondaR._platform().subdir,
         "host" => CondaR._host_identity(), "artifacts" => [
             Dict("name" => "r-base", "version" => version, "build" => "fixture_0",
                  "url" => "https://conda.anaconda.org/conda-forge/$(CondaR._platform().subdir)/r-base-$version-fixture_0.conda",
                  "sha256" => repeat("a", 64))])
end

@testset "Native resolution identity and verification" begin
    resolution = native_fixture()
    @test CondaR._validate_resolution(resolution) == resolution
    @test startswith(CondaR._explicit_spec(resolution), "@EXPLICIT\n")
    @test occursin("#" * repeat("a", 64), CondaR._explicit_spec(resolution))
    @test CondaR._runtime_path("cache", resolution) != CondaR._runtime_path("cache", native_fixture("4.5.4"))
    for (key, value, message) in (("platform", "foreign", "OS/architecture"),
                                  ("host", Dict("machine" => "foreign"), "host ABI"),
                                  ("format", 999, "format"))
        @test_throws Regex(message) CondaR._validate_resolution(merge(resolution, Dict(key => value)))
    end
    bad = deepcopy(resolution)
    bad["artifacts"][1]["sha256"] = ""
    @test_throws r"SHA256" CondaR._validate_resolution(bad)
    bad["artifacts"][1]["sha256"] = repeat("a", 64)
    bad["artifacts"][1]["url"] = "https://other.example/package.conda"
    @test_throws r"provider" CondaR._validate_resolution(bad)
    bad = deepcopy(resolution)
    bad["artifacts"][1]["url"] = "https://conda.anaconda.org/conda-forge/foreign/r-base.conda"
    @test_throws r"OS/architecture" CondaR._validate_resolution(bad)
    bad = deepcopy(resolution)
    push!(bad["artifacts"], copy(first(bad["artifacts"])))
    @test_throws r"Duplicate" CondaR._validate_resolution(bad)
end

@testset "Source bytes control binary reuse" begin
    mktempdir() do directory
        runtime = mkpath(joinpath(directory, "runtime"))
        plan = joinpath(directory, "plan")
        bytes = "selected upstream source archive"
        sha = bytes2hex(CondaR.SHA.sha256(bytes))
        md5 = bytes2hex(CondaR.MD5.md5(bytes))
        catalog = Dict("example" => Dict("version" => "1.0", "source_sha256" => sha,
            "artifact" => "https://conda.anaconda.org/conda-forge/noarch/example.conda", "patches" => String[]))
        CondaR._atomic_toml(joinpath(runtime, "condar-binaries.toml"), catalog)
        record = Dict{String,Any}("Package" => "example", "Version" => "1.0", "BinaryAllowed" => true,
            "MD5sum" => md5, "TarURL" => "https://example.org/MPN/example_1.0.tar.gz", "Repository" => "MPN")
        downloads = String[]
        downloader(url, dest) = (push!(downloads, url); write(dest, bytes))
        function attest(rec=record)
            write(plan * ".json", CondaR.JSON.json([rec]))
            CondaR._attest_sources(runtime, plan, directory; downloader)
        end
        verified = attest()
        @test verified["example"]["source_md5"] == md5
        @test verified["example"]["source_url"] == record["TarURL"]
        @test downloads == [record["TarURL"]]
        @test attest() == verified && length(downloads) == 1
        @test isempty(attest(merge(record, Dict("Version" => "2.0"))))
        @test isempty(attest(merge(record, Dict("BinaryAllowed" => false))))
        @test length(downloads) == 1
        @test attest(merge(record, Dict("MD5sum" => ""))) == verified
        @test length(downloads) == 2 # without repository MD5, refresh retrieves selected bytes
        @test_throws r"Repository source checksum mismatch" attest(merge(record, Dict("MD5sum" => repeat("b", 32))))
        catalog["example"]["source_sha256"] = repeat("c", 64)
        CondaR._atomic_toml(joinpath(runtime, "condar-binaries.toml"), catalog)
        @test_logs (:info, r"binary source differs") @test isempty(attest())
        @test !isfile(joinpath(directory, "sources", repeat("c", 64) * ".tar.gz"))
    end
end
