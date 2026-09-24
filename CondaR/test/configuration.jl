@testset "OS and architecture isolation" begin
    platforms = [CondaR._platform(; kernel, arch, machine="fixture") for
        (kernel,arch) in [(:Linux,:x86_64), (:Linux,:aarch64), (:Darwin,:x86_64), (:Darwin,:aarch64), (:NT,:x86_64)]]
    @test getproperty.(platforms, :subdir) == ["linux-64", "linux-aarch64", "osx-64", "osx-arm64", "win-64"]
    @test length(CondaR._path_id("a"^64, last(platforms))) == 20
    @test CondaR._path_id("a"^64, first(platforms)) == "a"^64
    @test_throws r"no managed R/toolchain" CondaR._platform(kernel=:NT, arch=:aarch64)
    @test_throws r"no managed R/toolchain" CondaR._platform(kernel=:Linux, arch=:i686)
    @test_throws r"no managed R/toolchain" CondaR._platform(kernel=:FreeBSD, arch=:x86_64)
    @test_throws r"no managed R/toolchain" CondaR._platform(kernel=:Linux, arch=:x86_64, machine="x86_64-linux-musl")
    for p in platforms
        deps = CondaR._native_requirements(p)["deps"]
        @test deps["r-base"] == ">=4.5,<5"
        @test haskey(deps, "zlib") && haskey(deps, "pandoc")
        @test haskey(deps, "libxml2-devel")
        @test p.os != "osx" || haskey(deps, "libintl-devel")
        @test haskey(deps, "c-compiler") == (p.os != "win")
        @test haskey(deps, "gcc_win-64") == (p.os == "win")
        @test haskey(deps, "xorg-xorgproto") == (p.os == "linux")
        e = CondaR._r_environment("prefix", "private-library"; platform=p)
        @test e["R_LIBS_USER"] == "private-library"
        @test e["R_PROFILE_USER"] == (p.os == "win" ? "NUL" : "/dev/null")
        @test e["R_HOME"] == CondaR._rhome("prefix", p)
        @test e["PKG_CONFIG_PATH"] == e["PKG_CONFIG_LIBDIR"]
        @test !occursin("/usr", e["PKG_CONFIG_PATH"])
        if p.os == "win"
            @test endswith(CondaR._rscript("prefix", p), joinpath("Scripts", "Rscript.exe"))
            @test endswith(CondaR._libr(e["R_HOME"], p), joinpath("bin", "x64", "R.dll"))
            @test joinpath("prefix", "Library", "bin") in split(e["PATH"], ';')
        else
            @test endswith(CondaR._rscript("prefix", p), joinpath("lib", "R", "bin", "Rscript"))
            @test endswith(CondaR._libr(e["R_HOME"], p), p.os == "osx" ? ".dylib" : ".so")
        end
    end
end

@testset "Project policy and preferences" begin
    mktempdir() do root
        write(joinpath(root, "Project.toml"), "[preferences.CondaR]\nmode = \"latest\"\n")
        @test CondaR._mode(root) == :latest
        @test !CondaR._verbose(root)
        write(joinpath(root, "LocalPreferences.toml"), "[CondaR]\nmode = \"project\"\n[Unrelated]\nkeep = true\n")
        @test CondaR._mode(root) == :project
        @test CondaR._configuration(root)["mode"] == "latest"
        yaml = """
        Version: 1
        Packages: [mrggsave, example]
        Repos:
          - snapshot: https://example.org/snapshot/1
          - fallback: https://example.org/latest
        Customizations:
          Packages:
            - example: {Repo: snapshot, Type: source, Suggests: true, Env: {FLAG: 'value'}}
        Rpath: /unrelated/R
        Lockfile: {Type: renv}
        """
        path = joinpath(root, "pkgr.yml")
        write(path, yaml)
        policy = CondaR._configuration(root)
        @test policy["mode"] == "project"
        @test policy["repos"][1]["name"] == "snapshot"
        @test !("example" in policy["packages"])
        @test Set(policy["packages"]) == Set(CondaR._REQUIRED_PACKAGES)
        @test policy["package_options"]["example"]["Env"]["FLAG"] == "value"
        @test !haskey(policy, "Rpath")
        original = CondaR._fingerprint(policy)
        write(path, replace(yaml, "Packages: [mrggsave, example]" => "Packages: [mrggsave, example, unrelated]"))
        @test CondaR._fingerprint(CondaR._configuration(root)) == original
        write(path, replace(yaml, "snapshot/1" => "snapshot/2"))
        @test CondaR._fingerprint(CondaR._configuration(root)) != original
        write(path, replace(yaml, "Type: source" => "Type: binary"))
        @test_throws r"Type: source only" CondaR._configuration(root)
        @test CondaR._configuration(root, :latest)["packages"] == CondaR._REQUIRED_PACKAGES
        write(path, "this is not valid: [yaml")
        @test CondaR._configuration(root, :latest)["mode"] == "latest"
        @test_throws ArgumentError CondaR._configuration(root, :invalid)
        @test read(joinpath(root, "LocalPreferences.toml"), String) == "[CondaR]\nmode = \"project\"\n[Unrelated]\nkeep = true\n"
    end
