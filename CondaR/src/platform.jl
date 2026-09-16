# Select for the running Julia process, including Julia running under emulation.
# An embedded R must have the same architecture as Julia.
function _platform(; kernel=Sys.KERNEL, arch=Sys.ARCH, machine=Sys.MACHINE)
    os = kernel == :Darwin ? "osx" : kernel == :Linux ? "linux" : kernel == :NT ? "win" : ""
    cpu = arch == :x86_64 ? "64" : arch == :aarch64 ? (os == "linux" ? "aarch64" : "arm64") : ""
    if isempty(os) || isempty(cpu) || (os == "win" && arch != :x86_64) || (os == "linux" && occursin("musl", machine))
        throw(ArgumentError("CondaR has no managed R/toolchain for $kernel/$arch ($machine). " *
            "Available targets: Linux glibc x86_64/aarch64, macOS x86_64/aarch64, Windows x86_64. " *
            "On Windows ARM, use x86_64 Julia under Windows emulation; native ARM R is not available from this provider."))
    end
    (; os, arch=string(arch), subdir="$os-$cpu")
end

# Leave room for package source paths under Windows' legacy path-length limits.
# Complete fingerprints remain in the installation records.
_path_id(hash, platform=_platform()) = platform.os == "win" ? first(hash, 20) : hash
_rhome(runtime, platform=_platform()) = joinpath(runtime, platform.os == "win" ? "Lib" : "lib", "R")
_rscript(runtime, platform=_platform()) = platform.os == "win" ? joinpath(runtime, "Scripts", "Rscript.exe") : joinpath(_rhome(runtime, platform), "bin", "Rscript")
_libr(rhome, platform=_platform()) = platform.os == "win" ? joinpath(rhome, "bin", "x64", "R.dll") : joinpath(rhome, "lib", platform.os == "osx" ? "libR.dylib" : "libR.so")

function _runtime_bins(runtime, platform=_platform())
    platform.os == "win" || return [joinpath(runtime, "bin")]
    [joinpath(runtime, "Scripts"), joinpath(runtime, "Library", "bin"),
     joinpath(runtime, "Library", "mingw-w64", "bin"), joinpath(runtime, "Library", "usr", "bin"),
     joinpath(_rhome(runtime, platform), "bin", "x64"), runtime]
end
