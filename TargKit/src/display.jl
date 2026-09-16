# ============================================================
# Display — Base.show for FitResult, ScoreReport
# ============================================================

# --- ScoreReport ---

function Base.show(io::IO, r::ScoreReport)
    print(io, "ScoreReport: $(r.n_met)/$(r.n_total) targets met, total loss = $(round(r.total_loss; digits=4))")
end

function Base.show(io::IO, ::MIME"text/plain", r::ScoreReport)
    show(io, r)
    nrow(r.details) == 0 && return

    # Compute column widths
    name_w = max(4, maximum(length(string(n)) for n in r.details.name))
    pred_w = max(9, maximum(length(_fmt_val(p)) for p in r.details.predicted))
    targ_w = max(6, maximum(length(_fmt_val(v)) for v in r.details.value))
    loss_w = max(4, maximum(length(_fmt_loss(l)) for l in r.details.loss))

    # Check if we have range columns
    has_range = hasproperty(r.details, :lower) && hasproperty(r.details, :upper)
    if has_range
        range_w = max(5, maximum(length(_fmt_range_cols(r.details.lower[i], r.details.upper[i]))
                                 for i in 1:nrow(r.details)))
    else
        range_w = 1
    end

    # Header
    println(io)
    if has_range
        header = "  $(rpad("Name", name_w))  $(lpad("Predicted", pred_w))  $(lpad("Target", targ_w))  $(lpad("Range", range_w))  $(lpad("Loss", loss_w))  Status"
    else
        header = "  $(rpad("Name", name_w))  $(lpad("Predicted", pred_w))  $(lpad("Target", targ_w))  $(lpad("Loss", loss_w))  Status"
    end
    println(io, header)

    # Rows
    for i in 1:nrow(r.details)
        d = r.details[i, :]
        name_str = rpad(string(d.name), name_w)
        pred_str = lpad(_fmt_val(d.predicted), pred_w)
        targ_str = lpad(_fmt_val(d.value), targ_w)
        loss_str = lpad(_fmt_loss(d.loss), loss_w)
        status = _fmt_status(d.in_range)
        if has_range
            range_str = lpad(_fmt_range_cols(d.lower, d.upper), range_w)
            println(io, "  $name_str  $pred_str  $targ_str  $range_str  $loss_str  $status")
        else
            println(io, "  $name_str  $pred_str  $targ_str  $loss_str  $status")
        end
    end
end

# --- FitResult ---

function Base.show(io::IO, r::FitResult)
    print(io, "FitResult: loss=$(round(r.loss; digits=6)), $(length(r.params)) params, method=:$(r.method), converged=$(r.converged)")
end

function Base.show(io::IO, ::MIME"text/plain", r::FitResult)
    show(io, r)
    println(io)
    println(io, "  Parameters:")
    for (k, v) in sort(collect(r.params); by=first)
        println(io, "    $k = $(_smart_round(v))")
    end
    if !isnothing(r.report)
        println(io, "  $(r.report.n_met)/$(r.report.n_total) targets met")
    end
end

# ============================================================
# Internal formatting helpers
# ============================================================

function _fmt_val(v)
    v isa Real ? _smart_round(v) : string(v)
end

function _smart_round(v::Real)
    av = abs(v)
    if av == 0
        "0.0"
    elseif av >= 100
        string(round(v; digits=1))
    elseif av >= 10
        string(round(v; digits=2))
    elseif av >= 1
        string(round(v; digits=3))
    else
        string(round(v; digits=4))
    end
end

function _fmt_range_cols(lower, upper)
    lo_ok = !ismissing(lower) && !isnan(lower)
    up_ok = !ismissing(upper) && !isnan(upper)
    (!lo_ok || !up_ok) && return "-"
    "($(_smart_round(lower)), $(_smart_round(upper)))"
end

function _fmt_loss(l::Float64)
    if l == 0.0
        "0.0"
    elseif l >= 100
        string(round(l; digits=1))
    else
        string(round(l; digits=4))
    end
end

function _fmt_status(in_range::Union{Bool, Nothing})
    isnothing(in_range) && return "-"
    in_range ? "OK" : "MISS"
end
