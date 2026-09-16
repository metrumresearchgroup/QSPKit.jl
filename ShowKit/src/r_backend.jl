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
const _ST2PNG_MISSING = Ref("")

# Runtime function references (set at runtime if CondaR is available)
const _rcopy_fn = Ref{Any}(nothing)
const _reval_fn = Ref{Any}(nothing)
const _rcall_fn = Ref{Any}(nothing)
const _robject_fn = Ref{Any}(nothing)
const _R_BACKEND_LOCK = ReentrantLock()

"""
    r_available() -> Bool

Initialize the private R backend if needed and check that ggplot2 is available.
"""
function r_available()
    return lock(_R_BACKEND_LOCK) do
        _RCALL_AVAILABLE[] || return false
        CondaR._ensure_r!()
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
        _rcopy_fn[] = CondaR.rcopy
        _reval_fn[] = CondaR.reval
        _rcall_fn[] = CondaR.rcall
        _robject_fn[] = CondaR.robject
        # The first R operation provisions and initializes R. Do not hide setup
        # failures behind a cached "unavailable" flag.
        _RCALL_AVAILABLE[] = true
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
        _RCALL_AVAILABLE[] || error("R backend is not initialized")
        CondaR._ensure_r!()
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
                   "Check the project's pkgr.yml repositories, or use " *
                   "ShowKit.configure_r!(mode=:latest)."
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
        # CondaR discovers existing native TinyTeX installations; it does not
        # install TeX or change the user's shell configuration here.
        CondaR.ensure_tex_path!()
        pdftools_ok = _rcopy(Bool, _reval("requireNamespace('pdftools', quietly=TRUE)"))
        pdflatex_path = _rcopy(String, _reval("Sys.which('pdflatex')"))
        _ST2PNG_AVAILABLE[] = pdftools_ok && !isempty(pdflatex_path)
        missing = String[]
        pdftools_ok || push!(missing, "R package pdftools")
        isempty(pdflatex_path) && push!(missing, "pdflatex (checked PATH and native TinyTeX locations)")
        _ST2PNG_MISSING[] = join(missing, "; ")
    end
end

function _require_st2png()
    lock(_R_BACKEND_LOCK) do
    _require_pmtables()
    if !_ST2PNG_CHECKED[] || !_ST2PNG_AVAILABLE[]
        _ensure_st2png()
    end
    _ST2PNG_AVAILABLE[] || error(
        "pmtables::st2png dependencies unavailable: $(_ST2PNG_MISSING[])."
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
