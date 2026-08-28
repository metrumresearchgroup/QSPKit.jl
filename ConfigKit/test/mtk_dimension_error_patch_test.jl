using Test
using ConfigKit
using ModelingToolkitBase

struct ConfigKitDimensionErrorProbe end
struct ConfigKitSafeGetUnitOverloadProbe end

function ModelingToolkitBase.get_unit(::ConfigKitDimensionErrorProbe)
    DQ = ConfigKit.DQ
    length_quantity = DQ.Quantity(1.0, DQ.Dimensions(length = 1))
    time_quantity = DQ.Quantity(1.0, DQ.Dimensions(time = 1))
    throw(DQ.DimensionError(length_quantity, time_quantity))
end

@testset "ModelingToolkit DimensionError workaround" begin
    ext = Base.get_extension(ModelingToolkitBase, :MTKDynamicQuantitiesExt)
    @test ext !== nothing

    if ext !== nothing
        target = which(ext.safe_get_unit, Tuple{Any, Any})
        @test !ConfigKit._is_broken_mtk_safe_get_unit(ext, target)

        info = "ConfigKit MTK unit probe"
        logger = Test.TestLogger(min_level = Base.CoreLogging.Debug)
        result = Base.CoreLogging.with_logger(logger) do
            ModelingToolkitBase._validate([ConfigKitDimensionErrorProbe()], [info])
        end

        DQ = ConfigKit.DQ
        dimension_error = DQ.DimensionError(
            DQ.Quantity(1.0, DQ.Dimensions(length = 1)),
            DQ.Quantity(1.0, DQ.Dimensions(time = 1)),
        )
        expected_warning =
            "$info: $(dimension_error.q1) and $(dimension_error.q2) are not dimensionally compatible."

        @test result === false
        @test [(record.level, record.message) for record in logger.logs] ==
              [(Base.CoreLogging.Warn, expected_warning)]

        # Re-running the patch must not remove a specialized overload owned by
        # upstream or another extension.
        overload_type = ConfigKitSafeGetUnitOverloadProbe
        Core.eval(ext, :(safe_get_unit(::$overload_type, info) = :preserved))
        overload = which(ext.safe_get_unit, Tuple{overload_type, Any})
        try
            @test Base.invokelatest(ext.safe_get_unit, overload_type(), nothing) === :preserved
            ConfigKit._patch_mtk_dimension_error()
            @test Base.invokelatest(ext.safe_get_unit, overload_type(), nothing) === :preserved
            @test which(ext.safe_get_unit, Tuple{overload_type, Any}) === overload
        finally
            Base.delete_method(overload)
        end
    end
end
