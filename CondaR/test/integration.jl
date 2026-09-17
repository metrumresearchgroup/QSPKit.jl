# Opt-in native host check: installs R/packages on a clean machine.
# Run from QSPKit: julia --project=CondaR/test CondaR/test/integration.jl
using Test, QSPKit.CondaR

@testset "Native R provisioning and bridge" begin
    @test CondaR._R_MODULE[] === nothing
    @test rcopy(Int, reval("1L + 1L")) == 2
    @test realpath(rcopy(String, reval("R.home()"))) == realpath(CondaR.r_home())
    @test realpath(first(rcopy(Vector{String}, reval(".libPaths()")))) == realpath(CondaR.r_libdir())
    expected_arch = Sys.ARCH == :aarch64 ? ("aarch64", "arm64") : ("x86_64", "x64")
    @test rcopy(String, reval("R.version\$arch")) in expected_arch
    for package in CondaR._REQUIRED_PACKAGES
        @test rcopy(Bool, rcall(:requireNamespace, package; quietly=true))
    end
    mktempdir() do directory
        plot = reval("ggplot2::ggplot(data.frame(x=1:3, y=3:1), ggplot2::aes(x, y)) + ggplot2::geom_point()")
        cd(directory) do
            rcall(reval("mrggsave::mrggsave"), plot;
                  stem="native-smoke", dir=directory, dev=["png"], script="integration.jl",
                  width=4.0, height=3.0, var"path.type"="none")
            @test filesize(joinpath(directory, "native-smoke.png")) > 100
            reval("while(grDevices::dev.cur() > 1) grDevices::dev.off()")
        end
    end
end
