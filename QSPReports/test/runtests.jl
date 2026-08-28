using Test
using QSPReports
using DataFrames
using ConfigKit

@testset "QSPReports actions" begin
    action = report_action(:low, :data, :inspect, "Inspect data.", "Missing rows.")
    @test action == (
        priority=:low,
        category=:data,
        action=:inspect,
        message="Inspect data.",
        reason="Missing rows.",
    )

    actions = NamedTuple[]
    push_action!(actions, :medium, :fit, :inspect, "Inspect fit.", "Medium issue.")
    push_action!(actions, :high, :fit, :rerun, "Rerun fit.", "High issue.")
    push_action!(actions, :medium, :fit, :inspect, "Inspect fit.", "Duplicate.")

    @test length(actions) == 2
    ranked = rank_actions(actions)
    @test ranked[1].priority === :high
    @test ranked[1].rank == 1

    txt = sprint(io -> print_action_list(io, actions))
    @test occursin("[high] Rerun fit.", txt)
    @test occursin("[medium] Inspect fit.", txt)

    custom = report_action(:custom, :other, :review, "Review.", "Custom priority.")
    low = report_action(:low, :other, :review_low, "Review low.", "Known priority.")
    @test rank_actions([custom, low])[1].priority === :low
    @test isempty(rank_actions(actions; max_actions=0))
    @test_throws ArgumentError rank_actions(actions; max_actions=-1)
    @test_throws ArgumentError print_action_list(IOBuffer(), actions; max_actions=-1)

    pre_ranked = rank_actions(actions)
    ranked_txt = sprint(io -> print_action_list(io, pre_ranked; max_actions=1, indent="--"))
    @test startswith(ranked_txt, "--1. [high]")

    @test sprint(io -> print_section(io, "Diagnostics")) == "\nDiagnostics\n"
    @test sprint(io -> print_key_values(io, Pair[])) == ""
    @test sprint(io -> print_key_values(io, ["n" => 2, "mode" => :fast];
        indent="* ", separator="; ")) == "* n=2; mode=fast\n"
end

Base.@kwdef struct _ReportOptions
    n::Int = 10
    mode::Symbol = :auto
end

@testset "QSPReports option resolution" begin
    defaults = _ReportOptions()
    resolved = _ReportOptions(n=20)
    rows = option_resolution_rows(resolved, defaults; smart_replaced=Set([:mode]))
    @test rows[1] == (field=:n, value="20", provenance=:user)
    @test rows[2] == (field=:mode, value="auto", provenance=:smart)

    txt = sprint() do io
        print_option_resolution(io, "Options", resolved, defaults;
            smart_replaced=Set([:mode]))
    end
    @test occursin("Options", txt)
    @test occursin("n    = 20", txt)
    @test occursin("[smart]", txt)

    subset = option_resolution_rows(resolved, defaults;
        fields=(:n,), value_formatter=(field, value) -> "$(field):$(value)")
    @test subset == [(field=:n, value="n:20", provenance=:user)]

    defaults_only = option_resolution_rows(defaults, defaults)
    @test all(row.provenance === :default for row in defaults_only)
    @test sprint(io -> print_option_resolution(io, "Empty", resolved, defaults;
        fields=())) == "Empty\n"
end

Base.@kwdef struct _ParamEntry
    name::Symbol
    value
    unit = ""
    value_original = value
    metadata::Dict{Symbol, Any} = Dict{Symbol, Any}()
end

struct _ParamView
    data::Dict{Symbol, _ParamEntry}
end

Base.iterate(view::_ParamView, state...) = iterate(view.data, state...)

struct _Keyfile
    Parameters::_ParamView
    Variables::_ParamView
    Constants::_ParamView
end

struct _FitLike
    params::Dict{Symbol, Float64}
    loss::Float64
end

struct _EstimateLike
    estimates
    chosen
end

function _test_keyfile()
    _Keyfile(
        _ParamView(Dict(
            :K => _ParamEntry(
                name=:K,
                value=2.0,
                unit="1",
                metadata=Dict(:description => "Iteration gain", :source => "keyfile", :bounds => [0.1, 10.0]),
            ),
            :derived_scale => _ParamEntry(
                name=:derived_scale,
                value=4.25,
                value_original="base_level * scale_factor + offset",
                unit="1",
                metadata=Dict(:description => "Derived composite scale", :unit_original => "1"),
            ),
        )),
        _ParamView(Dict(
            :state_a => _ParamEntry(name=:state_a, value=0.0, unit="1"),
        )),
        _ParamView(Dict(
            :unit_scale => _ParamEntry(name=:unit_scale, value=8.0, unit="1"),
        )),
    )
end

