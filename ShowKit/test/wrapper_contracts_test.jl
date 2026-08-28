const _SHOWKIT_MOCK_AVAILABILITY_REFS = (
    ShowKit._RCALL_AVAILABLE,
    ShowKit._GGPLOT2_AVAILABLE,
    ShowKit._GGPLOT2_CHECKED,
    ShowKit._PMPLOTS_AVAILABLE,
    ShowKit._PMPLOTS_CHECKED,
    ShowKit._PMTABLES_AVAILABLE,
    ShowKit._PMTABLES_CHECKED,
    ShowKit._MRGGSAVE_AVAILABLE,
    ShowKit._MRGGSAVE_CHECKED,
    ShowKit._VPC_AVAILABLE,
    ShowKit._VPC_CHECKED,
    ShowKit._NPDE_AVAILABLE,
    ShowKit._NPDE_CHECKED,
    ShowKit._ST2PNG_AVAILABLE,
    ShowKit._ST2PNG_CHECKED,
)

const _SHOWKIT_MOCK_FUNCTION_REFS = (
    ShowKit._rcopy_fn,
    ShowKit._reval_fn,
    ShowKit._rcall_fn,
    ShowKit._robject_fn,
)

struct _ShowKitMockRObject
    kind::Symbol
    value::Any
end

"""Run a test against a deterministic in-memory stand-in for the R boundary."""
function _with_mock_showkit_r(f::Function)
    refs = (_SHOWKIT_MOCK_AVAILABILITY_REFS..., _SHOWKIT_MOCK_FUNCTION_REFS...)
    saved = map(ref -> ref[], refs)
    calls = Any[]
    try
        foreach(ref -> ref[] = true, _SHOWKIT_MOCK_AVAILABILITY_REFS)

        ShowKit._reval_fn[] = function(code)
            value = String(code)
            push!(calls, (kind=:reval, value=value))
            return _ShowKitMockRObject(:reval, value)
        end
        ShowKit._robject_fn[] = function(value)
            push!(calls, (kind=:robject, value=value))
            return _ShowKitMockRObject(:robject, value)
        end
        ShowKit._rcall_fn[] = function(args...; kwargs...)
            call = (
                kind=:rcall,
                args=args,
                kwargs=Dict{Symbol,Any}(kwargs),
                index=length(calls) + 1,
            )
            push!(calls, call)
            return _ShowKitMockRObject(:rcall, call.index)
        end
        ShowKit._rcopy_fn[] = function(target, value)
            push!(calls, (kind=:rcopy, target=target, value=value))
            target === Bool && return true
            target === Int && return 1
            target === Float64 && return 0.0
            target === String && return "mock"
            target === Vector{String} && return ["mock"]
            target === DataFrame && return DataFrame(id=[1], xobs=[0.0], npde=[0.0])
            error("unsupported mock R conversion to $target")
        end

        return f(calls)
    finally
        for (ref, value) in zip(refs, saved)
            ref[] = value
        end
    end
end

_showkit_reval_seen(calls, value) =
    any(call -> call.kind === :reval && call.value == value, calls)

@testset "Generated wrapper contracts" begin
    generated_ggplot = vcat(
        ShowKit.GEOM_FUNCTIONS,
        ShowKit.SCALE_FUNCTIONS,
        ShowKit.COORD_FUNCTIONS,
        ShowKit.STAT_FUNCTIONS,
        ShowKit.POSITION_FUNCTIONS,
        ShowKit.GUIDE_FUNCTIONS,
        ShowKit.MISC_FUNCTIONS,
        ShowKit.THEME_PRESETS,
    )
    @test length(generated_ggplot) == length(unique(generated_ggplot))

    _with_mock_showkit_r() do calls
        for name in generated_ggplot
            empty!(calls)
            wrapper = getfield(ShowKit, name)
            layer = wrapper(:sentinel; line_width=2)
            @test layer isa GGLayer
            @test layer.name === name
            @test _showkit_reval_seen(calls, "ggplot2::$name")
            r_call = only(filter(call -> call.kind === :rcall, calls))
            @test r_call.args[2] === :sentinel
            @test r_call.kwargs[Symbol("line.width")] == 2
        end
    end

    diagnostic_plots = vcat(
        ShowKit.PMPLOTS_DV_FUNCTIONS,
        ShowKit.PMPLOTS_RESID_FUNCTIONS,
        ShowKit.PMPLOTS_WRAP_FUNCTIONS,
        ShowKit.PMPLOTS_COVARIATE_FUNCTIONS,
    )
    @test length(diagnostic_plots) == length(unique(diagnostic_plots))
    data = DataFrame(x=[1.0, 2.0], y=[2.0, 4.0])

    _with_mock_showkit_r() do calls
        for name in diagnostic_plots
            empty!(calls)
            plot = getfield(ShowKit, name)(data; x="x//Synthetic input")
            @test plot isa GGPlot
            @test _showkit_reval_seen(calls, "pmplots::$name")
        end

        for name in ShowKit.PMPLOTS_DV_LIST_FUNCTIONS
            empty!(calls)
            plots = getfield(ShowKit, name)(data)
            @test plots isa Vector{GGPlot}
            @test length(plots) == 1
            @test _showkit_reval_seen(calls, "pmplots::$name")
        end

        for name in ShowKit.PMPLOTS_ETA_FUNCTIONS
            empty!(calls)
            plot = getfield(ShowKit, name)(data; tag_levels="A")
            @test plot isa GGPlot
            @test _showkit_reval_seen(calls, "pmplots::$name")
            package_call = first(filter(call ->
                call.kind === :rcall && haskey(call.kwargs, :tag_levels), calls))
            @test package_call.kwargs[:tag_levels] == "A"
        end
    end

    _with_mock_showkit_r() do calls
        for name in ShowKit.VPC_FUNCTIONS
            empty!(calls)
            plot = getfield(ShowKit, name)(; sim=data, pred_corr=true)
            @test plot isa GGPlot
            @test _showkit_reval_seen(calls, "vpc::$name")
            package_call = only(filter(call -> call.kind === :rcall, calls))
            @test haskey(package_call.kwargs, :sim)
            @test package_call.kwargs[Symbol("pred.corr")] === true
        end
    end
