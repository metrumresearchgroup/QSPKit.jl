using Test
using BookKit
using Graphs
using MetaGraphsNext
using StoreKit
using TargKit            # triggers BookKitTargKitExt (book_extract(::FitResult))
using SimKit             # triggers BookKitSimKitExt (book_extract(::SimContext))
using ModelingToolkit

# A minimal MTK-backed problem for the SimKit extractor test.
@independent_variables _bk_t
const _bk_D = Differential(_bk_t)
@parameters _bk_k = 0.1
@variables _bk_X(_bk_t) = 1.0
@named _bk_model = System([_bk_D(_bk_X) ~ -_bk_k * _bk_X], _bk_t)
const _bk_sys = mtkcompile(_bk_model)
const _bk_prob = ODEProblem(_bk_sys, [], (0.0, 1.0))

# Capture stdout helper (needed for history test)
macro capture_out(ex)
    quote
        original_stdout = stdout
        rd, wr = redirect_stdout()
        try
            $(esc(ex))
            redirect_stdout(original_stdout)
            close(wr)
            read(rd, String)
        catch e
            redirect_stdout(original_stdout)
            close(wr)
            rethrow(e)
        end
    end
end

# A custom result type with a book_extract method, to exercise the typed path.
struct _ExtFit
    converged::Bool
end
function BookKit.book_extract(r::_ExtFit)
    return (kind = :fit, payload = "fit-payload",
            status_hint = r.converged ? :accepted : :rejected,
            fingerprints = Dict("params" => "ph1"),
            metrics = Dict("loss" => 0.5),
            fit_quality = nothing, inputs = String[])
end

