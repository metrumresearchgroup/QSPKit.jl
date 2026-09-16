using InjecKit
using DifferentialEquations
using DataFrames
using Test

println("Testing parameter dependency detection...")

# Simple test case
@independent_variables t
@discretes BASE(t) = 2.0 SCALE(t) = 3.0
@discretes CL(t) = BASE * SCALE  # Default value dependency
@variables C(t)
D = Differential(t)

sys = MTK.System([D(C) ~ -CL * C], t, name=:test)
sys = MTK.mtkcompile(sys)

# Extract dependencies
deps = InjecKit.extract_parameter_dependencies(sys)
println("Dependencies found: ", deps)

# Test with DataFrame
df = DataFrame(
    TIME = [0.0, 12.0],
    EVID = [1, 2],
    CMT = [:C, missing],
    AMT = [100.0, missing],
    BASE = [missing, 4.0]
)

u0_p = Dict(C => 100.0, BASE => 2.0, SCALE => 3.0, CL => 6.0)
tspan = (0.0, 24.0)

println("\nTesting in strict mode (should error)...")
try
    prob = ODEProblem(sys, u0_p, tspan, df)
    println("ERROR: Should have thrown an error!")
catch e
    println("Got expected error: ", typeof(e))
    println("Message: ", e)
end

println("\nTesting in non-strict mode (should warn)...")
withenv("INJECKIT_STRICT_PARAM_CHECK" => "false") do
    @test InjecKit.is_strict_mode() == false
    prob = ODEProblem(sys, u0_p, tspan, df)
    println("Created problem successfully in non-strict mode")
end

# Test system with dynamic dependency
println("\n\nTesting system with dynamic dependency...")
@discretes BASE2(t) = 2.0 SCALE2(t) = 3.0 CL2(t)
@variables C2(t)

eqs = [
    CL2 ~ BASE2 * SCALE2,  # Dynamic dependency
    D(C2) ~ -CL2 * C2
]

sys2 = MTK.System(eqs, t, name=:test2)
sys2 = MTK.mtkcompile(sys2)

deps2 = InjecKit.extract_parameter_dependencies(sys2)
println("Dependencies found in dynamic system: ", deps2)

df2 = DataFrame(
    TIME = [0.0, 12.0],
    EVID = [1, 2],
    CMT = [:C2, missing],
    AMT = [100.0, missing],
    BASE2 = [missing, 4.0]
)

u0_p2 = Dict(C2 => 100.0, BASE2 => 2.0, SCALE2 => 3.0, CL2 => 6.0)

println("\nTesting dynamic system (should NOT error or warn)...")
prob2 = ODEProblem(sys2, u0_p2, tspan, df2)
println("Created problem successfully with no warnings")

println("\nAll tests completed!")