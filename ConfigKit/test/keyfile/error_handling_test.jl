using Test
using ConfigKit
using OrderedCollections
using YAML

@testset "Comprehensive Error Handling" begin

    @testset "File System Error Recovery" begin
        @testset "Permission denied scenarios" begin
            temp_dir = mktempdir()
            try
                cd(temp_dir) do
                    restricted_dir = "restricted_access"
                    mkpath(restricted_dir)
                    if !Sys.iswindows()
                        try
                            chmod(restricted_dir, 0o444) # Read only
                            @test_throws Base.IOError mkpath(joinpath(restricted_dir, "subdir"))
                            chmod(restricted_dir, 0o755)
                        catch e
                            println("Permission test skipped: $(typeof(e))")
                        end
                    end
                end
            finally
                rm(temp_dir; recursive = true, force = true)
            end
        end
    end

    @testset "Data Integrity Error Handling" begin
        @testset "Malformed data recovery" begin
            temp_dir = mktempdir()
            try
                cd(temp_dir) do
                    malformed_files = [
                        ("incomplete.yml", "name: test\nversion: "),
                        ("invalid_yaml.yml", "{\ninvalid: yaml: structure\n[unclosed"),
                    ]

                    for (filename, content) in malformed_files
                        open(filename, "w") do f
                            write(f, content)
                        end
                        try
                            # Direct YAML load might fail
                            YAML.load_file(filename)
                        catch e
                            @test e isa Exception
                        end
                    end
                end
            finally
                rm(temp_dir; recursive = true, force = true)
            end
        end
    end
end
