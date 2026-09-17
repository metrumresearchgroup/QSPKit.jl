using Test
using QSPKit.ConfigKit

@testset verbose=true "ConfigKit Full Suite" begin

    # 1. ORIGINAL & COMPATIBILITY
    @info "Running Existing Tests..."
    include("existing_tests.jl")

    # 2. KEYFILE ENGINE
    @info "Running Keyfile Engine Tests..."
    include("keyfile/utils_test.jl")
    include("keyfile/structs_test.jl")
    include("keyfile/variant_diff_test.jl")
    include("keyfile/accessor_api_test.jl")
    include("keyfile/bulk_accessors_test.jl")
    include("keyfile/value_test.jl")

    # 3. ROBUSTNESS
    @info "Running Robustness Tests..."
    include("keyfile/advanced_error_handling_test.jl")
    include("keyfile/parser_edge_cases_test.jl")

    # 4. UPDATE ENGINE & MTK V11
    @info "Running Update Engine Tests..."
    include("update/update_test.jl")
    include("update/populate_test.jl")

    # 5. MACROS
    @info "Running Macro Tests..."
    include("macros/macros_test.jl")

    # 6. PARAMETER SET
    @info "Running ParameterSet Tests..."
    include("parameter_set_test.jl")

    # 7. OPTICS (Accessors.jl)
    @info "Running Optics Tests..."
    include("optics_test.jl")

    # 8. PERFORMANCE REGRESSION CHECK
    @info "Running Performance Regression Check..."
    include("update/perf_regression_test.jl")

end