end

@testset "RCall preferences remain local" begin
    mktempdir() do root
        project_file = joinpath(root, "Project.toml")
        project_text = """
        [deps]
        CondaR = "02826c15-4b38-49f8-b478-6f46c11e7393"

        [extras]
        RCall = "6f49c342-dc21-5d91-9882-a32aef131414"
        """
        write(project_file, project_text)
        rhome = joinpath(root, "runtime", "lib", "R")
        libr = CondaR._libr(rhome)
        mkpath(dirname(libr))
        write(libr, "fixture")

        CondaR._set_rcall_preferences!(root, (; rhome))

        @test read(project_file, String) == project_text
        preferences = CondaR.TOML.parsefile(joinpath(root, "LocalPreferences.toml"))
        @test preferences["RCall"]["Rhome"] == rhome
        @test preferences["RCall"]["libR"] == libr
        merged = Base.recursive_prefs_merge(
            Dict{String,Any}(),
            Base.collect_preferences(
                project_file,
                Base.UUID("6f49c342-dc21-5d91-9882-a32aef131414"),
            ),
        )
        @test merged["Rhome"] == rhome
        @test merged["libR"] == libr
    end
end

@testset "RCall preferences have a resolvable project identity" begin
    mktempdir() do root
        project_file = joinpath(root, "Project.toml")
        write(project_file,
            "[deps]\nCondaR = \"02826c15-4b38-49f8-b478-6f46c11e7393\"\n")
        rhome = joinpath(root, "runtime", "lib", "R")
        libr = CondaR._libr(rhome)
        mkpath(dirname(libr))
        write(libr, "fixture")

        CondaR._set_rcall_preferences!(root, (; rhome))

        project = CondaR.TOML.parsefile(project_file)
        @test project["extras"]["RCall"] ==
            "6f49c342-dc21-5d91-9882-a32aef131414"
        preferences = CondaR.TOML.parsefile(joinpath(root, "LocalPreferences.toml"))
        @test preferences["RCall"]["Rhome"] == rhome
        @test preferences["RCall"]["libR"] == libr
    end
end

@testset "Managed R preparation precedes RCall import" begin
    mktempdir() do root
        write(joinpath(root, "Project.toml"), "[deps]\n")
        runtime = joinpath(root, "runtime")
        library = joinpath(root, "library")
        rhome = CondaR._rhome(runtime)
        libr = CondaR._libr(rhome)
        mkpath(dirname(libr))
        write(libr, "fixture")
        prepared = (; runtime, library, rhome)
        calls = String[]
        provision(actual_root, mode) = begin
            push!(calls, "prepare:$mode:$actual_root")
            prepared
        end
        ensure_tex() = push!(calls, "tex")
        old_active = CondaR._ACTIVE[]
        try
            withenv(
                "R_HOME" => nothing,
                "R_LIBS" => nothing,
                "R_LIBS_USER" => nothing,
                "R_LIBS_SITE" => nothing,
                "KMP_DUPLICATE_LIB_OK" => nothing,
            ) do
                result = CondaR._prepare_rcall!(
                    root, :project; prepare=provision, ensure_tex)
                @test result === prepared
                @test calls == ["prepare:project:$root", "tex"]
                @test CondaR._ACTIVE[] === prepared
                @test ENV["R_HOME"] == rhome
                @test ENV["R_LIBS_USER"] == library
                @test ENV["KMP_DUPLICATE_LIB_OK"] == "TRUE"
                preferences = CondaR.TOML.parsefile(
                    joinpath(root, "LocalPreferences.toml"))
                @test preferences["RCall"]["Rhome"] == rhome
                @test preferences["RCall"]["libR"] == libr
            end
        finally
            CondaR._ACTIVE[] = old_active
        end
    end
