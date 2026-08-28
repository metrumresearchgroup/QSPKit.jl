using Test
using ShowKit
using DataFrames

@testset "ShowKit" begin

    @testset "Types" begin
        # GGPlot, GGLayer, PMTable, LaTeXTable can be constructed
        p = GGPlot(nothing)
        l = GGLayer(nothing, :geom_point)
        t = PMTable(nothing)
        lt = LaTeXTable("\\begin{tabular}{ll}\na & b\\\\\n\\end{tabular}")

        @test p isa GGPlot
        @test l isa GGLayer
        @test t isa PMTable
        @test lt isa LaTeXTable
        @test lt.latex isa String
    end

    @testset "Display (text)" begin
        p = GGPlot(nothing)
        l = GGLayer(nothing, :geom_point)
        t = PMTable(nothing)
        lt = LaTeXTable("line1\nline2\nline3")

        @test sprint(show, p) == "GGPlot(...)"
        @test sprint(show, l) == "GGLayer(:geom_point)"
        @test sprint(show, t) == "PMTable(...)"
        @test sprint(show, lt) == "LaTeXTable(3 lines)"
    end

    @testset "pmtables DataFrame preparation" begin
        original = DataFrame(
            name=[:mixing_weight, :mixing_weight, :branch_count],
            variant=Union{Missing, Symbol}[:compact, missing, :expanded],
            value=[0.25, 0.75, 3.0],
        )
        prepared = ShowKit._prepare_pmtable_data(original)

        @test prepared.name == ["mixing_weight", "mixing_weight", "branch_count"]
        @test isequal(
            prepared.variant,
            Union{Missing, String}["compact", missing, "expanded"],
        )
        @test prepared.value == original.value
        @test original.name == [:mixing_weight, :mixing_weight, :branch_count]
    end

    @testset "Display (rich)" begin
        t = PMTable(nothing)
        lt = LaTeXTable("line1\nline2\nline3")

        @test showable(MIME("image/png"), t) == ShowKit._RCALL_AVAILABLE[]
        @test showable(MIME("image/png"), lt) == ShowKit._RCALL_AVAILABLE[]
        @test hasmethod(show, Tuple{IO, MIME"image/png", PMTable})
        @test hasmethod(show, Tuple{IO, MIME"image/png", LaTeXTable})
    end

    @testset "LaTeXTable stable reconstruction" begin
        lt = LaTeXTable("line1\nline2\n")
        if ShowKit._RCALL_AVAILABLE[]
            r_stable = ShowKit._as_r_stable(lt)
            inherits_stable = ShowKit._rcopy(
                Bool,
                ShowKit._rcall(ShowKit._reval("inherits"), r_stable, "stable"),
            )
            @test inherits_stable
            @test ShowKit._rcopy(Vector{String}, r_stable) == ["line1", "line2", ""]
        end
    end

    @testset "LaTeX text caret escaping" begin
        escape_carets = ShowKit._escape_text_carets
        @test escape_carets("cm^2") == "cm\\textasciicircum{}2"
        @test escape_carets("x^2 and y^3") ==
              "x\\textasciicircum{}2 and y\\textasciicircum{}3"
        @test escape_carets(raw"$x^2$ and cm^2") ==
              raw"$x^2$ and cm\textasciicircum{}2"
        @test escape_carets(raw"already \^ escaped") == raw"already \^ escaped"
    end

    @testset "Kwarg conversion" begin
        # Test underscore → dot conversion
        @test ShowKit._julia_to_r_name(:axis_text_x) == "axis.text.x"
        @test ShowKit._julia_to_r_name(:legend_position) == "legend.position"
        @test ShowKit._julia_to_r_name(:simple) == "simple"

        # Double underscore → single underscore (escape hatch)
        @test ShowKit._julia_to_r_name(:my__var) == "my_var"
        @test ShowKit._julia_to_r_name(:panel__bg) == "panel_bg"

        # Mixed
        @test ShowKit._julia_to_r_name(:axis__text_x) == "axis_text.x"

        # Package wrappers can preserve selected R kwargs that really use underscores.
        @test ShowKit._r_kwarg_name(:tag_levels; literal_kwargs=(:tag_levels,)) == :tag_levels
        @test ShowKit._r_kwarg_name(:legend_position; literal_kwargs=(:tag_levels,)) == Symbol("legend.position")
    end

    @testset "pmtables kwarg conversion" begin
        # pmtables is snake_case throughout, so underscores stay literal. Sending
        # `lt.cap.label` instead would be swallowed by pmtables' `...` in silence.
        @test ShowKit._pmtables_to_r_name(:lt_cap_label) == "lt_cap_label"
        @test ShowKit._pmtables_to_r_name(:note_config) == "note_config"
        @test ShowKit._pmtables_to_r_name(:cols_cont) == "cols_cont"
        @test ShowKit._pmtables_to_r_name(:simple) == "simple"

        # Keyword names double as column names, which are often snake_case too.
        @test ShowKit._pmtables_to_r_name(:keyfile_value) == "keyfile_value"

        # A leading underscore is the only translation: Julia cannot spell
        # pmtables' dot-prefixed arguments (.default, .coltype, ...).
        @test ShowKit._pmtables_to_r_name(:_default) == ".default"
        @test ShowKit._pmtables_to_r_name(:_coltype) == ".coltype"
        @test ShowKit._pmtables_to_r_name(:_complete) == ".complete"
        # ...and only the leading one.
        @test ShowKit._pmtables_to_r_name(:_note_config) == ".note_config"

        # ggplot2 mapping is untouched by all of this.
        @test ShowKit._julia_to_r_name(:lt_cap_label) == "lt.cap.label"

        # _rcall_pkg routes pmtables call sites through the pmtables mapper.
        @test ShowKit._r_kwarg_name(:lt_cap_label;
                                    name_fun=ShowKit._pmtables_to_r_name) == :lt_cap_label

        pairs_out = ShowKit._pmtables_kwargs(pairs((lt_cap_label="tab-x", _default="l")))
        @test pairs_out == [:lt_cap_label => "tab-x", Symbol(".default") => "l"]
    end

    @testset "pmtables pt_* cols selection" begin
        # cols accepts a vector or a scalar, and is emitted ahead of user kwargs.
        @test ShowKit._pt_kwargs([:WT, :AGE], pairs((by="STUDY",))) ==
              [:cols => "WT,AGE", :by => "STUDY"]
        @test ShowKit._pt_kwargs(["WT", "AGE"], pairs(NamedTuple())) == [:cols => "WT,AGE"]
        @test ShowKit._pt_kwargs(:WT, pairs(NamedTuple())) == [:cols => "WT"]
        @test ShowKit._pt_kwargs(nothing, pairs((all_name="Total",))) ==
              [:all_name => "Total"]
    end

    @testset "Curried renderers accept kwargs" begin
        # stable()/stable_long() previously took no kwargs in curried form, so
        # `tbl |> stable_long(lt_cap_label=...)` raised a MethodError.
        @test hasmethod(stable_long, Tuple{}, (:lt_cap_label,))
        @test hasmethod(stable, Tuple{}, (:note_config,))
        @test stable_long(lt_cap_label="tab-param-table") isa Function
        @test stable(inspect=true) isa Function

        # The zero-argument curried form still works.
        @test stable_long() isa Function
        @test stable() isa Function

        # Direct forms remain available.
        @test hasmethod(stable_long, Tuple{PMTable}, (:lt_cap_label,))
        @test hasmethod(stable, Tuple{PMTable}, (:note_config,))

        # stable_save can render a longtable for the PMTable paths.
        @test hasmethod(stable_save, Tuple{PMTable, String}, (:longtable,))
        @test hasmethod(stable_save, Tuple{PMTable}, (:longtable,))
    end

    @testset "mrggsave script provenance" begin
        # Pure decision: real .jl paths -> basename; interactive pseudo-files -> nothing.
        @test ShowKit._script_name("/example/project/analysis.jl") == "analysis.jl"
        @test ShowKit._script_name("analysis.jl") == "analysis.jl"
        @test ShowKit._script_name("none") === nothing          # julia -e / piped stdin / fallback REPL
        @test ShowKit._script_name("REPL[1]") === nothing       # TTY REPL
        @test ShowKit._script_name("In[3]") === nothing         # IJulia
        @test ShowKit._script_name("") === nothing
        @test ShowKit._script_name("/p/notebook.jl#==#1a2b3c") === nothing  # Pluto cell

        # An explicit script always wins, untouched.
        @test ShowKit._resolve_script("custom.jl") == "custom.jl"

        # Auto-detection from a real script: this test file. The detected name
        # must equal the basename of the file these lines live in.
        # Capture outside `@test`: Pkg.test evaluates assertion expressions
        # through Test.jl, which would otherwise become the immediate caller.
        detected_caller = ShowKit._caller_script()
        resolved_script = ShowKit._resolve_script(nothing)
        @test detected_caller == basename(@__FILE__)
        @test resolved_script == basename(@__FILE__)
    end

    @testset "R backend state" begin
        available = r_available()
        @test available == (ShowKit._RCALL_AVAILABLE[] && ShowKit._GGPLOT2_AVAILABLE[])
        @test available isa Bool

        smoke_data = DataFrame(x=[1.0, 2.0], y=[3.0, 4.0])
        if available
            @test ShowKit._rcopy(Bool, ShowKit._reval("TRUE"))
            plot = ggplot(smoke_data, aes(x=:x, y=:y)) + geom_point()
            @test plot isa GGPlot
        else
            err = try
                ggplot(smoke_data, aes(x=:x, y=:y))
                nothing
            catch caught
                caught
            end
            @test err isa ErrorException
            message = sprint(showerror, err)
            @test occursin("R is not available", message) ||
                  occursin("ggplot2 R package is not available", message)
        end
    end

    @testset "set_display_size" begin
        set_display_size(width=10.0, height=8.0, dpi=300)
        @test ShowKit._DISPLAY_WIDTH[] == 10.0
        @test ShowKit._DISPLAY_HEIGHT[] == 8.0
        @test ShowKit._DISPLAY_DPI[] == 300

        # Reset
        set_display_size(width=7.0, height=5.0, dpi=150)
    end

    @testset "Exports" begin
        # Verify key functions are exported and accessible
        @test isdefined(ShowKit, :ggplot)
        @test isdefined(ShowKit, :aes)
        @test isdefined(ShowKit, :geom_point)
        @test isdefined(ShowKit, :geom_line)
        @test isdefined(ShowKit, :theme_bw)
        @test isdefined(ShowKit, :theme)
        @test isdefined(ShowKit, :facet_wrap)
        @test isdefined(ShowKit, :labs)
        @test isdefined(ShowKit, :gg)
        @test isdefined(ShowKit, :dv_pred)
        @test isdefined(ShowKit, :cwres_time)
        @test isdefined(ShowKit, :eta_cont)
        @test isdefined(ShowKit, :pt_cont_wide)
        @test isdefined(ShowKit, :st_units)
        @test isdefined(ShowKit, :st_align)
        @test isdefined(ShowKit, :col_fixed)
        @test isdefined(ShowKit, :st_clear_grouped)
        @test isdefined(ShowKit, :tab_clear_reps)
        @test hasmethod(tab_clear_reps, Tuple{DataFrame, Symbol})
        @test isdefined(ShowKit, :stable)
        @test isdefined(ShowKit, :mrggsave)
        @test isdefined(ShowKit, :vpc)
        @test isdefined(ShowKit, :vpc_cens)
        @test isdefined(ShowKit, :vpc_cat)
        @test isdefined(ShowKit, :vpc_tte)
        @test isdefined(ShowKit, :axis_col_labs)
        @test isdefined(ShowKit, :r_available)
        @test isdefined(ShowKit, :scale_x_continuous)
        @test isdefined(ShowKit, :coord_flip)
        @test isdefined(ShowKit, :element_text)
        @test isdefined(ShowKit, :element_blank)

        inventory_path = normpath(joinpath(
            @__DIR__, "..", "..", "validation", "exports-ShowKit.txt"))
        expected = Set{Symbol}()
        for line in eachline(inventory_path)
            entry = strip(first(split(line, '#'; limit=2)))
            isempty(entry) || push!(expected, Symbol(entry))
        end
        actual = Set(names(ShowKit; all=false, imported=false))
        delete!(actual, :ShowKit)
        @test actual == expected
    end

    @testset "Yspec integration (no R)" begin
        # Test axis_col_labs with a mock spec-like object
        mock_col = (short="Weight", label="Body Weight", unit="kg")
        mock_col2 = (short="Age", label="Age at Baseline", unit="years")
        mock_col3 = (short="Conc", label="Concentration", unit=nothing)
        mock_spec = (columns=Dict(
            :WT => mock_col,
            :AGE => mock_col2,
            :DV => mock_col3,
        ),)

        labs_dict = axis_col_labs(mock_spec, [:WT, :AGE, :DV])
        @test labs_dict[:WT] == "WT//Weight [kg]"
        @test labs_dict[:AGE] == "AGE//Age [years]"
        @test labs_dict[:DV] == "DV//Conc"

        # col_label
        @test col_label(mock_spec, :WT) == "Weight [kg]"
        @test col_label(mock_spec, :DV) == "Conc"
        @test col_label(mock_spec, :MISSING) == "MISSING"

        # axis_col_labs for all columns
        all_labs = axis_col_labs(mock_spec)
        @test length(all_labs) == 3
    end
end

include("wrapper_contracts_test.jl")
