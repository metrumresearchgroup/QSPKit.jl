const _SYMBOLIC_COMPILATION_LOCK = ReentrantLock()

"""
    with_symbolic_compilation_lock(f)

Run `f` while holding QSPKit's process-wide symbolic compilation lock.

Some ModelingToolkit/SymbolicUtils code-generation paths mutate shared internal
scratch state while building functions. QSPKit packages use this lock around
lazy symbolic compilation that may be reached from threaded workflows.
"""
with_symbolic_compilation_lock(f::F) where {F} =
    lock(f, _SYMBOLIC_COMPILATION_LOCK)