_onlyrow(df, name) = only(eachrow(df[df.name .== name, :]))
_onlyrow(df, section, name) = only(eachrow(df[(df.section .== section) .& (df.name .== name), :]))

@testset "QSPReports parameter tables" begin
    kf = _test_keyfile()

    base = parameter_table(kf)
    @test nrow(base) == 4
    @test eltype(base.keyfile_value) === Any
    @test _onlyrow(base, :K).role === :parameter
    @test _onlyrow(base, :K).keyfile_value == 2.0
    @test _onlyrow(base, :K).lower == 0.1
    @test _onlyrow(base, :derived_scale).role === :derived_parameter
    expected = raw"$\mathrm{base\_level} \cdot \mathrm{scale\_factor} + \mathrm{offset}$"
    @test _onlyrow(base, :derived_scale).keyfile_value == expected
    @test _onlyrow(base, :derived_scale).expression == "base_level * scale_factor + offset"
    @test _onlyrow(base, :derived_scale).unit == "1"
    @test _onlyrow(base, :initials, :state_a).keyfile_initial == 0.0
    @test _onlyrow(base, :constants, :unit_scale).role === :constant

    plain = parameter_table(kf; latex=false)
    source_expression = "base_level * scale_factor + offset"
    @test _onlyrow(plain, :derived_scale).keyfile_value == source_expression
    @test _onlyrow(plain, :derived_scale).expression == source_expression
    latex_overlay = parameter_table(kf, Dict(:K => 2.4))
    @test _onlyrow(latex_overlay, :derived_scale).keyfile_value == expected
    @test _onlyrow(latex_overlay, :derived_scale).expression == source_expression

    metadata = parameter_metadata_overlay(Dict(
        "K" => Dict("source" => "overlay source", "group" => "controller"),
        "init[state_a]" => Dict("description" => "Initial synthetic state"),
    ))
    with_metadata = parameter_table(kf; metadata)
    @test _onlyrow(with_metadata, :K).source == "overlay source"
    @test _onlyrow(with_metadata, :K).source_source === :overlay
    @test _onlyrow(with_metadata, :K).group == "controller"
    @test _onlyrow(with_metadata, :initials, :state_a).description == "Initial synthetic state"

    update = parameter_update(
        parameters=(K=2.2,),
        initials=(state_a=4.0,),
        constants=(unit_scale=7.5,),
        label=:fit,
        source="fit.yml",
    )
    with_update = parameter_table(kf, update)
    @test _onlyrow(with_update, :K).fit_value == 2.2
    @test _onlyrow(with_update, :K).value_source == "fit.yml"
    @test _onlyrow(with_update, :initials, :state_a).fit_value == 4.0
    @test _onlyrow(with_update, :constants, :unit_scale).fit_value == 7.5

    with_dict = parameter_table(kf, Dict(:K => 2.4); overlay_name=:manual)
    @test _onlyrow(with_dict, :K).manual_value == 2.4

    result_like = _FitLike(Dict(:K => 2.5), 1.2)
    with_result = parameter_table(kf, result_like; overlay_name=:opt)
    @test _onlyrow(with_result, :K).opt_value == 2.5

    vector_update = optimization_update([2.6]; names=[:K], label=:vecfit)
    with_vector = parameter_table(kf, vector_update)
    @test _onlyrow(with_vector, :K).vecfit_value == 2.6

    omega = parameter_overlay(Dict(Symbol("sd[K]") => 0.3);
        section=:omega, label=:posterior, column=:posterior_median)
    with_omega = parameter_table(kf, omega)
    @test _onlyrow(with_omega, :omega, Symbol("sd[K]")).posterior_median == 0.3

    @test_throws ArgumentError parameter_table(kf; metadata_policy=:unknown)
end

