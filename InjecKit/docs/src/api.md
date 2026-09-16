# API Reference

Complete reference for InjecKit.jl functions, types, and methods.

## Main Entry Points

### ODEProblem Constructors

InjecKit extends `ODEProblem` with new constructors for event handling:

```julia
ODEProblem(sys::ModelingToolkit.AbstractSystem, u0_p, tspan, events_data; kwargs...)
```

Where `events_data` can be:
- `DataFrame` - NONMEM-style dosing data
- `Vector{IEvent}` - mrgsolve-style events  
- `Vector{SymbolicDiscreteCallback}` - ModelingToolkit callbacks

### Event Creation Functions

```julia
ev(; time=0.0, cmt=nothing, amt=nothing, rate=nothing, duration=nothing, 
   evid=1, ii=nothing, addl=nothing, ss=nothing, kwargs...)
```

Creates an IEvent with mrgsolve-style syntax.

## Core Processing Functions

```@docs
setevent
expand_repeated_events
get_infusion_parameters
```

## ODEProblem Constructors

InjecKit.jl provides multiple dispatch constructors for `ODEProblem` to streamline event handling:

```@autodocs
Modules = [InjecKit]
Order = [:function, :type]
Filter = t -> occursin("ODEProblem", string(t))
```

## Types

### IEvent

```julia
struct IEvent
    time::Float64
    cmt::Union{Symbol, String, ModelingToolkit.Num, Nothing}
    amt::Union{Float64, Nothing}
    rate::Union{Float64, Nothing}
    duration::Union{Float64, Nothing}
    evid::Int
    ii::Union{Float64, Nothing}
    addl::Union{Int, Nothing}
    ss::Union{Int, Nothing}
    param_changes::Dict{Union{Symbol, ModelingToolkit.Num}, Float64}
end
```

Represents a single dosing or parameter change event similar to NONMEM/mrgsolve event records.

**Fields:**
- `time`: Event time
- `cmt`: Target compartment/parameter (Symbol, String, or resolved ModelingToolkit.Num)
- `amt`: Dose amount 
- `rate`: Infusion rate (for continuous infusions)
- `duration`: Infusion duration (alternative to rate)
- `evid`: Event ID (1=dosing, 2=parameter change, 3=reset, 4=reset+dose)
- `ii`: Inter-dose interval (for repeated dosing)
- `addl`: Additional doses (for repeated dosing)
- `ss`: Steady state flag
- `param_changes`: Dictionary of parameter changes (for EVID=2)

### Event Detection

InjecKit.jl uses the following logic to detect continuous infusions:
- **EVID = 1** (dosing event) AND
- **RATE > 0** OR **(AMT > 0 AND DURATION > 0)**

## Internal Functions

These functions are used internally. While not part of the public API, they may be useful for understanding the implementation:

### Event Batching
InjecKit batches events by type for efficient callback creation:
- `create_batched_bolus_callback` - Groups bolus doses to same compartment
- `create_batched_infusion_callbacks` - Groups infusion start/stop events
- `create_batched_parameter_callback` - Groups parameter changes

### System Extension
- `create_extended_system_upfront` - Extends system with infusion rate parameters
- `extend_and_compile_system` - Compiles system with event support

### Variable Resolution
- `resolve_variable_to_num` - Resolves Symbol/String compartment references to MTK Num types

## DataFrame Column Reference

When using DataFrame-based events, InjecKit.jl recognizes these standard columns:

### Required Columns
- **TIME**: Event times (Float64)
- **EVID**: Event ID (Int): 1=dosing, 2=parameter change
- **CMT**: Target compartment/parameter (Symbol or String)

### Optional Columns
- **AMT**: Dose amount (Float64, required for EVID=1)
- **RATE**: Infusion rate (Float64, for continuous infusions)
- **DURATION**: Infusion duration (Float64, alternative to RATE)
- **II**: Inter-dose interval (Float64, for repeated dosing)  
- **ADDL**: Additional doses (Int, for repeated dosing)
- **SS**: Steady state flag (Int, for steady-state dosing)

### Missing Value Handling
- Use `missing` for optional values that don't apply to specific events
- Required values (like AMT for dosing events) cannot be missing

## Error Types

### Common Errors

**`ArgumentError("CMT must specify a valid compartment")`**
- Thrown when CMT doesn't match any variable/parameter in the system

**`ArgumentError("For continuous infusion, specify exactly two of: amt, rate, duration")`**
- Thrown when infusion parameters are over-specified or under-specified

**`ArgumentError("Target parameter must have [input = true] metadata")`**
- Thrown when trying to infuse to an existing parameter without proper metadata

**`MethodError` for ODEProblem constructors**
- Occurs when system `f` is not a ModelingToolkit AbstractSystem

## Advanced Usage Patterns

### Expanding Repeated Events
```julia
# Expand events with ii/addl into individual events
events = [ev(time=0.0, cmt=:Depot, amt=100.0, ii=24.0, addl=6)]
expanded = expand_repeated_events(events)
# Returns 7 individual events at t=0, 24, 48, 72, 96, 120, 144
```

### System Inspection
```julia
# Check for infusion parameters after solving
infusion_params = get_infusion_parameters(sol.prob.f.sys)
println("Found $(length(infusion_params)) infusion parameters")
```

### DataFrame to Events Conversion
```julia
# Convert NONMEM-style DataFrame to IEvent vector
events = InjecKit.dataframe_to_mrgevents(dosing_df)
```

## Performance Notes

### Optimization Features
- **Unique parameter naming**: Uses `gensym()` for collision-free parameter names
- **Minimal system modification**: Only modifies equations for compartments receiving infusions
- **Efficient callbacks**: Optimized start/stop event generation
- **Type stability**: All operations maintain type stability

### Best Practices for Performance
1. **Batch events**: Group multiple events in single DataFrame/vector rather than processing individually
2. **Pre-allocate**: For population simulations, pre-allocate result storage
3. **Appropriate solvers**: Use `Tsit5()` for most PK problems, `Rodas4()` for stiff systems
4. **Saveat optimization**: Only save timepoints you need for analysis

### Memory Considerations
- Continuous infusion processing creates additional parameters and equations
- For very large event datasets, consider chunked processing
- Use `GC.gc()` between large simulations if needed

## Integration Notes

### ModelingToolkit Compatibility
- Requires ModelingToolkit.jl v11.0+
- Works with `@mtkcompile` compiled systems
- Compatible with ModelingToolkit parameter and variable types
- Time-varying parameters should be declared with `@discretes` macro

### DifferentialEquations.jl Integration  
- Seamless integration with DifferentialEquations.jl solvers
- Automatic callback handling
- Support for all standard solver options

### Plotting Integration
- Solutions work directly with Plots.jl
- Infusion parameters can be plotted like any other solution variable
- Helper function `plot_infusion_history()` for convenience

## Prepared execution

```@docs
PreparedEventSolve
```

`EventRunner` precomputes a reusable event plan, and `solve_event_runner`
executes it. The callback boundaries `with_prepared_event_problem`,
`with_prepared_event_solve`, and
`with_prepared_active_tunable_sensitivity_problem` lend prepared workspaces for
one call. `tunable_parameter_index` resolves the flat index of a tunable model
parameter.

The `with_prepared_*` functions lend temporary problems and buffers to a
callback. Do not retain or mutate those borrowed values after the callback
returns.

This API reference provides complete coverage of InjecKit.jl functionality for both basic and advanced usage scenarios.
