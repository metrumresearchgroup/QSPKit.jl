# Generic helpers for immutable keyword-style configuration structs.

function config_values(config)
    names = fieldnames(typeof(config))
    values = ntuple(i -> getfield(config, names[i]), length(names))
    return NamedTuple{names}(values)
end

is_auto_provenance_field(name::Symbol) = endswith(String(name), "_auto")

function public_config_values(config;
                              provenance_field::Function=is_auto_provenance_field)
    names = Tuple(n for n in fieldnames(typeof(config)) if !provenance_field(n))
    values = ntuple(i -> getfield(config, names[i]), length(names))
    return NamedTuple{names}(values)
end

function replace_config(config; kwargs...)
    return typeof(config)(; merge(config_values(config), (; kwargs...))...)
end
