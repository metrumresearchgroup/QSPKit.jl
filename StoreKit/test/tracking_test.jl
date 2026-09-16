using StoreKit
using Test

# ═══ File Tracking Tests ═══

@testset "File Tracking" begin

    @testset "catches plain file reads via open()" begin
        StoreKit.clear_file_reads!()
        mktempdir() do dir
            path = joinpath(dir, "test.txt")
            write(path, "hello")

            content = open(path, "r") do f
                read(f, String)
            end

            @test content == "hello"
            @test any(fr -> fr.path == abspath(path), StoreKit.FILE_READS)
        end
    end

    @testset "catches open() with default mode" begin
        StoreKit.clear_file_reads!()
        mktempdir() do dir
            path = joinpath(dir, "test2.txt")
            write(path, "world")

            content = open(read, path)

            @test any(fr -> fr.path == abspath(path), StoreKit.FILE_READS)
        end
    end

    @testset "forwards keyword-only open modes" begin
        StoreKit.clear_file_reads!()
        mktempdir() do dir
            path = joinpath(dir, "keyword-output.txt")

            open(path; write=true, create=true, truncate=true) do io
                write(io, "keyword output")
            end

            entry = only(filter(fr -> fr.path == abspath(path), StoreKit.FILE_READS))
            @test entry.mode == "w"
            @test StoreKit._is_read_mode(entry.mode) == false
            @test read(path, String) == "keyword output"
        end
    end

    @testset "catches write mode" begin
        StoreKit.clear_file_reads!()
        mktempdir() do dir
            path = joinpath(dir, "output.txt")

            open(path, "w") do f
                write(f, "output data")
            end

            # A write open is still LOGGED (with mode "w") ...
            entry = only(filter(fr -> fr.path == abspath(path), StoreKit.FILE_READS))
            @test entry.mode == "w"
            # ... but is flagged as not-a-read so attribution can drop it.
            @test StoreKit._is_read_mode(entry.mode) == false
        end
    end

    @testset "records open mode" begin
        StoreKit.clear_file_reads!()
        mktempdir() do dir
            rpath = joinpath(dir, "in.txt"); write(rpath, "x")
            wpath = joinpath(dir, "out.txt")

            # Clear the setup write (which itself opens rpath in "w" mode) so we
            # only observe the opens under test.
            StoreKit.clear_file_reads!()
            open(rpath, "r") do f; read(f, String); end
            open(wpath, "w") do f; write(f, "y"); end

            reads = get_file_reads()
            rentry = only(filter(fr -> fr.path == abspath(rpath), reads))
            wentry = only(filter(fr -> fr.path == abspath(wpath), reads))
            @test rentry.mode == "r"
            @test wentry.mode == "w"
        end
    end

    @testset "_is_read_mode predicate" begin
        for m in ("r", "", "rb", "rt", "R")
            @test StoreKit._is_read_mode(m) == true
        end
        for m in ("w", "a", "w+", "a+", "r+", "rb+")
            @test StoreKit._is_read_mode(m) == false
        end
    end

    @testset "tags with expression ID" begin
        mktempdir() do dir
            path = joinpath(dir, "tagged.txt")
            write(path, "data")

            # Clear after write so we only see the read
            StoreKit.clear_file_reads!()

            # Simulate expression ID being set (as ast_transforms would do)
            StoreKit._CURRENT_EXPR_ID[] = 42
            open(path, "r") do f
                read(f, String)
            end
            StoreKit._CURRENT_EXPR_ID[] = 0

            tagged = filter(fr -> fr.path == abspath(path), StoreKit.FILE_READS)
            @test length(tagged) == 1
            @test tagged[1].expr_id == 42
        end
    end

    @testset "catches include()-triggered reads" begin
        StoreKit.clear_file_reads!()
        mktempdir() do dir
            jl_path = joinpath(dir, "included.jl")
            write(jl_path, "_storekit_test_included = true\n")

            include(jl_path)

            @test any(fr -> fr.path == abspath(jl_path), StoreKit.FILE_READS)
        end
    end

    @testset "catches nested include() chains" begin
        StoreKit.clear_file_reads!()
        mktempdir() do dir
            inner_path = joinpath(dir, "inner.jl")
            write(inner_path, "_storekit_inner_loaded = true\n")

            outer_path = joinpath(dir, "outer.jl")
            write(outer_path, "include(\"$(escape_string(inner_path))\")\n_storekit_outer_loaded = true\n")

            include(outer_path)

            @test any(fr -> fr.path == abspath(outer_path), StoreKit.FILE_READS)
            @test any(fr -> fr.path == abspath(inner_path), StoreKit.FILE_READS)
        end
    end

    @testset "get_file_reads returns copy" begin
        StoreKit.clear_file_reads!()
        reads = get_file_reads()
        @test reads isa Vector
        @test isempty(reads)
        # Mutating the copy should not affect the original
        push!(reads, (path="fake", expr_id=0, mode="r"))
        @test isempty(StoreKit.FILE_READS)
    end

    @testset "clear_file_reads! empties log" begin
        mktempdir() do dir
            path = joinpath(dir, "to_clear.txt")
            write(path, "data")
            open(path, "r") do f; read(f, String); end
            @test !isempty(StoreKit.FILE_READS)
            StoreKit.clear_file_reads!()
            @test isempty(StoreKit.FILE_READS)
        end
    end
