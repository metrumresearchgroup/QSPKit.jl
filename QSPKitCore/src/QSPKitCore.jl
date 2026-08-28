"""
    QSPKitCore

Process-wide coordination for symbolic compilation in QSPKit packages.

The alpha keeps this package deliberately narrow: InjecKit uses its reentrant
lock to serialize ModelingToolkit and SymbolicUtils code-generation paths that
can mutate shared scratch state.
"""
module QSPKitCore

include("symbolic_codegen.jl")

export with_symbolic_compilation_lock

end
