using Test
using QSPKitCore

@testset "QSPKitCore symbolic compilation lock" begin
    # Return values and do-block syntax are transparent to callers.
    @test with_symbolic_compilation_lock(() -> 42) == 42
    @test with_symbolic_compilation_lock() do
        with_symbolic_compilation_lock(() -> :reentrant)
    end === :reentrant

    # Exceptions propagate without poisoning the process-wide lock.
    @test_throws ErrorException with_symbolic_compilation_lock() do
        error("compile failed")
    end
    @test with_symbolic_compilation_lock(() -> :recovered) === :recovered

    # Concurrent callers are serialized. Yielding inside the critical section
    # makes an unprotected read/modify/write race deterministic enough to catch
    # accidental removal or weakening of the lock, even with one Julia thread.
    counter = Ref(0)
    entered = Ref(0)
    max_entered = Ref(0)
    @sync for _ in 1:64
        Threads.@spawn with_symbolic_compilation_lock() do
            entered[] += 1
            max_entered[] = max(max_entered[], entered[])
            old = counter[]
            yield()
            counter[] = old + 1
            entered[] -= 1
        end
    end
    @test counter[] == 64
    @test entered[] == 0
    @test max_entered[] == 1
end
