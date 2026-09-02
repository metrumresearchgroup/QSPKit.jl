using StoreKit
using Test

fixture_statement(path) = "include(" * repr(path) * ")\n"

@testset "IR Tracing" begin

    @testset "_is_user_file" begin
        # REPL / eval sources are not user files
        @test StoreKit._is_user_file("") == false
        @test StoreKit._is_user_file(":REPL") == false

        # Non-.jl files are not user files
        @test StoreKit._is_user_file("/some/path/file.txt") == false

        # Package files are not user files
        @test StoreKit._is_user_file(joinpath(homedir(), ".julia/packages/SomePackage/src/main.jl")) == false

        # stdlib files are not user files
        @test StoreKit._is_user_file("/usr/share/julia/stdlib/v1.12/Test/src/Test.jl") == false

        # StoreKit's own source files (canonical path) are not user files
        storekit_file = realpath(joinpath(@__DIR__, "..", "src", "store.jl"))
        if isfile(storekit_file)
            @test StoreKit._is_user_file(storekit_file) == false
        end

        # Nonexistent files are not user files
        @test StoreKit._is_user_file("/nonexistent/path/to/file.jl") == false
    end

    @testset "_find_project_root" begin
        # Should find the QSPKit root (or StoreKit's own Project.toml)
        storekit_src = joinpath(@__DIR__, "..", "src")
        root = StoreKit._find_project_root(storekit_src)
        @test root !== nothing
        @test isfile(joinpath(root, "Project.toml"))

        # Filesystem root returns nothing
        @test StoreKit._find_project_root("/") === nothing
    end

    @testset "_collect_globalrefs!" begin
        refs = Set{GlobalRef}()

        # GlobalRef is collected
        gr = GlobalRef(Main, :foo)
        StoreKit._collect_globalrefs!(refs, gr)
        @test gr in refs

        # Nested Expr
        refs2 = Set{GlobalRef}()
        gr2 = GlobalRef(Base, :println)
        expr = Expr(:call, gr2, 42)
        StoreKit._collect_globalrefs!(refs2, expr)
        @test gr2 in refs2

        # Literals are ignored
        refs3 = Set{GlobalRef}()
        StoreKit._collect_globalrefs!(refs3, 42)
        @test isempty(refs3)
    end

    @testset "_trace_fn_deps!" begin
        # Trace a known function — hash_file is defined in StoreKit itself,
        # so it should NOT appear (filtered as package code).
        deps = Dict{String,String}()
        seen = Set{UInt64}()
        StoreKit._trace_fn_deps!(deps, seen, StoreKit.hash_file)
        # hash_file is in StoreKit src — filtered out by _is_user_file
        @test isempty(deps)

        # Tracing the same function twice is a no-op (seen set)
        StoreKit._trace_fn_deps!(deps, seen, StoreKit.hash_file)
        @test isempty(deps)
    end

    @testset "_scan_deps_recursive!" begin
        mktempdir() do dir
            # Create a chain: a.jl includes b.jl includes c.jl
            write(joinpath(dir, "c.jl"), "# leaf file\n")
            write(joinpath(dir, "b.jl"), fixture_statement("c.jl"))
            write(joinpath(dir, "a.jl"), fixture_statement("b.jl"))

            deps = Dict{String,String}()
            seen = Set{String}()
            StoreKit._scan_deps_recursive!(deps, joinpath(dir, "a.jl"), seen)

            @test haskey(deps, joinpath(dir, "a.jl"))
            @test haskey(deps, joinpath(dir, "b.jl"))
            @test haskey(deps, joinpath(dir, "c.jl"))
            @test length(deps) == 3

            # Each entry has a SHA-256 hash (64 hex chars)
            for (_, h) in deps
                @test length(h) == 64
            end
        end
    end

    @testset "_scan_deps_recursive! handles cycles" begin
        mktempdir() do dir
            # Create a cycle: a.jl includes b.jl includes a.jl
            write(joinpath(dir, "a.jl"), fixture_statement("b.jl"))
            write(joinpath(dir, "b.jl"), fixture_statement("a.jl"))

            deps = Dict{String,String}()
            seen = Set{String}()
            # Should not infinite loop
            StoreKit._scan_deps_recursive!(deps, joinpath(dir, "a.jl"), seen)
            @test length(deps) == 2
        end
    end

    @testset "_discover_closure_source_deps" begin
        # A closure over nothing — should return empty deps
        f = () -> 42
        deps = StoreKit._discover_closure_source_deps(f)
        @test deps isa Dict{String,String}
        # The closure is defined in a test file, which may or may not be
        # considered a user file depending on project root detection.
        # Just verify it returns without error and returns the right type.
    end

    @testset "_is_traceable_file (reachability predicate)" begin
        @test StoreKit._is_traceable_file("") == false
        @test StoreKit._is_traceable_file("none") == false
        @test StoreKit._is_traceable_file(":REPL") == false
        @test StoreKit._is_traceable_file(joinpath(homedir(), ".julia", "packages", "Foo", "ab12", "src", "Foo.jl")) == false
        @test StoreKit._is_traceable_file("/usr/share/julia/stdlib/v1.13/Random/src/Random.jl") == false
        # A project-local file is traceable...
        @test StoreKit._is_traceable_file(@__FILE__) == true
        # ...AND a dev'd sibling-package source file is too (KEY diff vs _is_user_file).
        sibling = joinpath(dirname(dirname(@__DIR__)), "BookKit", "src", "book.jl")
        @test StoreKit._is_traceable_file(sibling) == true
    end

    @testset "source_fingerprint (per-method)" begin
        # A "helpers file": used `sfbar`, UNUSED `sfbaz`, and a driver calling sfbar.
        @eval module _SFTest
            sfbar(x) = 2x + 1
            sfbaz(x) = x^2 + 99       # not referenced by sfdriver
            sfdriver(x) = sfbar(x) + 7
        end

        fp = StoreKit.source_fingerprint(_SFTest.sfdriver)
        @test fp isa Dict{String,String}
        @test any(k -> occursin("sfdriver", k), keys(fp))   # self
        @test any(k -> occursin("sfbar", k), keys(fp))      # reached callee
        @test !any(k -> occursin("sfbaz", k), keys(fp))     # unused sibling NOT reached

        c1 = StoreKit.combined_fingerprint(_SFTest.sfdriver)
        @test StoreKit.combined_fingerprint(_SFTest.sfdriver) == c1   # determinism

        # THE requirement: editing the UNUSED sibling does not move the fingerprint
        @eval _SFTest sfbaz(x) = x^3 - 12345
        @test StoreKit.combined_fingerprint(_SFTest.sfdriver) == c1

        # change-sensitivity: editing the USED callee does
        @eval _SFTest sfbar(x) = 5x - 2
        c2 = StoreKit.combined_fingerprint(_SFTest.sfdriver)
        @test c2 != c1
        # determinism across identical redefinition
        @eval _SFTest sfbar(x) = 5x - 2
        @test StoreKit.combined_fingerprint(_SFTest.sfdriver) == c2
    end

    @testset "source_fingerprint handles @generated" begin
        @eval module _SFGen
            @generated function sfgen(x)
                return :(x + 1)
            end
            sfgen_caller(x) = sfgen(x) * 2
        end
        # Must not throw (Base.uncompressed_ast throws on @generated — handled).
        @test StoreKit.combined_fingerprint(_SFGen.sfgen_caller) isa String
        fp = StoreKit.source_fingerprint(_SFGen.sfgen_caller)
        @test any(k -> occursin("sfgen", k), keys(fp))
    end

end
