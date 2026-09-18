const UNIFIED_COMPONENT_IMPORTS = [
    :BookKit => :book!,
    :CondaR => :prepare!,
    :ConfigKit => :load_keyfile,
    :InjecKit => :ev,
    :QSPKitCore => :with_symbolic_compilation_lock,
    :QSPKitIO => :save_archive,
    :QSPReports => :parameter_table,
    :ShowKit => :ggplot,
    :SimKit => :simulate,
    :SpecKit => :load_yspec,
    :StoreKit => :open_store,
    :TargKit => :fit,
]

const WORKSPACE_PACKAGE_NAMES = [
    :BayesKit,
    :PopCore,
    :PopKit,
    :SamplerCore,
    :SensKit,
    :SolveKit,
    :VPop,
    :WALNUTS,
]

const NAMESPACE_NAMES = Set([
    :QSPKit,
    first.(UNIFIED_COMPONENT_IMPORTS)...,
    WORKSPACE_PACKAGE_NAMES...,
])

function source_files(directory)
    files = String[]
    for (root, _, names) in walkdir(directory)
        for name in names
            endswith(name, ".jl") && push!(files, joinpath(root, name))
        end
    end
    return sort!(files)
end

function dotted_root(ex)
    current = ex
    while current isa Expr && current.head === :. && !isempty(current.args)
        current = current.args[1]
    end
    return current isa Symbol ? current : nothing
end

function quoted_namespace_references!(found, node, path; quoted=false)
    node isa Expr || return found
    inside_quote = quoted || node.head in (:quote, :inert)
    if inside_quote && node.head === :.
        root = dotted_root(node)
        root in NAMESPACE_NAMES && push!(found, (path, root))
    end
    for arg in node.args
        quoted_namespace_references!(found, arg, path; quoted=inside_quote)
    end
    return found
end

@testset "Unified namespace audit" begin
    repository_root = normpath(joinpath(@__DIR__, ".."))
    unified_names = first.(UNIFIED_COMPONENT_IMPORTS)
    all_package_names = [unified_names; WORKSPACE_PACKAGE_NAMES]
    source_roots = [
        joinpath(repository_root, String(name), "src")
        for name in all_package_names
        if isdir(joinpath(repository_root, String(name), "src"))
    ]
    push!(source_roots, joinpath(repository_root, "src"))

    @testset "explicit imports work without parent module bindings" begin
        for (component, api) in UNIFIED_COMPONENT_IMPORTS
            caller_name = Symbol(:NamespaceAudit, component, :Caller)
            result = Core.eval(Main, Meta.parseall("""
                module $caller_name
                using QSPKit.$component: $api
                const NAMESPACE_AUDIT_RESULT = (
                    isdefined(@__MODULE__, :$api),
                    isdefined(@__MODULE__, :QSPKit),
                    isdefined(@__MODULE__, :$component),
                )
                end
                $caller_name.NAMESPACE_AUDIT_RESULT
            """))
            @test result[1]
            @test !result[2]
            @test !result[3]
        end
    end

    @testset "source does not discover packages through Main" begin
        violations = Tuple{String,Symbol}[]
        for directory in source_roots, path in source_files(directory)
            source = read(path, String)
            for name in all_package_names
                main_lookup = Regex(
                    "(?:isdefined|getfield)\\(Main\\s*,\\s*:$(name)\\b|\\bMain\\.$(name)\\b",
                )
                occursin(main_lookup, source) && push!(violations, (path, name))
            end
        end
        @test isempty(violations)
    end

    @testset "unified components use relative sibling imports" begin
        violations = Tuple{String,Symbol}[]
        for component in unified_names
            directory = joinpath(repository_root, String(component), "src")
            for path in source_files(directory)
                source = read(path, String)
                for sibling in unified_names
                    absolute_import = Regex(
                        "(?m)^\\s*(?:using|import)\\s+$(sibling)(?:\\s|:|\$)",
                    )
                    occursin(absolute_import, source) &&
                        push!(violations, (path, sibling))
                end
            end
        end
        @test isempty(violations)
    end

    @testset "caller-evaluated code has no symbolic package qualification" begin
        found = Tuple{String,Symbol}[]
        for directory in source_roots, path in source_files(directory)
            syntax = Meta.parseall(read(path, String); filename=path)
            quoted_namespace_references!(found, syntax, path)
        end
        @test isempty(found)
    end

    @testset "StoreKit REPL hook uses defining-module references" begin
        QSPKit.StoreKit.clear_session_log!()
        caller = Module(gensym(:StoreKitCaller))
        transformed = QSPKit.StoreKit._recording_transform(:(global answer = 42))
        @test Core.eval(caller, transformed) == 42
        @test Core.eval(caller, :answer) == 42
        @test !isdefined(caller, :QSPKit)
        @test !isdefined(caller, :StoreKit)
        @test only(QSPKit.StoreKit.get_session_log()).defs == Set([:answer])
        QSPKit.StoreKit.clear_session_log!()
    end
end
