"""
    QSPKitCore

Small dependency-light utilities shared by QSPKit packages.

This package is intentionally domain-neutral: no MTK model configuration,
no sampler targets, and no solver/runtime objects.
"""
module QSPKitCore

include("config_structs.jl")
include("parallel.jl")
include("symbolic_codegen.jl")

export config_values, public_config_values, replace_config,
    is_auto_provenance_field
export resolve_worker_layout, run_worker_queue!
export with_symbolic_compilation_lock

end
