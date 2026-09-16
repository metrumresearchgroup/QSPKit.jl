using Test
using CondaR

@test CondaR._R_MODULE[] === nothing
include("native.jl")
include("configuration.jl")
include("installer_output.jl")

@testset "Native TinyTeX discovery" begin
    mktempdir() do directory
        native_dirs = CondaR._tinytex_platform_dirs()
        if !isempty(native_dirs)
            executable = Sys.iswindows() ? "pdflatex.exe" : "pdflatex"
            native_root = joinpath(directory, "native")
            native_bin = joinpath(native_root, "bin", first(native_dirs))
            foreign_root = joinpath(directory, "foreign")
            foreign_bin = joinpath(foreign_root, "bin", "another-platform")
            for bin in (native_bin, foreign_bin)
                mkpath(bin)
                write(joinpath(bin, executable), "#!/bin/sh\nexit 0\n")
                chmod(joinpath(bin, executable), 0o755)
            end
            withenv("PATH" => "") do
                @test ensure_tex_path!(; roots=[foreign_root]) === nothing
                @test ENV["PATH"] == ""
                found = ensure_tex_path!(; roots=[foreign_root, native_root])
                @test found == joinpath(native_bin, executable)
                @test ENV["PATH"] == native_bin
                @test Sys.which("pdflatex") == found
                @test ensure_tex_path!(; roots=String[]) == found
                @test ENV["PATH"] == native_bin
            end
        end
    end
end
