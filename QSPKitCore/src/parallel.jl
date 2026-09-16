# Generic work-queue helpers for task parallelism.

function resolve_worker_layout(n_items::Integer,
                               total_threads::Integer,
                               requested_workers::Integer,
                               requested_inner_threads::Integer;
                               supports_parallel::Bool=true)
    n_items = max(0, Int(n_items))
    total_threads = max(1, Int(total_threads))
    requested_workers = max(0, Int(requested_workers))
    requested_inner_threads = max(0, Int(requested_inner_threads))

    if n_items == 0
        return (
            workers = 0,
            inner_threads = 0,
            thread_budget = 0,
            parallel = false,
            reason = :empty,
        )
    end

    if !supports_parallel || total_threads <= 1 || n_items <= 1
        return (
            workers = 1,
            inner_threads = 0,
            thread_budget = 1,
            parallel = false,
            reason = supports_parallel ? :single_thread : :unsupported_parallel,
        )
    end

    if requested_workers > 0
        workers = min(requested_workers, n_items, total_threads)
        inner_cap = max(1, total_threads ÷ max(workers, 1))
        inner_threads = requested_inner_threads > 0 ?
            min(requested_inner_threads, inner_cap) : inner_cap
    elseif requested_inner_threads > 0
        inner_threads = min(requested_inner_threads, total_threads)
        workers = min(n_items, max(1, total_threads ÷ inner_threads))
    else
        workers = min(n_items, total_threads)
        inner_threads = max(1, total_threads ÷ max(workers, 1))
    end

    thread_budget = workers * inner_threads
    return (
        workers = workers,
        inner_threads = inner_threads,
        thread_budget = thread_budget,
        parallel = workers > 1 ||
                   requested_workers > 0 ||
                   requested_inner_threads > 0,
        reason = :parallel_items,
    )
end

_no_worker_cleanup!(_) = nothing
_no_item_done!(_, _, _) = nothing

function run_worker_queue!(n_items::Integer,
                           n_workers::Integer;
                           init_worker::Function,
                           process_item!::Function,
                           cleanup_worker!::Function=_no_worker_cleanup!,
                           on_item_done!::Function=_no_item_done!)
    n_items = max(0, Int(n_items))
    n_workers = min(max(0, Int(n_workers)), n_items)
    (n_items == 0 || n_workers == 0) && return nothing

    worker_states = Vector{Any}(undef, n_workers)
    next_item = Threads.Atomic{Int}(1)
    cancelled = Threads.Atomic{Int}(0)
    tasks = Vector{Task}(undef, n_workers)

    try
        for worker in 1:n_workers
            worker_states[worker] = init_worker(worker)
        end

        for worker in 1:n_workers
            tasks[worker] = Threads.@spawn begin
                worker_state = worker_states[worker]
                try
                    while cancelled[] == 0
                        item = Threads.atomic_add!(next_item, 1)
                        item > n_items && break
                        process_item!(worker_state, item, worker)
                        on_item_done!(worker_state, item, worker)
                    end
                catch
                    cancelled[] = 1
                    rethrow()
                end
                return nothing
            end
        end

        for task in tasks
            try
                fetch(task)
            catch
                cancelled[] = 1
                for other in tasks
                    try
                        wait(other)
                    catch
                    end
                end
                rethrow()
            end
        end
    finally
        for worker in 1:n_workers
            if isassigned(worker_states, worker)
                cleanup_worker!(worker_states[worker])
            end
        end
    end

    return nothing
end
