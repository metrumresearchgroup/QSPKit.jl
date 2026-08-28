# ============================================================
# R Backend — Runtime CondaR/RCall Detection
# ============================================================

# Availability flags
const _RCALL_AVAILABLE = Ref(false)
const _GGPLOT2_AVAILABLE = Ref(false)
const _GGPLOT2_CHECKED = Ref(false)
const _PMPLOTS_AVAILABLE = Ref(false)
const _PMPLOTS_CHECKED = Ref(false)
const _PMTABLES_AVAILABLE = Ref(false)
const _PMTABLES_CHECKED = Ref(false)
const _MRGGSAVE_AVAILABLE = Ref(false)
const _MRGGSAVE_CHECKED = Ref(false)
const _VPC_AVAILABLE = Ref(false)
const _VPC_CHECKED = Ref(false)
const _NPDE_AVAILABLE = Ref(false)
const _NPDE_CHECKED = Ref(false)
# pmtables::st2png deps: pdflatex (TeX install) + pdftools (PDF→PNG)
const _ST2PNG_AVAILABLE = Ref(false)
const _ST2PNG_CHECKED = Ref(false)

# Runtime function references (set at runtime if CondaR is available)
const _rcopy_fn = Ref{Any}(nothing)
const _reval_fn = Ref{Any}(nothing)
const _rcall_fn = Ref{Any}(nothing)
const _robject_fn = Ref{Any}(nothing)
const _R_BACKEND_LOCK = ReentrantLock()

"""
    r_available() -> Bool

Check if the RCall backend is active (R loaded and ggplot2 available).
"""
function r_available()
    return lock(_R_BACKEND_LOCK) do
        _RCALL_AVAILABLE[] || return false
        if !_GGPLOT2_CHECKED[]
            _ensure_ggplot2()
        end
        _RCALL_AVAILABLE[] && _GGPLOT2_AVAILABLE[]
    end
end

"""
    _check_rcall()

Initialize RCall functions from CondaR. Called during __init__.
"""
function _check_rcall()
    lock(_R_BACKEND_LOCK) do
        try
            _rcopy_fn[] = CondaR.rcopy
            _reval_fn[] = CondaR.reval
            _rcall_fn[] = CondaR.rcall
            _robject_fn[] = CondaR.robject
            # Test that R is actually callable
            _rcopy_fn[](Bool, _reval_fn[]("TRUE"))
            _RCALL_AVAILABLE[] = true
        catch
            _RCALL_AVAILABLE[] = false
        end
    end
end

# ---- Wrapper functions ----

function _rcopy(args...)
    return lock(_R_BACKEND_LOCK) do
        isnothing(_rcopy_fn[]) && error("RCall not available — load CondaR first: `using CondaR`")
        _rcopy_fn[](args...)
    end
end

function _reval(args...)
    return lock(_R_BACKEND_LOCK) do
        isnothing(_reval_fn[]) && error("RCall not available — load CondaR first: `using CondaR`")
        _reval_fn[](args...)
    end
end

function _rcall(args...; kwargs...)
    return lock(_R_BACKEND_LOCK) do
        isnothing(_rcall_fn[]) && error("RCall not available — load CondaR first: `using CondaR`")
        _rcall_fn[](args...; kwargs...)
    end
end

function _robject(x)
    return lock(_R_BACKEND_LOCK) do
        isnothing(_robject_fn[]) && error("RCall not available — load CondaR first: `using CondaR`")
        _robject_fn[](x)
    end
end

# ---- R package availability checks ----

function _require_r()
    lock(_R_BACKEND_LOCK) do
        _RCALL_AVAILABLE[] || error("R is not available. Load CondaR first: `using CondaR`")
    end
end

function _ensure_ggplot2()
    lock(_R_BACKEND_LOCK) do
    _GGPLOT2_CHECKED[] = true
    _RCALL_AVAILABLE[] || return
    try
        installed = _rcopy(Bool, _reval("requireNamespace('ggplot2', quietly=TRUE)"))
        if !installed
            @error "ShowKit: ggplot2 is not installed. " *
                   "Add `r-ggplot2` to your CondaPkg.toml or run: " *
                   "CondaR.CondaPkg.add(\"r-ggplot2\"); CondaR.CondaPkg.resolve()"
        end
        _GGPLOT2_AVAILABLE[] = installed
    catch e
        @debug "ShowKit: ggplot2 check failed" exception=e
        _GGPLOT2_AVAILABLE[] = false
    end
    end
end

function _ensure_pmplots()
    lock(_R_BACKEND_LOCK) do
    _PMPLOTS_CHECKED[] = true
    _RCALL_AVAILABLE[] || return
    try
        installed = _rcopy(Bool, _reval("requireNamespace('pmplots', quietly=TRUE)"))
        if installed
            installed = _rcopy(Bool, _reval("""
                local({
                    needed <- c("xlab", "ylab")
                    imports_env <- parent.env(asNamespace("pmplots"))
                    all(vapply(needed, exists, logical(1),
                               envir = imports_env, inherits = FALSE))
                })
            """))
        end
        _PMPLOTS_AVAILABLE[] = installed
    catch e
        @debug "ShowKit: pmplots availability check failed" exception=e
        _PMPLOTS_AVAILABLE[] = false
    end
    end
