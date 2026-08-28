using Test
using ConfigKit
using OrderedCollections
using YAML

@testset "Advanced Error Handling" begin

    @testset "File System Recovery" begin
        # Test loading from a corrupted file
        temp_file = tempname() * ".yml"
        open(temp_file, "w") do f
            write(f, "Parameters:\n  k: [unclosed_list")
        end

        try
            @test_throws Exception load_keyfile(temp_file)
        finally
            rm(temp_file, force=true)
        end
    end

    @testset "Missing Fields" begin
        # YAML missing 'value' - parser sets it to nothing
        yaml_no_value = """
        Parameters:
          k:
            abbr: k
            unit: "1/hr"
        """
        temp_file = tempname() * ".yml"
        write(temp_file, yaml_no_value)

        try
            kf = load_keyfile(temp_file)
            # Value is nothing when not specified
            @test isnothing(kf.Parameters.k.value)
        finally
            rm(temp_file, force=true)
        end
    end

    @testset "Concurrency / Resource Contention" begin
        # Simulate race conditions by writing/reading in parallel
        # This tests if the parser crashes under rapid IO
        mktempdir() do tmpdir
            keyfile = joinpath(tmpdir, "race.yml")
            write(keyfile, "Parameters:\n  k: {value: 1.0, abbr: k}")

            # ConfigKit load_keyfile is read-only, so strictly safe,
            # but we verify it doesn't lock the file preventing others from reading

            tasks = []
            for i in 1:10
                push!(tasks, Threads.@spawn begin
                    kf = load_keyfile(keyfile)
                    return kf.parameter_defaults[:k]
                end)
            end

            results = fetch.(tasks)
            @test all(r == 1.0 for r in results)
        end
    end
end
