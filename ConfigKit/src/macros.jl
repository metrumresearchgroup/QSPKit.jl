# Helper Macros for ConfigKit.jl
#
# Utility macros for ModelingToolkit-based model construction.

"""
    @observed(expr)
    @observed(name ~ expr)
    @observed begin
        name1 ~ expr1
        name2 ~ expr2
    end

Create observed equation(s) that link computed expressions to observable variables.

This macro simplifies the creation of observed (algebraic) equations in ModelingToolkit
systems. It creates the observed variable internally and sets up an equation making it
observable.

# Usage

```julia
using ConfigKit
using ModelingToolkitBase: @parameters, @variables

# Inside a model function:
@variables t x(t) y(t)
@parameters a b

# Define computed quantities
ratio = x / y
total = a * x + b * y

# Create observed equations from local expression names
observed_eqs = [
    @observed(ratio),
    @observed(total)
]

# Or create the observed variable directly on the equation LHS
observed_eqs = @observed begin
    ratio_obs ~ x / y
    total_obs ~ a * x + b * y
    normalized_total ~ total_obs / a
end
```

# Arguments
- `expr`: A symbol representing the local variable to observe, or an equation
  `name ~ expression` whose LHS is the observed variable to create

# Returns
An `Equation` of the form `var ~ expr`, or a vector of equations for block input.

# Notes
- The macro creates a new `@variables` declaration internally
- For `@observed(expr)`, the observed variable has the same name as the input expression
- For `@observed(name ~ expr)`, the observed variable is `name`, which does not
  need to be predeclared
- In block form, simple observed LHS names are available to later equations in the
  same block
- Parameters that appear only in observed equations may need to be passed in the
  explicit `System(eqs, iv, unknowns, parameters; observed=...)` parameter list;
  MTK's shorthand system constructor can infer parameters from `eqs` only
- Typically used when building the `observed` keyword argument for ODESystem

# Example in Context

```julia
function build_pk_model(; name)
    @variables t central(t) peripheral(t)
    @parameters CL V1 V2 Q

    # Computed quantities
    conc_central = central / V1
    auc = integral(conc_central)

    D = Differential(t)
    eqs = [
        D(central) ~ -CL/V1 * central - Q/V1 * central + Q/V2 * peripheral,
        D(peripheral) ~ Q/V1 * central - Q/V2 * peripheral
    ]

    return ODESystem(eqs, t;
        name = name,
        observed = @observed begin
            conc_central ~ central / V1
            auc ~ integral(central / V1)
        end
    )
end
```

See also: [`@common_constants`](@ref)
"""
function _observed_equation_expr(ex)
    if ex isa Expr && ex.head == :call && ex.args[1] === :~ && length(ex.args) == 3
        lhs, rhs = ex.args[2], ex.args[3]
        return quote
            (@variables $lhs)[1] ~ $(esc(rhs))
        end
    end

    quote
        (@variables $ex)[1] ~ $(esc(ex))
    end
end

_observed_block_rhs_expr(ex, lhs_map) = esc(ex)
function _observed_block_rhs_expr(ex::Symbol, lhs_map)
    return get(lhs_map, ex) do
        esc(ex)
    end
end
function _observed_block_rhs_expr(ex::Expr, lhs_map)
    return Expr(ex.head, (_observed_block_rhs_expr(arg, lhs_map) for arg in ex.args)...)
end
_observed_block_rhs_expr(ex::QuoteNode, lhs_map) = ex

"""
    @observed expression
    @observed name ~ expression
    @observed begin ... end

Create one or more ModelingToolkit observed equations. A block permits later
equations to refer to observed names declared earlier in that block.
"""
macro observed(ex)
    if ex isa Expr && ex.head == :block
        eqs = Any[]
        lhs_defs = Any[]
        lhs_map = Dict{Symbol, Symbol}()

        for stmt in ex.args
            stmt isa LineNumberNode && continue
            if stmt isa Expr && stmt.head == :call && stmt.args[1] === :~ && length(stmt.args) == 3
                lhs, rhs = stmt.args[2], stmt.args[3]
                if lhs isa Symbol
                    if haskey(lhs_map, lhs)
                        lhs_var = lhs_map[lhs]
                    else
                        lhs_var = gensym(lhs)
                        lhs_map[lhs] = lhs_var
                        push!(lhs_defs, :(local $lhs_var = (@variables $lhs)[1]))
                    end
                    rhs_expr = _observed_block_rhs_expr(rhs, lhs_map)
                    push!(eqs, :($lhs_var ~ $rhs_expr))
                else
                    push!(eqs, :((@variables $lhs)[1] ~ $(esc(rhs))))
                end
            else
                push!(eqs, _observed_equation_expr(stmt))
            end
        end

        return quote
            let
                $(lhs_defs...)
                [$(eqs...)]
            end
        end
    end

    return _observed_equation_expr(ex)
end

"""
    @common_constants()

!!! warning "Deprecated"
    `@common_constants` is deprecated. Define constants in the keyfile's `Constants:` block
    instead, with proper units:

    ```yaml
    Constants:
      N_Av:
        value: 6.022e23
        unit: 1/mol
        description: "Avogadro's number"
      nmol_per_mol:
        value: 1e9
        description: "Nanomoles per mole"
      s_per_hr:
        value: 3600
        description: "Seconds per hour"
    ```

    Then declare them as plain `@parameters N_Av nmol_per_mol s_per_hr` in the model.
    `populate()` will fill in values and units from the keyfile.
"""
macro common_constants()
    Base.depwarn(
        "`@common_constants` is deprecated. Define N_Av, nmol_per_mol, s_per_hr " *
        "in the keyfile Constants: block instead, then declare as plain @parameters.",
        Symbol("@common_constants"))
    esc(
        quote
            @parameters N_Av = 6.022e23
            @parameters nmol_per_mol = 1e9
            @parameters s_per_hr = 3600
        end
    )
end
