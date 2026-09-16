using Test
using QSPKitCore

Base.@kwdef struct _CoreOptions
    alpha::Float64 = 1.0
    mode::Symbol = :a
    alpha_auto::Bool = true
end

@testset "QSPKitCore config structs" begin
    opts = _CoreOptions()

    @test config_values(opts) == (alpha = 1.0, mode = :a, alpha_auto = true)
    @test public_config_values(opts) == (alpha = 1.0, mode = :a)

    changed = replace_config(opts; alpha = 2.0, mode = :b)
    @test changed isa _CoreOptions
    @test changed.alpha == 2.0
    @test changed.mode === :b
    @test changed.alpha_auto === true

    @test public_config_values(opts; provenance_field = name -> name === :mode) ==
        (alpha = 1.0, alpha_auto = true)
end

@testset "QSPKitCore worker queues" begin
    layout = resolve_worker_layout(8, 4, 0, 0)
    @test layout.workers == 4
    @test layout.inner_threads == 1
    @test layout.thread_budget == 4
    @test layout.parallel

    unsupported = resolve_worker_layout(8, 4, 0, 0; supports_parallel=false)
    @test unsupported.workers == 1
    @test !unsupported.parallel
    @test unsupported.reason === :unsupported_parallel

    seen = zeros(Int, 10)
    cleaned = Threads.Atomic{Int}(0)
    run_worker_queue!(10, 2;
        init_worker = worker -> worker,
        process_item! = (worker_state, item, worker) -> begin
            @test worker_state == worker
            seen[item] += 1
        end,
        cleanup_worker! = _ -> Threads.atomic_add!(cleaned, 1))
    @test seen == ones(Int, 10)
    @test cleaned[] == 2
end