end

@testset "RCall is precompiled before import" begin
    id = Base.PkgId(Base.UUID("6f49c342-dc21-5d91-9882-a32aef131414"), "RCall")
    compiled = Base.PkgId[]
    record(pkg) = (push!(compiled, pkg); ("cache.ji", nothing))
    @test !CondaR._precompile_rcall!(id; isprecompiled=_ -> true, compilecache=record)
    @test isempty(compiled)
    @test CondaR._precompile_rcall!(id; isprecompiled=_ -> false, compilecache=record)
    @test compiled == [id]
    declined = _ -> Base.PrecompilableError()
    @test_throws ErrorException CondaR._precompile_rcall!(
        id; isprecompiled=_ -> false, compilecache=declined)
end

@testset "Project-owned native and R resolutions" begin
    mktempdir() do root
        write(joinpath(root, "Project.toml"), "[deps]\n")
        yaml = "Version: 1\nPackages: [example]\nRepos:\n  - snapshot: https://example.org/1\n"
        write(joinpath(root, "pkgr.yml"), yaml)
        cache = joinpath(root, "cache")
        calls = String[]
        version, native_version = Ref("1.0"), Ref("4.5.3")
        fail_install, fail_build, fail_validation = Ref(false), Ref(false), Ref(false)
        resolve_failure, native_failure = Ref(0), Ref(0)
        fail(code) = code == 0 || run(`$(Base.julia_cmd()) --startup-file=no -e $("exit(" * string(code) * ")")`)
        resolver = function(directory; refresh)
            push!(calls, refresh ? "native-refresh" : "native-resolve")
            fail(native_failure[])
            native_fixture(native_version[])
        end
        installer = function(runtime, resolution)
            CondaR._atomic_toml(joinpath(runtime, "condar-native.toml"), resolution)
        end
        worker = function(runtime, library, action, cfg, plan)
            push!(calls, action)
            if action == "resolve"
                fail(resolve_failure[])
                write(plan, version[])
                write(plan * ".tsv", version[])
                write(plan * ".build", "example")
            elseif action == "install"
                fail_install[] && error("deliberate installation failure")
                write(joinpath(library, "installed"), read(plan, String))
            elseif action == "validate"
                fail_validation[] && error("deliberate validation failure")
                @test read(joinpath(library, "installed"), String) == read(plan, String)
            end
        end
        checker(runtime) = fail_build[] ? error("deliberate SDK failure") : nothing
        prepare(mode; refresh=false) = CondaR._prepare(root, mode; refresh, cache,
            native_resolver=resolver, runtime_installer=installer, attester=((args...) -> Dict()),
            worker, build_checker=checker)
        pointer(env) = CondaR.TOML.parsefile(joinpath(dirname(dirname(env.library)), "current.toml"))
        first = prepare(:project)
        @test calls == ["native-resolve", "resolve", "select", "install", "validate"]
        empty!(calls)
        @test prepare(:project) == first
        @test isempty(calls)
        empty!(CondaR._PREPARED) # another Julia session: no solver or R worker
        @test prepare(:project) == first
        @test isempty(calls)
        empty!(calls)
        @test prepare(:project; refresh=true) == first # same solution, no reinstall
        @test calls == ["native-refresh", "resolve", "select", "validate"]
        fail_validation[] = true
        @test_throws r"deliberate validation" prepare(:project; refresh=true)
        @test pointer(first)["library"] == first.library
        fail_validation[] = false
        # Recover an interruption before publishing the current pointer.
        statefile = joinpath(dirname(dirname(first.library)), "current.toml")
        planpath = pointer(first)["plan"]
        rm(planpath * ".tsv")
        rm(statefile)
        empty!(CondaR._PREPARED)
        empty!(calls)
        @test prepare(:project) == first
        @test calls == ["native-resolve", "resolve", "select", "validate"]
        @test read(planpath * ".tsv", String) == "1.0"
        # Native updates alone require a separate library, never copied source builds.
        native_version[] = "4.5.4"
        second = prepare(:project; refresh=true)
        @test second.runtime != first.runtime && second.library != first.library
        @test pointer(second)["runtime"] == second.runtime
        @test isfile(joinpath(first.library, "installed"))
        # A policy change can upgrade or downgrade independently.
        version[] = "2.0"
        write(joinpath(root, "pkgr.yml"), replace(yaml, "org/1" => "org/2"))
        third = prepare(:project)
        @test third.library != second.library && third.runtime == second.runtime
        write(joinpath(root, "pkgr.yml"), yaml)
        @test prepare(:project).library == second.library
        latest = prepare(:latest)
        @test read(joinpath(latest.library, "installed"), String) == "2.0"
        # Latest still refreshes metadata each session, but an unchanged published
        # library needs neither installation nor another namespace validation.
        empty!(CondaR._PREPARED)
        empty!(calls)
        @test prepare(:latest) == latest
        @test calls == ["native-refresh", "resolve", "select"]
        version[], native_version[] = "3.0", "4.5.5"
        fail_install[] = true
        @test_throws r"deliberate installation" prepare(:latest; refresh=true)
        @test pointer(latest)["library"] == latest.library
        @test pointer(latest)["runtime"] == latest.runtime
        fail_install[], fail_build[] = false, true
        @test_throws r"deliberate SDK" prepare(:latest; refresh=true)
        @test pointer(latest)["library"] == latest.library
        fail_build[] = false
        updated = prepare(:latest; refresh=true)
        @test updated.library != latest.library && updated.runtime != latest.runtime
        # Transport failures may retain a validated latest environment. Other errors may not.
        resolve_failure[] = 75
        @test_logs (:warn, r"repository refresh failed") begin
            @test prepare(:latest; refresh=true).library == updated.library
        end
        resolve_failure[] = 1
        @test_throws ProcessFailedException prepare(:latest; refresh=true)
        resolve_failure[], native_failure[] = 0, 75
        @test_logs (:warn, r"native repository refresh failed") begin
            @test prepare(:latest; refresh=true).runtime == updated.runtime
        end
        native_failure[] = 1
        @test_throws ProcessFailedException prepare(:latest; refresh=true)
        @test pointer(updated)["library"] == updated.library
        @test read(joinpath(root, "pkgr.yml"), String) == yaml
        @test CondaR._cache_root(root) != CondaR._cache_root(dirname(root))
    end
