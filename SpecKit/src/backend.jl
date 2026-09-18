# ============================================================
# Backend Selection — RCall vs Native
# ============================================================

const _RCALL_AVAILABLE = Ref(false)
const _YSPEC_AVAILABLE = Ref(false)
const _YSPEC_CHECKED = Ref(false)

# Function references for RCall operations (set at runtime if available)
const _rcopy_fn = Ref{Any}(nothing)
const _reval_fn = Ref{Any}(nothing)
const _SPEC_R_LOCK = ReentrantLock()

"""
    r_available() -> Bool

Check if the RCall backend is active (R loaded and yspec installed).
"""
function r_available()
    return lock(_SPEC_R_LOCK) do
        _RCALL_AVAILABLE[] || return false
        if !_YSPEC_CHECKED[]
            _ensure_yspec()
        end
        _RCALL_AVAILABLE[] && _YSPEC_AVAILABLE[]
    end
end

"""
    _check_rcall()

Bind the unified package's CondaR backend. Called during `__init__`; the first
actual R operation remains lazy and is performed by `r_available()`.
"""
function _check_rcall()
    lock(_SPEC_R_LOCK) do
        _rcopy_fn[] = CondaR.rcopy
        _reval_fn[] = CondaR.reval
        _RCALL_AVAILABLE[] = true
    end
    return nothing
end

# Wrapper functions that delegate to the runtime-resolved functions
function _rcopy(args...)
    return lock(_SPEC_R_LOCK) do
        isnothing(_rcopy_fn[]) && error("RCall not available")
        _rcopy_fn[](args...)
    end
end

function _reval(args...)
    return lock(_SPEC_R_LOCK) do
        isnothing(_reval_fn[]) && error("RCall not available")
        _reval_fn[](args...)
    end
end

"""
    _ensure_yspec()

Check if yspec is installed in R; install from GitHub if missing.
Called lazily on first r_available() check.
"""
function _ensure_yspec()
    lock(_SPEC_R_LOCK) do
        _YSPEC_CHECKED[] = true
        _RCALL_AVAILABLE[] || return
        try
            installed = _rcopy(Bool, _reval("requireNamespace('yspec', quietly=TRUE)"))
            if !installed
                @info "SpecKit: Installing yspec from GitHub (one-time setup)..."
                _reval("""
                    remotes::install_github(
                        'metrumresearchgroup/yspec',
                        quiet = TRUE,
                        build_vignettes = FALSE,
                        dependencies = FALSE
                    )
                """)
                installed = _rcopy(Bool, _reval("requireNamespace('yspec', quietly=TRUE)"))
            end
            _YSPEC_AVAILABLE[] = installed
        catch e
            @debug "SpecKit: yspec installation failed" exception=e
            _YSPEC_AVAILABLE[] = false
        end
    end
end

"""
    load_yspec(path; backend=:auto) -> YspecMetadata

Load a yspec YAML file into a YspecMetadata struct.

# Backends
- `:auto` — use RCall if available, fall back to native
- `:rcall` — use real yspec via RCall (error if unavailable)
- `:native` — use Julia YAML parser
"""
function load_yspec(path::AbstractString; backend::Symbol=:auto)
    path = abspath(path)
    isfile(path) || error("yspec file not found: $path")

    if backend == :auto
        if r_available()
            return parse_yspec_rcall(path)
        else
            return parse_yspec_native(path)
        end
    elseif backend == :rcall
        r_available() || error("RCall backend not available. R may not be installed.")
        return parse_yspec_rcall(path)
    elseif backend == :native
        return parse_yspec_native(path)
    else
        error("Unknown backend: $backend. Use :auto, :rcall, or :native.")
    end
end
