"""
MTK system utilities for InjecKit.
"""

"""
    extract_u0_p_from_problem(prob::ODEProblem)

Extract u0 and parameters from an ODEProblem and return a merged dictionary.
This is the unified function used across all solve methods.
"""
function extract_u0_p_from_problem(prob::ODEProblem)
    sys = prob.f.sys
    u0_og = Dict{Any, Any}()
    for v in MTK.unknowns(sys)
        u0_og[v] = _problem_state_value(prob, v)
    end

    p_og = Dict{Any, Any}()
    for p in MTK.parameters(sys)
        p_og[p] = _problem_parameter_value(prob, p)
    end
    return merge(u0_og, p_og)
end

function _problem_state_value(prob::ODEProblem, v)
    try
        return prob[v]
    catch e
        error("InjecKit: could not extract initial value for state $(v) by symbolic key. " *
              "This indicates the ODEProblem metadata no longer matches the system. " *
              "Original error: $(e)")
    end
end

function _problem_parameter_value(prob::ODEProblem, p)
    try
        return SciMLBase.getp(prob, p)(prob)
    catch e
        error("InjecKit: could not extract value for parameter $(p) by symbolic key. " *
              "This indicates the ODEProblem metadata no longer matches the system. " *
              "Original error: $(e)")
    end
end
