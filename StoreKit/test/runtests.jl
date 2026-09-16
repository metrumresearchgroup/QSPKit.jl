using StoreKit
using SQLite
using DBInterface
using Test

@testset "StoreKit" begin

    @testset "open_store creates directory structure" begin
        mktempdir() do dir
            store = open_store(dir)
            @test isdir(joinpath(dir, ".provenance"))
            @test isdir(joinpath(dir, ".provenance", "blobs"))
            @test isfile(joinpath(dir, ".provenance", "provenance.db"))
            @test store isa StoreKit.Store
        end
    end

    @testset "open_store reuses existing database" begin
        mktempdir() do dir
            store1 = open_store(dir)
            blob_put!(store1, "hello world"; type="test")

            store2 = open_store(dir)
            # The blob written via store1 should be visible via store2
            hash = hash_content("hello world")
            # blob_put! and hash_content use the same JLD2/HDF5 payload bytes.
            h = blob_put!(store1, "hello world"; type="test")
            @test blob_exists(store2, h)
        end
    end

    @testset "blob_put! / blob_get roundtrip" begin
        mktempdir() do dir
            store = open_store(dir)

            # String
            h1 = blob_put!(store, "test data"; type="result")
            @test blob_get(store, h1) == "test data"

            # Dict
            d = Dict(:a => 1, :b => [2, 3, 4])
            h2 = blob_put!(store, d; type="result")
            @test blob_get(store, h2) == d

            # Vector{Float64}
            v = [1.0, 2.0, 3.0]
            h3 = blob_put!(store, v; type="data_file")
            @test blob_get(store, h3) == v
        end
    end

    @testset "content-addressed dedup" begin
        mktempdir() do dir
            store = open_store(dir)

            data = "identical content"
            h1 = blob_put!(store, data; type="result")
            h2 = blob_put!(store, data; type="result")

            @test h1 == h2

            # Only one blob file on disk
            blob_files = readdir(joinpath(dir, ".provenance", "blobs"))
            matching = filter(f -> startswith(f, h1), blob_files)
            @test length(matching) == 1
        end
    end

    @testset "blob_exists" begin
        mktempdir() do dir
            store = open_store(dir)

            @test !blob_exists(store, "nonexistent_hash")

            h = blob_put!(store, 42; type="test")
            @test blob_exists(store, h)
        end
    end

    @testset "blob_get errors on missing blob" begin
        mktempdir() do dir
            store = open_store(dir)
            @test_throws ErrorException blob_get(store, "nonexistent_hash")
        end
    end

    @testset "hash_content deterministic" begin
        @test hash_content("hello") == hash_content("hello")
        @test hash_content("hello") != hash_content("world")
        @test hash_content(42) == hash_content(42)
    end

    @testset "hash_file" begin
        mktempdir() do dir
            path = joinpath(dir, "test.txt")
            write(path, "file content")
            h1 = hash_file(path)
            h2 = hash_file(path)
            @test h1 == h2
            @test length(h1) == 64  # SHA-256 hex string

            # Different content → different hash
            path2 = joinpath(dir, "test2.txt")
            write(path2, "different content")
            @test hash_file(path2) != h1
        end
    end

    @testset "SQLite schema" begin
        mktempdir() do dir
            store = open_store(dir)

            # Verify tables exist by querying them
            tables = [r.name for r in DBInterface.execute(store.db, "SELECT name FROM sqlite_master WHERE type='table'")]
            @test "blobs" in tables
            @test "annotations" in tables
            @test "file_snapshots" in tables
        end
    end

    @testset "annotation and file_snapshot helpers" begin
        mktempdir() do dir
            store = open_store(dir)

            # Insert an annotation
            ann_id = StoreKit.insert_annotation!(store.db;
                name="MU1",
                status="accepted",
                rationale="Good fit",
            )
            @test ann_id isa Integer
            @test ann_id > 0

            # Insert file snapshots
            StoreKit.insert_file_snapshot!(store.db, ann_id, "data/fig4.csv", "abc123", "data")
            StoreKit.insert_file_snapshot!(store.db, ann_id, "src/model.jl", "def456", "source")

            # Retrieve snapshots
            snaps = StoreKit.get_file_snapshots(store.db, ann_id)
            @test length(snaps) == 2
            @test any(s -> s.path == "data/fig4.csv" && s.file_type == "data", snaps)
            @test any(s -> s.path == "src/model.jl" && s.file_type == "source", snaps)

            # Latest annotation
            latest = StoreKit.latest_annotation(store.db, "MU1")
            @test latest !== nothing
            @test latest.name == "MU1"
            @test latest.status == "accepted"
            @test latest.rationale == "Good fit"

            # No annotation for unknown name
            @test StoreKit.latest_annotation(store.db, "NONEXISTENT") === nothing

            # All annotations
            ann_id2 = StoreKit.insert_annotation!(store.db;
                name="MU1",
                status="rejected",
                rationale="Poor fit",
            )
            all_anns = StoreKit.all_annotations(store.db, "MU1")
            @test length(all_anns) == 2
            @test all_anns[1].id == ann_id2  # Most recent first
            @test all_anns[2].id == ann_id
        end
    end

end

include("tracking_test.jl")
include("tracing_test.jl")