end

@testset "Export inventory is callable" begin
    inventory_path = normpath(joinpath(
        @__DIR__, "..", "..", "validation", "exports-ShowKit.txt"))
    expected = Symbol[]
    for line in eachline(inventory_path)
        entry = strip(first(split(line, '#'; limit=2)))
        isempty(entry) || push!(expected, Symbol(entry))
    end
    @test length(expected) == 328
    @test length(expected) == length(unique(expected))
    for name in expected
        @test isdefined(ShowKit, name)
        value = getfield(ShowKit, name)
        @test value isa Function || value isa DataType
        value isa Function && @test !isempty(methods(value))
    end
end

@testset "Manual R-boundary routing" begin
    data = DataFrame(x=[1.0, 2.0], y=[2.0, 4.0])
    _with_mock_showkit_r() do calls
        mapping = aes(x=:x, y=:y)
        @test mapping isa GGLayer
        @test mapping.columns == [:x, :y]
        @test ggplot(data, mapping) isa GGPlot
        @test ggplot(data) isa GGPlot
        @test ggplot() isa GGPlot

        @test theme(axis_text_x=element_text(angle=45)) isa GGLayer
        @test element_blank() !== nothing
        @test element_rect(fill="white") !== nothing
        @test element_line(linewidth=1) !== nothing
        @test facet_wrap(:group; ncol=2) isa GGLayer
        @test facet_wrap([:group, :arm]) isa GGLayer
        @test facet_grid(:group, :arm) isa GGLayer
        @test labs(x="Input", y="Output") isa GGLayer
        @test xlab("Input") isa GGLayer
        @test ylab("Output") isa GGLayer
        @test ggtitle("Synthetic plot"; subtitle="contract") isa GGLayer
        @test gg(:custom_layer; alpha=0.5) isa GGLayer
        @test r_gg(:custom_layer; alpha=0.25) isa GGLayer
        @test r_gg === gg
        @test factor(:group; levels=[1, 2], ordered=true) !== nothing

        for name in (
            :st_new,
            :pt_cont_wide,
            :pt_cont_long,
            :pt_cat_wide,
            :pt_cat_long,
            :pt_demographics,
            :pt_data_inventory,
        )
            @test getfield(ShowKit, name)(data) isa PMTable
        end

        table = PMTable(_ShowKitMockRObject(:table, nothing))
        @test st_units(table; x="unit") isa PMTable
        @test st_notes(table, "Synthetic note") isa PMTable
        @test st_caption(table, "Synthetic caption") isa PMTable
        @test st_files(table; output="table.tex") isa PMTable
        @test st_panel(table, :x) isa PMTable
        @test st_align(table; _default="l") isa PMTable
        @test st_center(table; x="c") isa PMTable
        @test st_blank(table, :x) isa PMTable
        @test st_noteconf(table; width=0.8) isa PMTable
        @test st_span_split(table; split="_") isa PMTable
        @test st_as_image(table) !== nothing
        @test st_span(table, "Group"; x=:x) isa PMTable
        @test st_rename(table; x="Input") isa PMTable
        @test st_bold(table; x=true) isa PMTable
        @test st_clear_reps(table, :x) isa PMTable
        @test st_clear_grouped(table, :x, :y) isa PMTable
        @test col_fixed(2.0) !== nothing
        @test col_ragged(2.0) !== nothing
        @test tab_clear_reps(data, :x) isa DataFrame
        @test stable(table) isa LaTeXTable
        @test stable_long(table) isa LaTeXTable
        @test stable_save(table; file="table.tex") === table

        mktempdir() do temp_dir
            cd(temp_dir) do
                # The fake R boundary reports this local file as the converted
                # page.  The contract checks ShowKit's path handling and both
                # exported table overloads without requiring TeX in unit tests.
                open("mock", "w") do io
                    write(io, "synthetic-png-payload")
                end
                pm_path = joinpath(temp_dir, "pm-table.png")
                latex_path = joinpath(temp_dir, "latex-table.png")
                @test st2png(table, pm_path; dpi=144) == pm_path
                @test read(pm_path, String) == "synthetic-png-payload"
                @test st2png(LaTeXTable("a & b"), latex_path) == latex_path
                @test read(latex_path, String) == "synthetic-png-payload"
                @test _showkit_reval_seen(calls, "pdftools::pdf_convert")
            end
        end

        @test pm_grid([GGPlot(_ShowKitMockRObject(:plot, nothing))]) isa GGPlot
        @test mrggsave(
            GGPlot(_ShowKitMockRObject(:plot, nothing)),
            "synthetic-plot";
            script="wrapper_contracts_test.jl",
        ) === nothing
        @test mrggsave_list(
            [GGPlot(_ShowKitMockRObject(:plot, nothing))];
            stems=["synthetic-plot"],
            script="wrapper_contracts_test.jl",
        ) === nothing

        obs = DataFrame(id=[1], time=[0.0], dv=[1.0])
        sim = DataFrame(id=[1], time=[0.0], dv=[1.1])
        result = autonpde(obs, sim)
        @test result isa DataFrame
        @test names(result) == ["id", "x", "NPDE"]
        @test _showkit_reval_seen(calls, "npde::autonpde")

        residuals = DataFrame(ID=[1], TIME=[0.0], MODE=[:nominal])
        predictive = DataFrame(
            ID=[1, 1],
            TIME=[0.0, 0.0],
            MODE=[:nominal, :nominal],
            OBSERVED=[0.75, 0.75],
            REPLICATE=[0.70, 0.82],
            DRAW=[1, 2],
        )
        @test add_npde!(
            residuals,
            predictive;
            by=:MODE,
            dv=:OBSERVED,
            dvrep=:REPLICATE,
        ) === residuals
        @test residuals.NPDE == [0.0]
    end