@testset "QSPReports update and overlay APIs" begin
    @test parameter_key("K") == ParameterRowKey(:parameters, :K)
    @test initial_key(:K) == ParameterRowKey(:initials, :K)
    @test constant_key(:K) == ParameterRowKey(:constants, :K)
    keyed = Dict(parameter_key(:K) => 2.0)
    @test keyed[ParameterRowKey(:parameters, :K)] == 2.0

    update = model_update(
        parameters=Dict("K" => 2.1),
        initials=(state_a=3.0,),
        constants=["unit_scale" => 7.5],
        label=:calibrated,
        source=:fit,
        metadata=Dict("method" => "MLE"),
    )
    @test update isa ParameterUpdate
    @test update.parameters == Dict{Symbol, Any}(:K => 2.1)
    @test update.initials[:state_a] == 3.0
    @test update.constants[:unit_scale] == 7.5
    @test update.label === :calibrated
    @test update.source == "fit"
    @test update.metadata[:method] == "MLE"
    @test parameter_update(parameters=(K=1.0,)).parameters[:K] == 1.0
    @test ParameterUpdate(initials=(state_a=2.0,)).initials[:state_a] == 2.0

    named = optimization_update((K=3.0, V=4.0); label=:named)
    @test named.parameters == Dict{Symbol, Any}(:K => 3.0, :V => 4.0)
    estimates = _EstimateLike([2.0, 5.0], [4.0, 8.0])
    from_estimates = optimization_update(estimates; names=[:K, :V])
    @test from_estimates.parameters[:V] == 5.0
    from_field = optimization_update(estimates;
        names=[:state_a, :state_b], section=:initials, value_field=:chosen,
        transform=x -> x / 2)
    @test from_field.initials == Dict{Symbol, Any}(:state_a => 2.0, :state_b => 4.0)
    as_constants = optimization_update(Dict(:unit_scale => 9.0); section=:constants)
    @test as_constants.constants[:unit_scale] == 9.0
    @test_throws ErrorException optimization_update([1.0, 2.0])
    @test_throws ErrorException optimization_update([1.0, 2.0]; names=[:K])
    @test_throws ErrorException optimization_update(estimates; value_field=:absent)
    @test_throws ErrorException optimization_update(Dict(:K => 1.0); section=:omega)

    overlay = parameter_overlay((K=7.0,); label=:manual, column=:chosen_value)
    @test overlay isa ParameterOverlay
    @test overlay.label === :manual
    @test only(overlay.rows).chosen_value == 7.0
    @test only(overlay.rows).value_source === :manual
    fit_overlay = parameter_overlay(estimates;
        names=[:K, :V], value_field=:chosen, transform=x -> x + 1)
    @test length(fit_overlay.rows) == 2
    @test Set(row.estimate_value for row in fit_overlay.rows) == Set([5.0, 9.0])
end

@testset "QSPReports metadata and merge policies" begin
    kf = _test_keyfile()
    metadata = parameter_metadata_overlay(Dict(
        "parameters:K" => Dict("source" => "curated", "group" => "controller"),
        "constant[unit_scale]" => (description="Dimensionless scale",),
    ); state_a=(description="Initial synthetic state",))
    @test metadata[parameter_key(:K)].source == "curated"
    @test metadata[constant_key(:unit_scale)].description == "Dimensionless scale"
    @test metadata[:state_a].description == "Initial synthetic state"
    @test_throws ErrorException parameter_metadata_overlay(Dict(:K => 1.0))

    preferred = parameter_table(kf; metadata)
    @test _onlyrow(preferred, :K).source == "curated"
    @test _onlyrow(preferred, :K).source_source === :overlay
    @test _onlyrow(preferred, :constants, :unit_scale).description == "Dimensionless scale"
    @test _onlyrow(preferred, :initials, :state_a).description == "Initial synthetic state"

    filled = parameter_table(kf; metadata, metadata_policy=:fill_missing)
    @test _onlyrow(filled, :K).source == "keyfile"
    @test _onlyrow(filled, :initials, :state_a).description == "Initial synthetic state"
    @test_throws ErrorException parameter_table(
        kf; metadata, metadata_policy=:error_on_conflict)
    @test_throws ArgumentError parameter_table(kf; metadata_policy=:not_a_policy)

    appended = parameter_table(kf, Dict(:new_parameter => 9.0))
    @test _onlyrow(appended, :parameters, :new_parameter).updated_value == 9.0
    dropped = parameter_table(kf, Dict(:new_parameter => 9.0); unmatched=:drop)
    @test :new_parameter ∉ dropped.name
    @test_logs (:warn, r"Dropping unmatched parameter overlay row") parameter_table(
        kf, Dict(:new_parameter => 9.0); unmatched=:warn)
    @test_throws ErrorException parameter_table(
        kf, Dict(:new_parameter => 9.0); unmatched=:error)
    @test_throws ArgumentError parameter_table(
        kf, Dict(:new_parameter => 9.0); unmatched=:invalid)

    malformed = ParameterOverlay(NamedTuple[(value=1.0,)], :bad)
    @test_throws ErrorException parameter_table(kf, malformed)
    @test nrow(parameter_table(kf; sections=:parameters)) == 2
    @test Set(parameter_table(kf; sections=[:initials, :constants]).section) ==
          Set([:initials, :constants])
end