end

@testset "Switching persists and defers loaded R" begin
    mktempdir() do root
        write(joinpath(root, "Project.toml"), "[deps]\n")
        write(joinpath(root, "LocalPreferences.toml"), "[Unrelated]\nkeep = true\n")
        prepared = (; runtime="runtime", library="latest-library")
        provision(root, mode; refresh) = prepared
        result = CondaR._configure!(root, :latest; prepare=provision, active=nothing)
        @test !result.restart_required
        @test CondaR._mode(root) == :latest
        CondaR._configure!(root, :latest; prepare=provision, active=nothing, verbose=true)
        @test CondaR._verbose(root)
        CondaR._configure!(root, :latest; prepare=provision, active=nothing)
        @test CondaR._verbose(root) # omitted setting is preserved
        before = CondaR._fingerprint(CondaR._configuration(root))
        CondaR._configure!(root, :latest; prepare=provision, active=nothing, verbose=false)
        @test !CondaR._verbose(root)
        @test CondaR._fingerprint(CondaR._configuration(root)) == before
        @test CondaR.TOML.parsefile(joinpath(root,"LocalPreferences.toml"))["Unrelated"]["keep"]
        active = (; runtime="runtime", library="project-library")
        result = CondaR._configure!(root, :latest; prepare=provision, active)
        @test result.restart_required
        @test active.library == "project-library"
        @test !CondaR._configure!(root, :latest; prepare=provision, active=prepared).restart_required
        broken(root, mode; refresh) = error("fixture failure")
        @test_throws r"fixture failure" CondaR._configure!(root, :project; prepare=broken, active)
        @test CondaR._mode(root) == :project
        @test_throws ArgumentError CondaR._configure!(root, :bad; prepare=provision)
        @test CondaR._mode(root) == :project
    end
end
