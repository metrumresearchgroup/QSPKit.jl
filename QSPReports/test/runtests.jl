using Test
using QSPKit.QSPReports
using DataFrames
using QSPKit.ConfigKit

@testset "QSPReports actions" begin
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

function _test_keyfile()
    _Keyfile(
        _ParamView(Dict(
            :K => _ParamEntry(
                name=:K,
                value=2.0,
                unit="1/d",
                metadata=Dict(:description => "Elimination rate", :source => "keyfile", :bounds => [0.1, 10.0]),
            ),
            :Vp => _ParamEntry(
                name=:Vp,
                value=3.5,
                value_original="0.5 * (4 * pi * (tum_diam / 2)^2)",
                unit="L",
                metadata=Dict(:description => "Peripheral volume", :unit_original => "mL"),
            ),
        )),
        _ParamView(Dict(
            :Ap => _ParamEntry(name=:Ap, value=0.0, unit="mg"),
        )),
        _ParamView(Dict(
            :MW => _ParamEntry(name=:MW, value=150000.0, unit="g/mol"),
        )),
    )
end

_onlyrow(df, name) = only(eachrow(df[df.name .== name, :]))
_onlyrow(df, section, name) = only(eachrow(df[(df.section .== section) .& (df.name .== name), :]))

@testset "QSPReports parameter tables" begin
    kf = _test_keyfile()

    base = parameter_table(kf)
    @test nrow(base) == 4
    @test _onlyrow(base, :K).role === :parameter
    @test _onlyrow(base, :K).keyfile_value == 2.0
    @test _onlyrow(base, :K).lower == 0.1
    @test _onlyrow(base, :Vp).role === :derived_parameter
    expected = raw"$0.5 \cdot 4 \cdot \pi \cdot {\frac{\mathrm{tum\_diam}}{2}}^{2}$"
    @test _onlyrow(base, :Vp).keyfile_value == expected
    @test _onlyrow(base, :Vp).expression == "0.5 * (4 * pi * (tum_diam / 2)^2)"
    @test _onlyrow(base, :Vp).unit == "mL"
    @test _onlyrow(base, :initials, :Ap).keyfile_initial == 0.0
    @test _onlyrow(base, :constants, :MW).role === :constant

    plain = parameter_table(kf; latex=false)
    source_expression = "0.5 * (4 * pi * (tum_diam / 2)^2)"
    @test _onlyrow(plain, :Vp).keyfile_value == source_expression
    @test _onlyrow(plain, :Vp).expression == source_expression
    latex_overlay = parameter_table(kf, Dict(:K => 2.4))
    @test _onlyrow(latex_overlay, :Vp).keyfile_value == expected
    @test _onlyrow(latex_overlay, :Vp).expression == source_expression

    metadata = parameter_metadata_overlay(Dict(
        "K" => Dict("source" => "overlay source", "group" => "FcRn"),
        "init[Ap]" => Dict("description" => "Initial peripheral amount"),
    ))
    with_metadata = parameter_table(kf; metadata)
    @test _onlyrow(with_metadata, :K).source == "overlay source"
    @test _onlyrow(with_metadata, :K).source_source === :overlay
    @test _onlyrow(with_metadata, :K).group == "FcRn"
    @test _onlyrow(with_metadata, :initials, :Ap).description == "Initial peripheral amount"

    update = parameter_update(
        parameters=(K=2.2,),
        initials=(Ap=4.0,),
        constants=(MW=149000.0,),
        label=:fit,
        source="fit.yml",
    )
    with_update = parameter_table(kf, update)
    @test _onlyrow(with_update, :K).fit_value == 2.2
    @test _onlyrow(with_update, :K).value_source == "fit.yml"
    @test _onlyrow(with_update, :initials, :Ap).fit_value == 4.0
    @test _onlyrow(with_update, :constants, :MW).fit_value == 149000.0

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
end

@testset "QSPReports variant parameter tables" begin
    mktempdir() do dir
        path = joinpath(dir, "variants.yml")
        write(path, """
Parameters:
  KD:
    variants:
      antibody_a:
        value: 10
        source: source A
      antibody_b:
        value: 25
        source: source B
    unit: nM
    description: Binding affinity
  target_per_cell:
    variants:
      antibody_a:
        value: 1000
        source: source C
      antibody_b:
        value: 5000
        source: source D
    unit: "1"
    description: Target abundance
  same_variant:
    variants:
      antibody_a: 7
      antibody_b: 7
    unit: "1"
  shared:
    value: 3
    unit: L
    source: shared source
""")

        table = parameter_table(
            path;
            variants=[:antibody_b, :antibody_a],
        )
        @test table.name == [:KD, :KD, :target_per_cell, :target_per_cell]
        @test table.variant ==
              [:antibody_b, :antibody_a, :antibody_b, :antibody_a]
        @test table.value == [25, 10, 5000, 1000]
        @test table.source == ["source B", "source A", "source D", "source C"]

        selected = parameter_table(
            path;
            variants=[:antibody_a, :antibody_b],
            names=[:KD],
            only_different=false,
        )
        @test selected.name == [:KD, :KD]
        @test selected.variant == [:antibody_a, :antibody_b]

        loaded = ConfigKit.load_keyfile(path; variant=:antibody_a)
        from_loaded = parameter_table(
            loaded;
            sections=:parameters,
            names=[:KD],
            only_different=false,
        )
        @test from_loaded == selected

        from_path = parameter_table(
            path;
            names=[:KD],
            only_different=false,
        )
        @test from_path == selected

        wide = parameter_table(
            loaded;
            names=[:KD, :target_per_cell],
            wide=true,
        )
        @test wide.name == [:KD, :target_per_cell]
        @test names(wide) == [
            "name", "unit", "description",
            "antibody_a_value", "antibody_a_source",
            "antibody_b_value", "antibody_b_source",
        ]
        @test wide.antibody_a_value == [10, 1000]
        @test wide.antibody_b_value == [25, 5000]
        @test wide.antibody_a_source == ["source A", "source C"]
        @test wide.antibody_b_source == ["source B", "source D"]

        empty_wide = parameter_table(
            loaded;
            names=[:not_present],
            wide=true,
        )
        @test nrow(empty_wide) == 0
        @test names(empty_wide) == names(wide)

        inconsistent = DataFrame(
            name=[:KD, :KD],
            variant=[:antibody_a, :antibody_b],
            value=[10, 25],
            unit=["nM", "nM"],
            description=["Affinity A", "Affinity B"],
            source=["source A", "source B"],
        )
        @test_throws ArgumentError QSPReports._wide_variant_parameter_table(
            inconsistent,
            [:antibody_a, :antibody_b],
        )

        @test_throws ArgumentError parameter_table(
            path;
            variants=[:antibody_a],
        )
    end
end

@testset "QSPReports saved parameter updates" begin
    update = parameter_update(parameters=(K=2.2,), initials=(Ap=4.0,), label=:fit)
    mktempdir() do dir
        path = joinpath(dir, "fit_update.yml")
        save_parameter_update(path, update)
        loaded = load_parameter_update(path)
        @test loaded.label === :fit
        @test loaded.parameters[:K] == 2.2
        @test loaded.initials[:Ap] == 4.0
    end
end