end

# ═══ Session Log Tests ═══

@testset "Session Log" begin

    @testset "SessionEntry stores defs and refs" begin
        entry = StoreKit.SessionEntry(1, Set([:x, :y]), Set([:a, :b]))
        @test entry.id == 1
        @test :x in entry.defs
        @test :y in entry.defs
        @test :a in entry.refs
        @test :b in entry.refs
    end

    @testset "clear_session_log! resets state" begin
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(1, Set([:x]), Set{Symbol}()))
        StoreKit._EXPR_COUNTER[] = 10
        StoreKit._CURRENT_EXPR_ID[] = 5

        StoreKit.clear_session_log!()

        @test isempty(StoreKit.SESSION_LOG)
        @test StoreKit._EXPR_COUNTER[] == 0
        @test StoreKit._CURRENT_EXPR_ID[] == 0
    end

    @testset "get_session_log returns copy" begin
        StoreKit.clear_session_log!()
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(1, Set([:x]), Set([:y])))
        log = get_session_log()
        @test length(log) == 1
        # Mutating the copy should not affect the original
        empty!(log)
        @test length(StoreKit.SESSION_LOG) == 1
        StoreKit.clear_session_log!()
    end

    @testset "manual session log population" begin
        StoreKit.clear_session_log!()

        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(1, Set([:data]), Set{Symbol}()))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(2, Set([:config]), Set{Symbol}()))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(3, Set([:result]), Set([:data, :config])))

        @test length(StoreKit.SESSION_LOG) == 3
        @test StoreKit.SESSION_LOG[1].defs == Set([:data])
        @test StoreKit.SESSION_LOG[3].refs == Set([:data, :config])

        StoreKit.clear_session_log!()
    end
end

# ═══ Attribution Engine Tests ═══