end

@testset "Pure data-boundary contracts" begin
    original = DataFrame(
        ID=Union{Missing,Int}[1, missing],
        SEX=[:group_a, :group_b],
        VALUE=[1.5, 2.5],
    )
    prepared = plot_data(original)
    @test isequal(prepared.ID, Union{Missing,String}["1", missing])
    @test prepared.SEX == ["group_a", "group_b"]
    @test prepared.VALUE == original.VALUE
    @test isequal(original.ID, Union{Missing,Int}[1, missing])
    @test original.SEX == [:group_a, :group_b]

    coded_column = (
        short="Group",
        label="Synthetic group",
        unit=nothing,
        values=Dict(1 => "Control", 2 => "Treatment"),
    )
    spec = (columns=Dict(:GROUP => coded_column),)
    coded = DataFrame(GROUP=Union{Missing,Int}[1, 2, missing, 9])
    decoded = ys_factors(coded, spec, :GROUP)
    @test isequal(decoded.GROUP, Union{Missing,String}[
        "Control", "Treatment", missing, "9",
    ])
    @test isequal(coded.GROUP, Union{Missing,Int}[1, 2, missing, 9])
    @test ys_factors!(coded, spec, [:GROUP]) === coded
    @test isequal(coded.GROUP, decoded.GROUP)

    @test ShowKit._split_pmplots_col_label("DV//Observed value") ==
          ("DV", "Observed value")
    @test ShowKit._split_pmplots_col_label("DV") == ("DV", nothing)
    normalized, label = ShowKit._pmplots_diagnostic_kwargs(
        :cwres_q,
        pairs((y="CWRES//Residual quantile", color="group")),
    )
    @test normalized == [:x => "CWRES", :color => "group"]
    @test label == "Residual quantile"

    generated = list_plot_x(
        DataFrame(value=[1.0]),
        (df; x) -> (nrow(df), x),
        ["a", "b"],
    )
    @test generated == [(1, "a"), (1, "b")]
end