end

function _ensure_pmtables()
    lock(_R_BACKEND_LOCK) do
    _PMTABLES_CHECKED[] = true
    _RCALL_AVAILABLE[] || return
    try
        installed = _rcopy(Bool, _reval("requireNamespace('pmtables', quietly=TRUE)"))
        _PMTABLES_AVAILABLE[] = installed
    catch e
        @debug "ShowKit: pmtables availability check failed" exception=e
        _PMTABLES_AVAILABLE[] = false
    end
    end
end

function _ensure_mrggsave()
    lock(_R_BACKEND_LOCK) do
    _MRGGSAVE_CHECKED[] = true
    _RCALL_AVAILABLE[] || return
    try
        installed = _rcopy(Bool, _reval("requireNamespace('mrggsave', quietly=TRUE)"))
        _MRGGSAVE_AVAILABLE[] = installed
    catch e
        @debug "ShowKit: mrggsave availability check failed" exception=e
        _MRGGSAVE_AVAILABLE[] = false
    end
    end
end

function _ensure_vpc()
    lock(_R_BACKEND_LOCK) do
    _VPC_CHECKED[] = true
    _RCALL_AVAILABLE[] || return
    try
        installed = _rcopy(Bool, _reval("requireNamespace('vpc', quietly=TRUE)"))
        _VPC_AVAILABLE[] = installed
    catch e
        @debug "ShowKit: vpc availability check failed" exception=e
        _VPC_AVAILABLE[] = false
    end
    end
end

function _ensure_npde()
    lock(_R_BACKEND_LOCK) do
    _NPDE_CHECKED[] = true
    _RCALL_AVAILABLE[] || return
    try
        installed = _rcopy(Bool, _reval("requireNamespace('npde', quietly=TRUE)"))
        _NPDE_AVAILABLE[] = installed
    catch e
        @debug "ShowKit: npde availability check failed" exception=e
        _NPDE_AVAILABLE[] = false
    end
    end
end

function _ensure_st2png()
    lock(_R_BACKEND_LOCK) do
    _ST2PNG_CHECKED[] = true
    _RCALL_AVAILABLE[] || return
    try
        # Read-only checks: ShowKit never installs R or TeX dependencies at
        # runtime.  Environment provisioning belongs to the application or CI.
        pdftools_ok = _rcopy(Bool, _reval("requireNamespace('pdftools', quietly=TRUE)"))
        pdflatex_path = _rcopy(String, _reval("Sys.which('pdflatex')"))
        _ST2PNG_AVAILABLE[] = pdftools_ok && !isempty(pdflatex_path)
        if !_ST2PNG_AVAILABLE[]
            @debug "ShowKit: st2png dependencies are unavailable" pdftools=pdftools_ok pdflatex=pdflatex_path
        end
    catch e
        @debug "ShowKit: st2png dependency check failed" exception=e
        _ST2PNG_AVAILABLE[] = false
    end
    end
end

function _require_st2png()
    lock(_R_BACKEND_LOCK) do
    _require_pmtables()
    if !_ST2PNG_CHECKED[]
        _ensure_st2png()
    end
    _ST2PNG_AVAILABLE[] || error(
        "pmtables::st2png deps not available (need pdftools R package and a working " *
        "pdflatex; tinytex::install_tinytex() can provide the latter)."
    )
    end
end

function _require_ggplot2()
    lock(_R_BACKEND_LOCK) do
    _require_r()
    if !_GGPLOT2_CHECKED[]
        _ensure_ggplot2()
    end
    _GGPLOT2_AVAILABLE[] || error("ggplot2 R package is not available")
    end
end

function _require_pmplots()
    lock(_R_BACKEND_LOCK) do
    _require_r()
    if !_PMPLOTS_CHECKED[]
        _ensure_pmplots()
    end
    _PMPLOTS_AVAILABLE[] || error("pmplots R package is not available")
    end
end

function _require_pmtables()
    lock(_R_BACKEND_LOCK) do
    _require_r()
    if !_PMTABLES_CHECKED[]
        _ensure_pmtables()
    end
    _PMTABLES_AVAILABLE[] || error("pmtables R package is not available")
    end
end

function _require_mrggsave()
    lock(_R_BACKEND_LOCK) do
    _require_r()
    if !_MRGGSAVE_CHECKED[]
        _ensure_mrggsave()
    end
    _MRGGSAVE_AVAILABLE[] || error("mrggsave R package is not available")
    end
end

function _require_vpc()
    lock(_R_BACKEND_LOCK) do
    _require_r()
    if !_VPC_CHECKED[]
        _ensure_vpc()
    end
    _VPC_AVAILABLE[] || error("vpc R package is not available")
    end
end

function _require_npde()
    lock(_R_BACKEND_LOCK) do
    _require_r()
    if !_NPDE_CHECKED[]
        _ensure_npde()
    end
    _NPDE_AVAILABLE[] || error("npde R package is not available")
    end
end