@testset "QSPReports variant parameter tables" begin
    mktempdir() do dir
        path = joinpath(dir, "variants.yml")
        write(path, """
Parameters:
  mixing_weight:
    variants:
      compact:
        value: 0.25
        source: source A
      expanded:
        value: 0.75
        source: source B
    unit: "1"
    description: Mixing coefficient
  branch_count:
    variants:
      compact:
        value: 3
        source: source C
      expanded:
        value: 8
        source: source D
    unit: "1"
    description: Synthetic branch count
  same_variant:
    variants:
      compact: 7
      expanded: 7
    unit: "1"
  shared:
    value: 3
    unit: "1"
    source: shared source
""")

        table = parameter_table(
            path;
            variants=[:expanded, :compact],
        )
        @test table.name == [:branch_count, :branch_count, :mixing_weight, :mixing_weight]
        @test table.variant ==
              [:expanded, :compact, :expanded, :compact]
        @test table.value == [8, 3, 0.75, 0.25]
        @test table.source == ["source D", "source C", "source B", "source A"]

        selected = parameter_table(
            path;
            variants=[:compact, :expanded],
            names=[:mixing_weight],
            only_different=false,
        )
        @test selected.name == [:mixing_weight, :mixing_weight]
        @test selected.variant == [:compact, :expanded]

        loaded = ConfigKit.load_keyfile(path; variant=:compact)
        default_loaded = parameter_table(loaded)
        @test Set(default_loaded.name) == Set([:mixing_weight, :branch_count, :same_variant, :shared])
        from_loaded = parameter_table(
            loaded;
            sections=:parameters,
            names=[:mixing_weight],
            only_different=false,
        )
        @test from_loaded == selected

        from_path = parameter_table(
            path;
            names=[:mixing_weight],
            only_different=false,
        )
        @test from_path == selected

        wide = parameter_table(
            loaded;
            names=[:mixing_weight, :branch_count],
            wide=true,
        )
        @test wide.name == [:branch_count, :mixing_weight]
        @test names(wide) == [
            "name", "unit", "description",
            "compact_value", "compact_source",
            "expanded_value", "expanded_source",
        ]
        @test wide.compact_value == [3, 0.25]
        @test wide.expanded_value == [8, 0.75]
        @test wide.compact_source == ["source C", "source A"]
        @test wide.expanded_source == ["source D", "source B"]

        empty_wide = parameter_table(
            loaded;
            names=[:not_present],
            wide=true,
        )
        @test nrow(empty_wide) == 0
        @test names(empty_wide) == names(wide)

        inconsistent = DataFrame(
            name=[:mixing_weight, :mixing_weight],
            variant=[:compact, :expanded],
            value=[0.25, 0.75],
            unit=["1", "1"],
            description=["Coefficient A", "Coefficient B"],
            source=["source A", "source B"],
        )
        @test_throws ArgumentError QSPReports._wide_variant_parameter_table(
            inconsistent,
            [:compact, :expanded],
        )

        @test_throws ArgumentError parameter_table(
            path;
            variants=[:compact],
        )
        @test_throws ArgumentError parameter_table(
            path;
            variants=[:compact, :compact],
        )
        @test_throws ArgumentError parameter_table(
            path;
            variants=[:compact, :expanded],
            sections=:all,
        )
        @test :same_variant ∉ table.name
        @test :shared ∉ table.name
    end
end

@testset "QSPReports saved parameter updates" begin
    update = parameter_update(
        parameters=(K=2.2,),
        initials=(state_a=4.0,),
        constants=(unit_scale=7.5,),
        label=:fit,
        source="fit-source",
        metadata=(objective="least-squares",),
    )
    mktempdir() do dir
        path = joinpath(dir, "fit_update.yml")
        @test save_parameter_update(path, update) == path
        loaded = load_parameter_update(path)
        @test loaded.label === :fit
        @test loaded.parameters[:K] == 2.2
        @test loaded.initials[:state_a] == 4.0
        @test loaded.constants[:unit_scale] == 7.5
        @test loaded.source == "fit-source"
        @test loaded.metadata[:objective] == "least-squares"

        legacy = joinpath(dir, "legacy.yml")
        write(legacy, "label: legacy\nvalues:\n  K:\n    value: 3.1\n")
        legacy_update = load_parameter_update(legacy)
        @test legacy_update.label === :legacy
        @test legacy_update.parameters[:K] == 3.1

        invalid_update = joinpath(dir, "invalid-update.yml")
        write(invalid_update, "- 1\n- 2\n")
        @test_throws ErrorException load_parameter_update(invalid_update)

        metadata_path = joinpath(dir, "metadata.yml")
        write(metadata_path, "\"parameters:K\":\n  source: curated\ninit[state_a]:\n  description: Initial synthetic state\n")
        metadata = load_parameter_metadata(metadata_path)
        @test metadata[parameter_key(:K)].source == "curated"
        @test metadata[initial_key(:state_a)].description == "Initial synthetic state"

        invalid_metadata = joinpath(dir, "invalid-metadata.yml")
        write(invalid_metadata, "- invalid\n")
        @test_throws ErrorException load_parameter_metadata(invalid_metadata)
    end
end