@testset "BookKit" begin

    @testset "exported API is bound" begin
        for name in (
            :book!, :lookup, :history, :restore, :BookedResult,
            :clear_consumption!, :staleness, :staleness_sweep,
            :StalenessReport, :is_stale, :book_extract, :artifact, :Artifact,
            :lineage_graph, :LineageGraph, :LineageNode, :LineageEdge,
            :to_dot, :render_lineage, :to_metagraph,
        )
            @test isdefined(BookKit, name)
        end
    end

    @testset "BookedResult property forwarding" begin
        data = (fitted_params=Dict(:k1 => 0.5, :k2 => 1.2), loss=0.01)
        br = BookedResult("test", :accepted, data, "good fit")

        @test br.name == "test"
        @test br.status == :accepted
        @test br.rationale == "good fit"
        @test br.data === data

        # Property forwarding to data
        @test br.fitted_params == Dict(:k1 => 0.5, :k2 => 1.2)
        @test br.fitted_params[:k1] == 0.5
        @test br.loss == 0.01

        # Show method
        @test sprint(show, br) == "BookedResult(\"test\", :accepted)"

        # propertynames includes both BookedResult fields and data fields
        pnames = propertynames(br)
        @test :name in pnames
        @test :fitted_params in pnames
        @test :loss in pnames
    end

    @testset "book! and lookup roundtrip" begin
        mktempdir() do dir
            result = (files=["index.html", "guide.html"], byte_count=2048)

            br = book!("site_bundle", :accepted;
                result=result,
                rationale="All pages rendered and links checked",
                store_dir=dir,
            )

            @test br isa BookedResult
            @test br.name == "site_bundle"
            @test br.status == :accepted
            @test br.data == result
            @test br.rationale == "All pages rendered and links checked"

            # lookup roundtrip
            looked = lookup("site_bundle"; store_dir=dir)
            @test looked isa BookedResult
            @test looked.name == "site_bundle"
            @test looked.status == :accepted
            @test looked.data == result
            @test looked.rationale == "All pages rendered and links checked"
            @test looked.files == ["index.html", "guide.html"]
        end
    end

    @testset "lookup throws on missing name" begin
        mktempdir() do dir
            @test_throws KeyError lookup("nonexistent"; store_dir=dir)
        end
    end

    @testset "book! creates SQLite rows" begin
        mktempdir() do dir
            result = (x=1, y=2)
            book!("SQL_TEST", :accepted; result=result, store_dir=dir)

            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "SQL_TEST")
            @test row !== nothing
            @test row.name == "SQL_TEST"
            @test row.status == "accepted"
            @test row.result_hash !== nothing
        end
    end

    @testset "book! creates .decision.md" begin
        mktempdir() do dir
            result = Dict(:fitted_params => Dict(:CL => 1.5), :loss => 0.02)
            book!("MU_DEC", :accepted;
                result=result,
                rationale="Good PK fit",
                fit_quality=Dict("R2" => 0.95, "AIC" => -120),
                store_dir=dir,
            )

            decision_path = joinpath(dir, ".provenance", "decisions", "mu_dec.md")
            @test isfile(decision_path)
            content = read(decision_path, String)
            @test occursin("# Decision: MU_DEC", content)
            @test occursin("accepted", content)
            @test occursin("Good PK fit", content)
            @test occursin("Fit Quality", content)
        end
    end

    @testset "book! with file attribution and verify" begin
        mktempdir() do dir
            # Create a data file to attribute
            data_file = joinpath(dir, "data.csv")
            write(data_file, "x,y\n1,2\n3,4\n")

            # Manually push a file read to simulate attribution
            push!(StoreKit.FILE_READS, (path=abspath(data_file), expr_id=0, mode="r"))

            result = "test_result"
            book!("FILE_TEST", :accepted; result=result, store_dir=dir)

            # Verify file snapshot was stored
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "FILE_TEST")
            snapshots = StoreKit.get_file_snapshots(store.db, row.id)
            @test length(snapshots) >= 1
            @test any(s -> occursin("data.csv", s.path), snapshots)

            # lookup with verify=true should not warn (file unchanged)
            looked = lookup("FILE_TEST"; store_dir=dir, verify=true)
            @test looked.data == "test_result"

            # Modify the file — verify should now warn
            write(data_file, "x,y\n1,2\n3,4\n5,6\n")
            @test_logs (:warn, r"may be stale") lookup("FILE_TEST"; store_dir=dir, verify=true)

            # Clean up FILE_READS
            empty!(StoreKit.FILE_READS)
        end
    end

    @testset "book!: written files are not attributed as inputs" begin
        mktempdir() do dir
            empty!(StoreKit.FILE_READS)
            in_file = joinpath(dir, "input.csv")
            out_file = joinpath(dir, "output.csv")
            write(in_file, "x\n1\n")
            write(out_file, "y\n2\n")

            # Simulate the run reading an input and WRITING an output.
            push!(StoreKit.FILE_READS, (path=abspath(in_file), expr_id=0, mode="r"))
            push!(StoreKit.FILE_READS, (path=abspath(out_file), expr_id=0, mode="w"))

            book!("WRITE_TEST", :accepted; result="x", store_dir=dir)

            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "WRITE_TEST")
            snaps = StoreKit.get_file_snapshots(store.db, row.id)
            paths = [s.path for s in snaps]
            @test any(p -> occursin("input.csv", p), paths)      # read input snapshotted
            @test !any(p -> occursin("output.csv", p), paths)    # written output NOT snapshotted

            empty!(StoreKit.FILE_READS)
        end
    end

    @testset "multiple book! calls and history" begin
        mktempdir() do dir
            book!("MU_HIST", :accepted; result="first", rationale="Initial", store_dir=dir)
            book!("MU_HIST", :rejected; result="second", rationale="Bad fit", store_dir=dir)
            book!("MU_HIST", :accepted; result="third", rationale="Refined", loss=0.001, store_dir=dir)

            # history returns all entries
            output = @capture_out history("MU_HIST"; store_dir=dir)
            @test occursin("3 entries", output)

            # lookup returns the latest
            looked = lookup("MU_HIST"; store_dir=dir)
            @test looked.data == "third"
            @test looked.status == :accepted
        end
    end

    @testset "restore recreates files" begin
        mktempdir() do dir
            # Create a data file
            data_file = joinpath(dir, "restore_test.txt")
            write(data_file, "hello world")

            push!(StoreKit.FILE_READS, (path=abspath(data_file), expr_id=0, mode="r"))

            book!("RESTORE_TEST", :accepted; result="r", store_dir=dir)
            empty!(StoreKit.FILE_READS)

            # Delete the original
            rm(data_file)
            @test !isfile(data_file)

            # Restore to a new location
            restore_dir = joinpath(dir, "restored")
            restored = restore("RESTORE_TEST"; to=restore_dir, store_dir=dir)

            @test restored !== nothing
            @test length(restored) >= 1
            # The restored file should have the original content
            for rel in restored
                full = joinpath(restore_dir, rel)
                if occursin("restore_test.txt", rel)
                    @test read(full, String) == "hello world"
                end
            end
        end
    end

    @testset "book! with loss" begin
        mktempdir() do dir
            book!("LOSS_TEST", :accepted; result="data", loss=0.0042, store_dir=dir)

            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "LOSS_TEST")
            @test row.loss == 0.0042
        end
    end

    @testset "book! with fit_quality" begin
        mktempdir() do dir
            fq = Dict("R2" => 0.98, "RMSE" => 0.05)
            book!("FQ_TEST", :accepted; result="data", fit_quality=fq, store_dir=dir)

            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "FQ_TEST")
            @test row.fit_quality !== nothing
            @test occursin("R2", row.fit_quality)
        end
    end

    @testset "VCS describe" begin
        ref, dirty = BookKit._vcs_describe()
        @test ref isa String
        @test dirty isa Bool
    end

    @testset "restore throws on missing name" begin
        mktempdir() do dir
            @test_throws KeyError restore("nonexistent"; to=joinpath(dir, "out"), store_dir=dir)
        end
    end

    # ──────────────────────────────────────────────────────────────────────
    # lineage_graph
    # ──────────────────────────────────────────────────────────────────────

    # Build a deliberately generic documentation-publishing workflow. Each script
    # produces a named artifact with `cached(...)` and reads upstream artifacts
    # with `latest(name=...)`.
    function _write_fixture_project(root)
        function script(relpath, body)
            path = joinpath(root, relpath)
            mkpath(dirname(path))
            write(path, body)
        end
        script("workflow/collect/run.jl", """
            \"\"\"
            Job10: Gather source pages
            \"\"\"
            using ExampleCache
            result = cached("Job10_ContentManifest"; output_dir="artifacts/cache") do
                collect_pages("content")
            end
            """)
        script("workflow/build/run.jl", """
            \"\"\"
            Job20: Build the site bundle
            \"\"\"
            using ExampleCache
            content_manifest = latest(name="Job10_ContentManifest", output_dir="artifacts/cache")
            result = cached("Job20_SiteBundle"; output_dir="artifacts/cache") do
                fit(content_manifest, page_template)
            end
            """)
        script("workflow/build/index.jl", """
            # Job20: Index the bundled files
            using ExampleCache
            site_bundle = latest(name="Job20_SiteBundle", output_dir="artifacts/cache")
            index = cached("Job20_BundleIndex"; output_dir="artifacts/cache") do
                build_index(site_bundle)
            end
            """)
        script("workflow/publish/run.jl", """
            #=
            Job30: Publish the generated site
            =#
            using ExampleCache
            site_bundle = latest(name="Job20_SiteBundle", output_dir="artifacts/cache")
            bundle_index = latest(name="Job20_BundleIndex", output_dir="artifacts/cache")
            receipt = cached("Job30_PublishedSite"; output_dir="artifacts/cache") do
                publish(site_bundle, bundle_index)
            end
            """)
        return root
    end

    @testset "lineage_graph reproduces the generic stage DAG" begin
        mktempdir() do dir
            _write_fixture_project(dir)
            g = lineage_graph(dir)              # default granularity = :unit

            @test g isa LineageGraph
            @test g.granularity == :unit
            names = Set(n.name for n in BookKit.nodes(g))
            @test names == Set(["Job10", "Job20", "Job30"])

            edgeset = Set((e.src, e.dst) for e in BookKit.edges(g))
            @test edgeset == Set([("Job10", "Job20"), ("Job20", "Job30")])

            # Roots / leaves
            @test BookKit.roots(g) == ["Job10"]
            @test BookKit.leaves(g) == ["Job30"]

            # The build script calls fit(content, template); collection and
            # publication do not. This keeps both classification paths covered
            # without using a scientific model fixture.
            kind = Dict(n.name => n.kind for n in BookKit.nodes(g))
            @test kind == Dict(
                "Job10" => :prediction,
                "Job20" => :fit,
                "Job30" => :prediction,
            )

            # descriptions discovered from leading docstrings/comments
            desc = Dict(n.name => n.description for n in BookKit.nodes(g))
            @test occursin("Gather source pages", desc["Job10"])
            @test occursin("Publish the generated site", desc["Job30"])

            # The two result-level reads from Job20 collapse to one stage edge,
            # while retaining the exact pulled artifacts as metadata.
            publish_edge = only(filter(
                e -> (e.src, e.dst) == ("Job20", "Job30"),
                BookKit.edges(g),
            ))
            @test Set(publish_edge.pulled) ==
                  Set(["Job20_SiteBundle", "Job20_BundleIndex"])
        end
    end

    @testset "lineage_graph to_dot" begin
        mktempdir() do dir
            _write_fixture_project(dir)
            g = lineage_graph(dir)
            dot = to_dot(g; title="fixture")
            @test occursin("digraph lineage", dot)
            @test occursin("\"Job10\" -> \"Job20\"", dot)
            @test occursin("\"Job20\" -> \"Job30\"", dot)
            @test occursin("#2E8B72", dot)   # fit (teal) styling
            @test occursin("#D9952F", dot)   # prediction (amber) styling
            @test occursin("label=\"fixture\"", dot)
        end
    end

    @testset "lineage_graph result-level granularity" begin
        mktempdir() do dir
            _write_fixture_project(dir)
            g = lineage_graph(dir; granularity=:result)
            @test g.granularity == :result
            names = Set(n.name for n in BookKit.nodes(g))
            @test names == Set([
                "Job10_ContentManifest",
                "Job20_SiteBundle",
                "Job20_BundleIndex",
                "Job30_PublishedSite",
            ])

            edgeset = Set((e.src, e.dst) for e in BookKit.edges(g))
            @test edgeset == Set([
                ("Job10_ContentManifest", "Job20_SiteBundle"),
                ("Job20_SiteBundle", "Job20_BundleIndex"),
                ("Job20_SiteBundle", "Job30_PublishedSite"),
                ("Job20_BundleIndex", "Job30_PublishedSite"),
            ])
            # intra-unit edge survives at result granularity (dropped at unit level)
            @test ("Job20_SiteBundle", "Job20_BundleIndex") in edgeset

            # the binding variable that read the upstream result is captured
            published = only(filter(
                e -> e.dst == "Job30_PublishedSite" &&
                     e.src == "Job20_BundleIndex",
                BookKit.edges(g),
            ))
            @test published.via == "bundle_index"
        end
    end

    @testset "lineage_graph from a BookKit store (recorded edges)" begin
        mktempdir() do dir
            clear_consumption!()
            manifest = Dict(:pages => ["guide.md", "reference.md"])
            book!("content_manifest", :accepted; result=manifest, store_dir=dir)

            # Auto-captured edge: looking up the manifest before booking the site
            # bundle records the exact upstream artifact.
            looked_up_manifest = lookup("content_manifest"; store_dir=dir)
            @test looked_up_manifest.data == manifest
            book!("site_bundle", :accepted;
                  result=Dict(:files => ["index.html"]), store_dir=dir)

            # Explicit, labeled edge.
            book!("publish_receipt", :accepted; result="published",
                  inputs=["site_bundle" => "site files"], store_dir=dir)

            store = open_store(dir)
            g = lineage_graph(store)
            edgeset = Set((e.src, e.dst) for e in BookKit.edges(g))
            @test edgeset == Set([
                ("content_manifest", "site_bundle"),
                ("site_bundle", "publish_receipt"),
            ])

            # explicit label is preserved
            publish_edge = only(filter(
                e -> (e.src, e.dst) == ("site_bundle", "publish_receipt"),
                BookKit.edges(g),
            ))
            @test publish_edge.label == "site files"

            # the store also recorded the rows directly
            bundle_row = StoreKit.latest_annotation(store.db, "site_bundle")
            bundle_inputs = StoreKit.get_result_inputs(store.db, bundle_row.id)
            @test only(bundle_inputs).input_name == "content_manifest"

            clear_consumption!()
        end
    end

    @testset "render_lineage writes Graphviz source" begin
        mktempdir() do dir
            _write_fixture_project(dir)
            g = lineage_graph(dir)
            path = joinpath(dir, "lineage.dot")
            @test render_lineage(g, path; title="site workflow") == path
            @test isfile(path)
            dot = read(path, String)
            @test occursin("digraph lineage", dot)
            @test occursin("label=\"site workflow\"", dot)
        end
    end

    @testset "to_metagraph extension preserves graph metadata" begin
        mktempdir() do dir
            _write_fixture_project(dir)
            g = lineage_graph(dir)
            mg = to_metagraph(g)
            @test mg isa MetaGraphsNext.MetaGraph
            @test Graphs.nv(mg) == length(BookKit.nodes(g))
            @test Graphs.ne(mg) == length(BookKit.edges(g))
            @test mg["Job20"].kind == :fit
            @test mg["Job30"].kind == :prediction
            @test mg["Job10", "Job20"].source == :script
        end
    end

    # ── Structured staleness (upstream / vcs / blob) ───────────────────────

    @testset "staleness: fresh report shape" begin
        mktempdir() do dir
            clear_consumption!()
            book!("SH", :accepted; result="data", capture_env=false, store_dir=dir)
            r = staleness("SH"; store_dir=dir)
            @test r isa StalenessReport
            @test r.name == "SH"
            @test is_stale(r) == false
            @test r.blob.checked == true     # has a result blob
            @test r.files.checked == false   # no attributed files (env capture off)
            s = sprint(show, r)
            @test occursin("SH", s)
            @test occursin("fresh", s)
            clear_consumption!()
        end
    end

    @testset "staleness: transitive upstream drift" begin
        mktempdir() do dir
            clear_consumption!()
            book!("UP", :accepted; result="v1", store_dir=dir)
            lookup("UP"; store_dir=dir)                 # auto-captures UP's hash
            book!("DOWN", :accepted; result="w", store_dir=dir)   # edge DOWN→UP pinned
            clear_consumption!()

            # Fresh while UP unchanged
            r = staleness("DOWN"; store_dir=dir)
            @test r.upstream.checked == true
            @test r.upstream.stale == false
            @test is_stale(r) == false

            # Re-book UP with different content → DOWN's pin drifts
            book!("UP", :accepted; result="v2", store_dir=dir)
            clear_consumption!()
            r2 = staleness("DOWN"; store_dir=dir)
            @test r2.upstream.stale == true
            @test is_stale(r2) == true
            @test any(d -> occursin("UP", d) && occursin("drifted", d), r2.upstream.details)

            # lookup verify emits exactly the legacy-style warning
            @test_logs (:warn, r"may be stale") lookup("DOWN"; store_dir=dir, verify=true)
            clear_consumption!()
        end
    end

    @testset "staleness: multi-hop recursion" begin
        mktempdir() do dir
            clear_consumption!()
            book!("A", :accepted; result="a1", store_dir=dir)
            lookup("A"; store_dir=dir); book!("B", :accepted; result="b", store_dir=dir)
            clear_consumption!()
            lookup("B"; store_dir=dir); book!("C", :accepted; result="c", store_dir=dir)
            clear_consumption!()

            book!("A", :accepted; result="a2", store_dir=dir)   # re-book the root
            clear_consumption!()

            r = staleness("C"; store_dir=dir)                   # C→B→A
            @test r.upstream.stale == true
            @test any(d -> occursin("A", d) && occursin("drifted", d), r.upstream.details)
            clear_consumption!()
        end
    end

    @testset "staleness: upstream cycle terminates" begin
        mktempdir() do dir
            book!("CA", :accepted; result="x", store_dir=dir)
            book!("CB", :accepted; result="y", store_dir=dir)
            store = open_store(dir)
            a = StoreKit.latest_annotation(store.db, "CA")
            b = StoreKit.latest_annotation(store.db, "CB")
            StoreKit.insert_result_input!(store.db, a.id, "CB")
            StoreKit.insert_result_input!(store.db, b.id, "CA")
            r = staleness("CA"; store_dir=dir)   # must not infinite-loop
            @test r isa StalenessReport
            clear_consumption!()
        end
    end

    @testset "staleness: unpinned and dangling upstreams are not drift" begin
        mktempdir() do dir
            clear_consumption!()
            book!("PU", :accepted; result="v1", store_dir=dir)
            # explicit inputs= with no prior lookup → input_hash stored NULL
            book!("PD", :accepted; result="w", inputs=["PU"], store_dir=dir)
            book!("DG", :accepted; result="z", inputs=["GHOST"], store_dir=dir)
            clear_consumption!()
            book!("PU", :accepted; result="v2", store_dir=dir)   # change PU
            clear_consumption!()

            rpd = staleness("PD"; store_dir=dir)
            @test rpd.upstream.stale == false   # unpinned: no baseline to compare
            @test any(d -> occursin("unpinned", d), rpd.upstream.details)

            rdg = staleness("DG"; store_dir=dir)
            @test rdg.upstream.stale == false   # dangling: never booked
            @test any(d -> occursin("GHOST", d) && occursin("dangling", d), rdg.upstream.details)
            clear_consumption!()
        end
    end

    @testset "staleness: result blob integrity" begin
        mktempdir() do dir
            clear_consumption!()
            book!("BI", :accepted; result="payload", store_dir=dir)
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "BI")
            blobp = joinpath(dir, ".provenance", "blobs", "$(row.result_hash).blob")
            @test isfile(blobp)

            # Corrupt the blob bytes.
            write(blobp, "corrupted-bytes")
            r = staleness("BI"; store_dir=dir)   # never throws
            @test r.blob.stale == true
            @test is_stale(r)
            # Under verify, lookup degrades to nothing (and warns) instead of throwing.
            @test lookup("BI"; store_dir=dir, verify=true).data === nothing
            # Default path stays fail-loud on a damaged blob.
            @test_throws Exception lookup("BI"; store_dir=dir)

            # Delete the blob → missing
            rm(blobp)
            r2 = staleness("BI"; store_dir=dir)
            @test r2.blob.stale == true
            @test lookup("BI"; store_dir=dir, verify=true).data === nothing
            clear_consumption!()
        end
    end

    @testset "staleness: result-less booking does not throw" begin
        mktempdir() do dir
            clear_consumption!()
            # Default result=nothing → NULL result_hash (surfaces from SQLite as `missing`).
            book!("REJ", :rejected; rationale="no fit", store_dir=dir)

            looked = lookup("REJ"; store_dir=dir)
            @test looked.data === nothing
            @test looked.status == :rejected

            r = staleness("REJ"; store_dir=dir)
            @test r isa StalenessReport
            @test r.blob.checked == false        # no result payload to verify
            @test is_stale(r) == false

            @test lookup("REJ"; store_dir=dir, verify=true).data === nothing   # must not throw
            clear_consumption!()
        end
    end

    @testset "staleness: select a specific revision" begin
        mktempdir() do dir
            clear_consumption!()
            book!("RV", :accepted; result="r1", store_dir=dir)
            book!("RV", :accepted; result="r2", store_dir=dir)
            store = open_store(dir)
            rows = StoreKit.all_annotations(store.db, "RV")   # newest first
            id_old = rows[end].id

            rhead = staleness("RV"; store_dir=dir)
            rold  = staleness("RV"; store_dir=dir, revision=id_old)
            @test rold.revision == id_old
            @test rhead.revision != rold.revision

            @test_throws KeyError staleness("RV"; store_dir=dir, revision=999999)
            @test_throws KeyError staleness("NOPE"; store_dir=dir)
            @test_throws ArgumentError staleness("RV"; store_dir=dir, revision=true)  # Bool is not a revision id
            clear_consumption!()
        end
    end

    @testset "fingerprints: persisted + diff-at-rebook staleness" begin
        mktempdir() do dir
            clear_consumption!()
            # First booking with fingerprints.
            book!("FP", :accepted; result="r1", store_dir=dir, capture_env=false,
                  fingerprints=Dict("params" => "h1", "solver" => "s1"))
            store = open_store(dir)
            row1 = StoreKit.latest_annotation(store.db, "FP")
            got = Dict(e.key => e.value for e in StoreKit.get_result_fingerprints(store.db, row1.id))
            @test got == Dict("params" => "h1", "solver" => "s1")

            # First booking → checked, not stale.
            r1 = staleness("FP"; store_dir=dir)
            @test r1.fingerprints.checked == true
            @test r1.fingerprints.stale == false
            @test any(d -> occursin("first booking", d), r1.fingerprints.details)

            # Re-book with a CHANGED shared-key value → stale on fingerprints.
            book!("FP", :accepted; result="r2", store_dir=dir, capture_env=false,
                  fingerprints=Dict("params" => "h2", "solver" => "s1"))
            r2 = staleness("FP"; store_dir=dir)
            @test r2.fingerprints.stale == true
            @test is_stale(r2)
            @test any(d -> occursin("params changed", d), r2.fingerprints.details)

            # Re-book with an ADDED key (params unchanged) → note, not stale.
            book!("FP", :accepted; result="r3", store_dir=dir, capture_env=false,
                  fingerprints=Dict("params" => "h2", "solver" => "s1", "model" => "m1"))
            r3 = staleness("FP"; store_dir=dir)
            @test r3.fingerprints.stale == false
            @test any(d -> occursin("model added", d), r3.fingerprints.details)
            clear_consumption!()
        end
    end

    @testset "fingerprints: no fingerprints = unchecked" begin
        mktempdir() do dir
            clear_consumption!()
            book!("NOFP", :accepted; result="r", capture_env=false, store_dir=dir)
            r = staleness("NOFP"; store_dir=dir)
            @test r.fingerprints.checked == false
            @test r.fingerprints.stale == false
            clear_consumption!()
        end
    end

    @testset "fingerprints: fingerprint-only change is recorded (duplicate-skip widened)" begin
        mktempdir() do dir
            clear_consumption!()
            store = open_store(dir)
            # Identical result/status/rationale + identical fingerprints → skipped.
            book!("DUP", :accepted; result="same", store_dir=dir, fingerprints=Dict("params" => "h1"))
            book!("DUP", :accepted; result="same", store_dir=dir, fingerprints=Dict("params" => "h1"))
            @test length(StoreKit.all_annotations(store.db, "DUP")) == 1

            # Same result/status/rationale but a DIFFERENT fingerprint → NOT skipped.
            book!("DUP", :accepted; result="same", store_dir=dir, fingerprints=Dict("params" => "h2"))
            @test length(StoreKit.all_annotations(store.db, "DUP")) == 2
            r = staleness("DUP"; store_dir=dir)
            @test r.fingerprints.stale == true   # params h1 → h2
            clear_consumption!()
        end
    end

    @testset "book_extract + dispatching book!(name, result)" begin
        mktempdir() do dir
            clear_consumption!()
            # generic fallback
            g = book_extract(Dict("a" => 1))
            @test g.kind == :generic
            @test g.payload == Dict("a" => 1)
            @test g.status_hint === nothing

            # escape hatch: Symbol 2nd arg → explicit core method
            book!("EH", :accepted; result=42, store_dir=dir)
            @test lookup("EH"; store_dir=dir).data == 42

            # dispatching path: status auto from hint, fingerprints + metrics flow
            br = book!("AF", _ExtFit(true); store_dir=dir)
            @test br.status == :accepted
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "AF")
            fps = Dict(e.key => e.value for e in StoreKit.get_result_fingerprints(store.db, row.id))
            @test fps["params"] == "ph1"
            mets = Dict(e.key => e.value for e in StoreKit.get_metrics(store.db, row.id))
            @test haskey(mets, "loss")
            @test row.loss == 0.5          # loss folded from metrics into the column

            # rejected hint
            @test book!("RF", _ExtFit(false); store_dir=dir).status == :rejected
            # explicit status overrides hint
            @test book!("OF", _ExtFit(false); status=:accepted, store_dir=dir).status == :accepted
            # no hint + no override → loud error
            @test_throws ErrorException book!("NF", Dict("x" => 1); store_dir=dir)
            clear_consumption!()
        end
    end

    @testset "BookKitTargKitExt: book_extract(::FitResult)" begin
        mktempdir() do dir
            clear_consumption!()
            # Construct a FitResult directly (no need to run a real fit).
            fr = TargKit.FitResult(Dict(:CL => 1.0, :V => 10.0), 0.25, nothing, true, :pso_nm, "srchash123")
            et = book_extract(fr)
            @test et.kind == :fit
            @test et.status_hint == :accepted
            @test haskey(et.fingerprints, "params")
            @test et.fingerprints["source"] == "srchash123"
            @test et.metrics["loss"] == 0.25

            # params fingerprint is deterministic + order-independent
            fr2 = TargKit.FitResult(Dict(:V => 10.0, :CL => 1.0), 0.25, nothing, true, :pso_nm, nothing)
            @test book_extract(fr2).fingerprints["params"] == et.fingerprints["params"]
            # ...and changes when a param value changes
            fr3 = TargKit.FitResult(Dict(:CL => 2.0, :V => 10.0), 0.25, nothing, true, :pso_nm, nothing)
            @test book_extract(fr3).fingerprints["params"] != et.fingerprints["params"]

            # end-to-end booking via the typed path
            br = book!("FITX", fr; store_dir=dir)
            @test br.status == :accepted
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "FITX")
            @test row.loss == 0.25
            fps = Dict(e.key => e.value for e in StoreKit.get_result_fingerprints(store.db, row.id))
            @test fps["source"] == "srchash123"

            # converged=false → rejected
            frr = TargKit.FitResult(Dict(:CL => 1.0), 9.9, nothing, false, :pso_nm, nothing)
            @test book_extract(frr).status_hint == :rejected
            clear_consumption!()
        end
    end

    @testset "BookKitSimKitExt: book_extract(::SimContext)" begin
        mktempdir() do dir
            clear_consumption!()
            ctx = SimContext(_bk_prob)   # solver=nothing; sys auto from prob.f.sys
            et = book_extract(ctx)
            @test et.kind == :prediction
            @test et.status_hint == :accepted
            @test haskey(et.fingerprints, "model")    # structural model fingerprint
            @test haskey(et.fingerprints, "solver")
            @test haskey(et.fingerprints, "params")
            @test haskey(et.fingerprints, "doses")

            # model fp is structural + deterministic: an identical sibling model matches
            @named _bk_model2 = System([_bk_D(_bk_X) ~ -_bk_k * _bk_X], _bk_t)
            sys2 = mtkcompile(_bk_model2)
            prob2 = ODEProblem(sys2, [], (0.0, 1.0))
            @test book_extract(SimContext(prob2)).fingerprints["model"] == et.fingerprints["model"]

            # end-to-end booking via the typed path
            br = book!("SIMX", ctx; store_dir=dir)
            @test br.status == :accepted
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "SIMX")
            fps = Dict(e.key => e.value for e in StoreKit.get_result_fingerprints(store.db, row.id))
            @test haskey(fps, "model")
            clear_consumption!()
        end
    end

    @testset "artifact(): file booked as result + cold-verifiable" begin
        mktempdir() do dir
            clear_consumption!()
            empty!(StoreKit.FILE_READS)
            figpath = joinpath(dir, "gof.png")
            write(figpath, "PNGDATA-v1")

            br = book!("FIG", artifact(figpath); store_dir=dir)
            @test br.status == :accepted
            @test br.data == Vector{UInt8}("PNGDATA-v1")   # book! returns bytes, like lookup

            # lookup returns the stored file bytes (raw-file blob, not JLD2)
            @test lookup("FIG"; store_dir=dir).data == Vector{UInt8}("PNGDATA-v1")

            # the artifact is a cold-verifiable file dependency
            r = staleness("FIG"; store_dir=dir)
            @test r.files.checked == true
            @test r.files.stale == false

            # editing the file on disk → stale on the files dimension
            write(figpath, "PNGDATA-v2-edited")
            r2 = staleness("FIG"; store_dir=dir)
            @test r2.files.stale == true
            @test is_stale(r2)

            empty!(StoreKit.FILE_READS)
            clear_consumption!()
        end
    end

    @testset "hardening: re-scored loss/metrics recorded, not skipped" begin
        mktempdir() do dir
            clear_consumption!()
            store = open_store(dir)
            book!("RS", :accepted; result="same", loss=1.0, store_dir=dir)
            book!("RS", :accepted; result="same", loss=2.0, store_dir=dir)   # only loss changed
            @test length(StoreKit.all_annotations(store.db, "RS")) == 2
            @test StoreKit.latest_annotation(store.db, "RS").loss == 2.0
            # a genuinely identical re-book still skips
            book!("RS", :accepted; result="same", loss=2.0, store_dir=dir)
            @test length(StoreKit.all_annotations(store.db, "RS")) == 2
            clear_consumption!()
        end
    end

    @testset "hardening: loss kwarg overrides divergent metrics[loss]" begin
        mktempdir() do dir
            @test_logs (:warn, r"overrides metrics") book!("DIV", :accepted; result="r",
                loss=0.1, metrics=Dict("loss" => 0.9), store_dir=dir)
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "DIV")
            @test row.loss == 0.1
            mets = Dict(e.key => e.value for e in StoreKit.get_metrics(store.db, row.id))
            @test mets["loss"] == "0.1"   # stores agree on the authoritative loss
        end
    end

    @testset "hardening: restore of out-of-root artifact does not clobber original" begin
        mktempdir() do store_root
            mktempdir() do ext
                clear_consumption!(); empty!(StoreKit.FILE_READS)
                figpath = joinpath(ext, "fig.png")     # OUTSIDE the store root
                write(figpath, "ORIGINAL")
                book!("OOR", artifact(figpath); store_dir=store_root)
                empty!(StoreKit.FILE_READS)

                write(figpath, "MODIFIED")             # change it on disk
                restored = restore("OOR"; to=joinpath(store_root, "restored"), store_dir=store_root)
                # the original must NOT be clobbered back to "ORIGINAL"
                @test read(figpath, String) == "MODIFIED"
                # and a copy landed under `to`
                @test any(r -> isfile(joinpath(store_root, "restored", r)), restored)
                clear_consumption!(); empty!(StoreKit.FILE_READS)
            end
        end
    end

    @testset "hardening: artifact snapshotted exactly once" begin
        mktempdir() do dir
            clear_consumption!(); empty!(StoreKit.FILE_READS)
            figpath = joinpath(dir, "g.png"); write(figpath, "x")
            book!("ONCE", artifact(figpath); store_dir=dir)
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "ONCE")
            snaps = [s.path for s in StoreKit.get_file_snapshots(store.db, row.id)]
            @test count(p -> occursin("g.png", p), snaps) == 1
            empty!(StoreKit.FILE_READS); clear_consumption!()
        end
    end

    @testset "env capture: Manifest snapshot + julia_version fingerprint" begin
        mktempdir() do dir
            clear_consumption!()
            book!("ENVON", :accepted; result="r", store_dir=dir)   # capture_env default true
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "ENVON")
            fps = Dict(e.key => e.value for e in StoreKit.get_result_fingerprints(store.db, row.id))
            @test fps["julia_version"] == string(VERSION)
            # numerical-environment knobs
            @test haskey(fps, "julia_threads")
            @test haskey(fps, "blas_threads")
            @test haskey(fps, "cpu")
            @test haskey(fps, "os")
            mp = BookKit._manifest_path()
            if mp !== nothing && isfile(mp)
                snaps = StoreKit.get_file_snapshots(store.db, row.id)
                @test any(s -> s.file_type == "env", snaps)   # Manifest cold-verifiable
                @test haskey(fps, "julia_manifest_hash")
            end
            clear_consumption!()
        end
    end

    @testset "env capture: capture_env=false disables it" begin
        mktempdir() do dir
            clear_consumption!()
            book!("ENVOFF", :accepted; result="r", capture_env=false, store_dir=dir)
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "ENVOFF")
            fps = Dict(e.key => e.value for e in StoreKit.get_result_fingerprints(store.db, row.id))
            @test !haskey(fps, "julia_version")
            @test !any(s -> s.file_type == "env", StoreKit.get_file_snapshots(store.db, row.id))
            clear_consumption!()
        end
    end

    @testset "hardening: book! truncates its own FILE_READS even on a mid-book error" begin
        mktempdir() do dir
            empty!(StoreKit.FILE_READS); clear_consumption!()
            n0 = length(StoreKit.FILE_READS)
            # capture_env reads the Manifest (env block) BEFORE the artifact error below;
            # the finally must still truncate that read so it can't leak into later bookings.
            @test_throws ErrorException book!("ERR", :accepted;
                result=artifact(joinpath(dir, "nope.bin")), store_dir=dir)
            @test length(StoreKit.FILE_READS) == n0
            empty!(StoreKit.FILE_READS); clear_consumption!()
        end
    end

    @testset "fit_quality folded into the metrics table" begin
        mktempdir() do dir
            book!("FQ2", :accepted; result="r", fit_quality=Dict("R2" => 0.98),
                  capture_env=false, store_dir=dir)
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "FQ2")
            mets = Dict(e.key => e.value for e in StoreKit.get_metrics(store.db, row.id))
            @test haskey(mets, "fit_quality")
            @test row.fit_quality !== nothing   # legacy column still written
        end
    end

    @testset "staleness_sweep: project-wide stale report" begin
        mktempdir() do dir
            clear_consumption!()
            book!("S1", :accepted; result="a", capture_env=false, store_dir=dir)
            book!("S2", :accepted; result="b", capture_env=false, store_dir=dir)
            @test isempty(staleness_sweep(; store_dir=dir))             # nothing stale yet
            @test length(staleness_sweep(; store_dir=dir, stale_only=false)) == 2

            # corrupt S1's blob → only S1 is stale
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "S1")
            write(joinpath(dir, ".provenance", "blobs", "$(row.result_hash).blob"), "corrupt-bytes")
            sweep = staleness_sweep(; store_dir=dir)
            @test any(nr -> nr[1] == "S1" && is_stale(nr[2]), sweep)
            @test !any(nr -> nr[1] == "S2", sweep)
            clear_consumption!()
        end
    end

    @testset "metrics persisted + loss mirrored" begin
        mktempdir() do dir
            book!("MT", :accepted; result="r", metrics=Dict("loss" => 1.5, "rmse" => 0.2), store_dir=dir)
            store = open_store(dir)
            row = StoreKit.latest_annotation(store.db, "MT")
            mets = Dict(e.key => e.value for e in StoreKit.get_metrics(store.db, row.id))
            @test mets["rmse"] == "0.2"
            @test row.loss == 1.5          # loss mirrored into the queryable column
        end
    end

    @testset "staleness: vcs + null normalization helpers" begin
        @test BookKit._base_ref("abc123-dirty") == "abc123"
        @test BookKit._base_ref("abc123") == "abc123"
        # svn refs: strip working-copy status, collapse mixed-rev range to committed rev
        @test BookKit._base_ref("svn:r123") == "svn:r123"
        @test BookKit._base_ref("svn:r123M") == "svn:r123"
        @test BookKit._base_ref("svn:r123:125M") == "svn:r125"
        @test BookKit._is_unknown_ref("unknown")
        @test BookKit._is_unknown_ref("")
        @test BookKit._is_unknown_ref("svn:rexported")   # svnversion non-revision output
        @test !BookKit._is_unknown_ref("abc123")
        @test !BookKit._is_unknown_ref("svn:r123M")
        @test BookKit._to_bool_or_nothing(0) == false
        @test BookKit._to_bool_or_nothing(1) == true
        @test BookKit._to_bool_or_nothing(missing) === nothing
        @test BookKit._to_bool_or_nothing(nothing) === nothing
        @test BookKit._str_or_nothing(missing) === nothing
        @test BookKit._str_or_nothing(nothing) === nothing
        @test BookKit._str_or_nothing("x") == "x"

        # A ref that cannot match the current tree reads as a VCS change
        # (when a VCS is resolvable here; otherwise the dimension is unchecked).
        d = BookKit._vcs_dim((vcs_ref="deadbeef000000", vcs_dirty=false))
        cur, _ = BookKit._vcs_describe()
        if BookKit._is_unknown_ref(cur)
            @test d.checked == false
        else
            @test d.stale == true
            @test any(s -> occursin("changed", s), d.details)
        end
    end

end

# Per-method lowered-IR fingerprint regression canary. This stays a top-level
# include because it defines its own module.
include("method_fingerprint_feasibility.jl")