@testset "Attribution" begin

    @testset "files_for_result walks dependency chain (MU2/MU3)" begin
        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()

        # Simulate a scientist session:
        # expr 1: data = CSV.read("fig4.csv")
        # expr 2: other = CSV.read("fig_supp1.csv")
        # expr 3: config = YAML.load("keyfile.yml")
        # expr 4: targets = process(data)
        # expr 5: mu2_result = fit(targets, config)
        # expr 6: mu3_result = fit(other, config)

        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(1, Set([:data]), Set{Symbol}()))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(2, Set([:other]), Set{Symbol}()))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(3, Set([:config]), Set{Symbol}()))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(4, Set([:targets]), Set([:data])))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(5, Set([:mu2_result]), Set([:targets, :config])))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(6, Set([:mu3_result]), Set([:other, :config])))

        push!(StoreKit.FILE_READS, (path="/data/fig4.csv", expr_id=1, mode="r"))
        push!(StoreKit.FILE_READS, (path="/data/fig_supp1.csv", expr_id=2, mode="r"))
        push!(StoreKit.FILE_READS, (path="/data/keyfile.yml", expr_id=3, mode="r"))

        # MU2: should include fig4.csv and keyfile.yml, exclude fig_supp1.csv
        result2 = files_for_result(:mu2_result)
        @test "/data/fig4.csv" in result2.data_files
        @test !("/data/fig_supp1.csv" in result2.data_files)
        @test "/data/keyfile.yml" in result2.data_files
        @test result2.expr_ids == Set([1, 3, 4, 5])

        # MU3: should include fig_supp1.csv and keyfile.yml, exclude fig4.csv
        result3 = files_for_result(:mu3_result)
        @test !("/data/fig4.csv" in result3.data_files)
        @test "/data/fig_supp1.csv" in result3.data_files
        @test "/data/keyfile.yml" in result3.data_files
        @test result3.expr_ids == Set([2, 3, 6])

        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()
    end

    @testset "files_for_result with no matching variable" begin
        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()

        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(1, Set([:x]), Set{Symbol}()))
        push!(StoreKit.FILE_READS, (path="/data/file.csv", expr_id=1, mode="r"))

        result = files_for_result(:nonexistent)
        @test isempty(result.data_files)
        @test isempty(result.expr_ids)

        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()
    end

    @testset "files_for_result with transitive dependencies" begin
        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()

        # a -> b -> c -> d (chain of 4)
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(1, Set([:a]), Set{Symbol}()))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(2, Set([:b]), Set([:a])))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(3, Set([:c]), Set([:b])))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(4, Set([:d]), Set([:c])))

        push!(StoreKit.FILE_READS, (path="/root.csv", expr_id=1, mode="r"))

        result = files_for_result(:d)
        @test "/root.csv" in result.data_files
        @test result.expr_ids == Set([1, 2, 3, 4])

        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()
    end

    @testset "files_for_result with diamond dependency" begin
        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()

        # raw -> left, raw -> right, left + right -> merged
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(1, Set([:raw]), Set{Symbol}()))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(2, Set([:left]), Set([:raw])))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(3, Set([:right]), Set([:raw])))
        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(4, Set([:merged]), Set([:left, :right])))

        push!(StoreKit.FILE_READS, (path="/data/raw.csv", expr_id=1, mode="r"))

        result = files_for_result(:merged)
        @test "/data/raw.csv" in result.data_files
        @test result.expr_ids == Set([1, 2, 3, 4])

        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()
    end

    @testset "files_for_result excludes write-mode opens" begin
        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()

        push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(1, Set([:result]), Set{Symbol}()))
        push!(StoreKit.FILE_READS, (path="/data/in.csv", expr_id=1, mode="r"))
        push!(StoreKit.FILE_READS, (path="/data/out.csv", expr_id=1, mode="w"))

        result = files_for_result(:result)
        @test "/data/in.csv" in result.data_files          # read input attributed
        @test !("/data/out.csv" in result.data_files)      # written output NOT attributed
        @test result.expr_ids == Set([1])                  # expr still in the chain

        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()
    end

    @testset "file tracking integration with expression IDs" begin
        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()

        mktempdir() do dir
            csv_path = joinpath(dir, "data.csv")
            yml_path = joinpath(dir, "config.yml")
            write(csv_path, "x,y\n1,2\n")
            write(yml_path, "k: 1.0\n")

            # Expression 1: read CSV (simulate ast_transforms setting expr ID)
            StoreKit._CURRENT_EXPR_ID[] = 1
            open(csv_path, "r") do f; read(f, String); end
            StoreKit._CURRENT_EXPR_ID[] = 0
            push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(1, Set([:df]), Set{Symbol}()))

            # Expression 2: read YAML
            StoreKit._CURRENT_EXPR_ID[] = 2
            open(yml_path, "r") do f; read(f, String); end
            StoreKit._CURRENT_EXPR_ID[] = 0
            push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(2, Set([:cfg]), Set{Symbol}()))

            # Expression 3: combine
            push!(StoreKit.SESSION_LOG, StoreKit.SessionEntry(3, Set([:result]), Set([:df, :cfg])))

            attr = files_for_result(:result)
            @test abspath(csv_path) in attr.data_files
            @test abspath(yml_path) in attr.data_files
            @test attr.expr_ids == Set([1, 2, 3])
        end

        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()
    end

    @testset "script mode attribution" begin
        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()

        mktempdir() do dir
            csv_path = joinpath(dir, "input.csv")
            other_path = joinpath(dir, "other.csv")
            write(csv_path, "x,y\n1,2\n")
            write(other_path, "a,b\n3,4\n")

            script_path = joinpath(dir, "script.jl")
            write(script_path, """
data = open("$(escape_string(csv_path))", "r") do f; read(f, String); end
unused = open("$(escape_string(other_path))", "r") do f; read(f, String); end
result = length(data)
""")

            # Simulate file reads that would have been caught by Base.open
            push!(StoreKit.FILE_READS, (path=abspath(csv_path), expr_id=0, mode="r"))
            push!(StoreKit.FILE_READS, (path=abspath(other_path), expr_id=0, mode="r"))

            attr = StoreKit._script_mode_attribution(script_path, :result)

            # input.csv should be attributed (data -> result chain)
            @test abspath(csv_path) in attr.data_files
            # other.csv should NOT be attributed (unused is not in result's chain)
            @test !(abspath(other_path) in attr.data_files)
        end

        StoreKit.clear_session_log!()
        StoreKit.clear_file_reads!()
    end
end
