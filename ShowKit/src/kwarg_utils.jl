# ============================================================
# Keyword Argument Translation: Julia → R
# ============================================================

"""
    _julia_to_r_name(s::Symbol) -> String

Convert a Julia keyword name to an R argument name, using the ggplot2 dot
convention:
- Single underscores `_` become dots `.`  (axis_text_x → axis.text.x)
- Double underscores `__` become single underscores (my__var → my_var)

This is correct for ggplot2 and for the pmplots/mrggsave wrappers built on it.
It is *not* correct for pmtables — see `_pmtables_to_r_name`.
"""
function _julia_to_r_name(s::Symbol)
    str = string(s)
    # Protect double underscores first
    str = replace(str, "__" => "\x00")
    # Single underscores → dots
    str = replace(str, "_" => ".")
    # Restore protected underscores
    str = replace(str, "\x00" => "_")
    str
end

"""
    _pmtables_to_r_name(s::Symbol) -> String

Convert a Julia keyword name to an R argument or column name for pmtables.

pmtables' argument surface is snake_case throughout (`lt_cap_label`,
`note_config`, `escape_fun`, `cols_cont`, ...), and its keyword names double as
data frame column names, which are usually snake_case too. So underscores are
kept **literal** here. Applying the ggplot2 rule instead sends `lt_cap_label` as
`lt.cap.label`, which pmtables swallows into `...` without complaint — a silent
wrong result rather than an error.

The only pmtables names Julia cannot spell directly are the handful that begin
with a dot (`.default`, `.coltype`, `.complete`, `.outer`, `.list`, `.r`, `.c`,
`.l`). Write those with a leading underscore: `_default` → `.default`.

pmtables has exactly one argument with an interior dot (`path.type`, on
`st_files()`); it is not reachable by keyword and is not wrapped.
"""
_pmtables_to_r_name(s::Symbol) = replace(string(s), r"^_" => ".")

"""
    _pmtables_kwargs(kwargs) -> Vector{Pair{Symbol, Any}}

Translate Julia keyword arguments into pmtables R arguments: names via
`_pmtables_to_r_name`, values via `_convert_value`.
"""
function _pmtables_kwargs(kwargs)
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        push!(r_kwargs, Symbol(_pmtables_to_r_name(k)) => _convert_value(v))
    end
    return r_kwargs
end

"""
    _convert_value(v) -> Any

Convert Julia values to R-compatible values for rcall:
- GGPlot/GGLayer → extract .robject
- NamedTuple/Dict → named R list
- Symbol → R symbol via rlang::sym()
- Everything else → pass through (RCall handles conversion)
"""
function _r_named_list(pairs)
    r_list = _reval("list()")
    for (k, v) in pairs
        r_list = _rcall(Symbol("[[<-"), r_list, string(k), _convert_value(v))
    end
    return r_list
end

function _convert_value(v)
    if v isa GGPlot
        v.robject
    elseif v isa GGLayer
        v.robject
    elseif v isa PMTable
        v.robject
    elseif v isa DataFrame
        _robject(plot_data(v))
    elseif v isa NamedTuple
        _r_named_list(pairs(v))
    elseif v isa AbstractDict
        _r_named_list(v)
    else
        v
    end
end

"""
    _rcall_gg(r_fn_name::Symbol, pos_args::Tuple, kwargs) -> RObject

Call an R function by name with positional and keyword arguments.
Handles underscore→dot conversion for kwarg names and value conversion.
"""
function _rcall_gg(r_fn_name::Symbol, pos_args::Tuple, kwargs)
    _require_ggplot2()

    # Build the R function reference
    r_fn = _reval("ggplot2::$(r_fn_name)")

    # Convert positional args
    converted_pos = [_convert_value(a) for a in pos_args]

    # Convert keyword args: underscore→dot names, extract robjects
    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = Symbol(_julia_to_r_name(k))
        rval = _convert_value(v)
        push!(r_kwargs, rname => rval)
    end

    if isempty(r_kwargs) && isempty(converted_pos)
        _rcall(r_fn)
    elseif isempty(r_kwargs)
        _rcall(r_fn, converted_pos...)
    else
        _rcall(r_fn, converted_pos...; r_kwargs...)
    end
end

function _r_kwarg_name(k::Symbol; literal_kwargs=(), name_fun=_julia_to_r_name)
    return k in literal_kwargs ? k : Symbol(name_fun(k))
end

"""
    _rcall_pkg(pkg::String, r_fn_name::Symbol, pos_args, kwargs) -> RObject

Call a namespaced R function (e.g., "pmplots::dv_pred") with argument conversion.
Keyword names are translated with `name_fun`, which defaults to the ggplot2 dot
convention; pmtables call sites pass `_pmtables_to_r_name` instead.
"""
function _rcall_pkg(pkg::String, r_fn_name::Symbol, pos_args, kwargs;
        literal_kwargs=(), name_fun=_julia_to_r_name)
    r_fn = _reval("$(pkg)::$(r_fn_name)")

    converted_pos = [_convert_value(a) for a in pos_args]

    r_kwargs = Pair{Symbol, Any}[]
    for (k, v) in kwargs
        rname = _r_kwarg_name(k; literal_kwargs, name_fun)
        rval = _convert_value(v)
        push!(r_kwargs, rname => rval)
    end

    if isempty(r_kwargs) && isempty(converted_pos)
        _rcall(r_fn)
    elseif isempty(r_kwargs)
        _rcall(r_fn, converted_pos...)
    else
        _rcall(r_fn, converted_pos...; r_kwargs...)
    end
end
