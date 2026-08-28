using Test

include(joinpath(@__DIR__, "..", "generate.jl"))

@testset "SDLC scorecard tooling" begin
    @test PACKAGES == [
        "BookKit", "CondaR", "ConfigKit", "InjecKit", "QSPKitCore", "QSPKitIO",
        "QSPReports", "ShowKit", "SimKit", "SpecKit", "StoreKit", "TargKit",
    ]
    @test !("DiffKit" in PACKAGES)
    @test validate_release_sanitization()
    @test validate_all_matrices()
    @test "test/test_prepared_api.jl" in executed_test_files("InjecKit")
    @test literal_includes("""
        fixture = \"include(\\\"not_executed.jl\\\")\"
        include("executed.jl")
    """) == ["executed.jl"]
    @test ".CondaPkg" in WORKING_TREE_ARCHIVE_EXCLUDES
    @test "*/.CondaPkg" in WORKING_TREE_ARCHIVE_EXCLUDES
    @test "validation/cards" in WORKING_TREE_ARCHIVE_EXCLUDES
    @test "LocalPreferences.toml" in WORKING_TREE_ARCHIVE_EXCLUDES
    @test "*/docs/build" in WORKING_TREE_ARCHIVE_EXCLUDES
    @test "*/docs/site" in WORKING_TREE_ARCHIVE_EXCLUDES
    @test "*/.idea" in WORKING_TREE_ARCHIVE_EXCLUDES
    @test "*/.vscode" in WORKING_TREE_ARCHIVE_EXCLUDES
    @test "*.tmp" in WORKING_TREE_ARCHIVE_EXCLUDES
    @test "*.bak" in WORKING_TREE_ARCHIVE_EXCLUDES

    withenv(
        "USER" => "private-local-user",
        "QSPKIT_BUG_REPORTS_URL" => "https://example.invalid/private",
        "GITHUB_ACTIONS" => nothing,
    ) do
        metadata = environment_metadata()
        serialized = sprint(show, metadata)
        @test executor_label() == "local"
        @test metadata["env_vars"]["QSPKIT_BUG_REPORTS_URL"] == "configured"
        @test !occursin("private-local-user", serialized)
        @test !occursin("example.invalid", serialized)
        @test !haskey(metadata["sys"], "machine")
        @test !haskey(metadata["sys"], "CPU threads")
    end
    withenv("GITHUB_ACTIONS" => "true") do
        @test executor_label() == "github-actions"
    end
    private_home = joinpath("/", "Users", "private-user")
    private_root = joinpath(private_home, "project")
    private_url = "https://" * "example.invalid/private"
    transcript = sanitize_transcript(
        "failure at $(joinpath(private_root, "file.jl")); see $private_url";
        root=private_root,
        home=private_home,
        bug_reports_url=private_url,
    )
    @test transcript == "failure at <QSPKIT_ROOT>/file.jl; see <BUG_REPORTS_URL>"
    @test !occursin("private-user", transcript)
    @test !occursin("example.invalid", transcript)
    mktemp(ROOT) do path, io
        write(io, transcript)
        close(io)
        @test validate_public_text_artifact(path)
    end

    public_metadata = Dict(
        "date" => "2026-08-28T00:00:00Z",
        "executor" => "local",
        "info" => Dict(
            "package" => "FixtureKit",
            "test_exit_code" => 0,
            "docs_exit_code" => 0,
            "coverage_counts" => Dict(
                "covered_lines" => 1,
                "executable_lines" => 1,
                "formula" => "100 * covered_lines / executable_lines",
            ),
            "resolved_manifest" => Dict(
                "artifact" => "FixtureKit_0.1.0.test.Manifest.toml",
                "sha256" => repeat("a", 64),
                "project_hash" => repeat("b", 40),
                "project_file" => "FixtureKit/test/Project.toml",
                "policy" => MANIFEST_BINDING_POLICY,
            ),
            "source" => Dict(
                "archive_mode" => "git-archive:abc123",
                "workspace_archive_mode" => "git-archive:abc123",
                "alpha_commit" => "abc123",
                "alpha_worktree_clean" => true,
            ),
            "julia_version" => "1.12.0",
            "env_vars" => Dict("QSPKIT_BUG_REPORTS_URL" => "configured"),
            "sys" => Dict(
                "kernel" => "example",
                "architecture" => "example",
                "Julia version" => "1.12.0",
            ),
        ),
    )
    @test validate_environment_metadata_payload(public_metadata, "FixtureKit")
    private_metadata = deepcopy(public_metadata)
    private_metadata["executor"] = "private-local-user"
    @test_throws ErrorException validate_environment_metadata_payload(
        private_metadata, "FixtureKit")
    extra_metadata = deepcopy(public_metadata)
    extra_metadata["info"]["operator"] = "person"
    @test_throws ErrorException validate_environment_metadata_payload(
        extra_metadata, "FixtureKit")
    extra_environment = deepcopy(public_metadata)
    extra_environment["info"]["env_vars"]["USER"] = "person"
    @test_throws ErrorException validate_environment_metadata_payload(
        extra_environment, "FixtureKit")
    aggregate_metadata = deepcopy(public_metadata)
    delete!(aggregate_metadata["info"], "package")
    delete!(aggregate_metadata["info"], "test_exit_code")
    delete!(aggregate_metadata["info"], "docs_exit_code")
    delete!(aggregate_metadata["info"]["source"], "workspace_archive_mode")
    @test validate_environment_metadata_payload(
        aggregate_metadata, AGGREGATE_NAME; kind=:aggregate)

    secret_email = join(("person", "internal.example"), '@')
    internal_url = uppercase("https") * "://" * "internal.example/path"
    ssh_url = "SsH" * "://" * "internal.example/repository"
    relative_url = "//" * "internal.example/path"
    relative_ip_url = "//" * "10.1.2.3/path"
    hostless_uri = uppercase("file") * ":///" * "etc/config"
    unreviewed_github = "https://" * "github.com/another-org/private-repository"
    restricted_marking = uppercase("confid" * "ential")
    unix_private_path = joinpath("/", "home", "person", "project")
    uppercase_private_path = joinpath("/", uppercase("users"), "person", "project")
    windows_private_path = join(("C:", "Users", "person", "project"), '\\')
    generic_windows_path = join(("D:", "workspace", "project"), '\\')
    escaped_windows_path = replace(windows_private_path, '\\' => "\\\\")
    for payload in (
        secret_email,
        internal_url,
        ssh_url,
        relative_url,
        relative_ip_url,
        hostless_uri,
        unreviewed_github,
        restricted_marking,
        unix_private_path,
        uppercase_private_path,
        generic_windows_path,
        escaped_windows_path,
    )
        @test !isempty(scan_text(payload, "fixture.txt"))
    end
    private_marker = "private-release-marker-fixture"
    withenv(
        SANITIZATION_PRIVATE_MARKERS_ENV => nothing,
        SANITIZATION_REQUIRE_PRIVATE_MARKERS_ENV => nothing,
    ) do
        @test isempty(private_sanitization_markers())
        @test isempty(scan_text(private_marker, "fixture.txt"))
        @test_throws ErrorException private_sanitization_markers(; required=true)
    end
    withenv(
        SANITIZATION_PRIVATE_MARKERS_ENV => uppercase(private_marker),
        SANITIZATION_REQUIRE_PRIVATE_MARKERS_ENV => "true",
    ) do
        @test private_sanitization_markers() == [uppercase(private_marker) |> lowercase]
        findings = scan_text(private_marker, "fixture.txt")
        @test any(finding -> finding.kind == "private review marker", findings)
        @test !occursin(
            private_marker,
            sprint(showerror, sanitization_error("fixture scan", findings)),
        )
    end
    @test isempty(scan_text(
        "https://metrumresearchgroup.github.io/example/project", "fixture.txt"))
    reviewed_github = "https://" * "github.com/SciML/ModelingToolkit.jl"
    @test isempty(scan_text(reviewed_github, "fixture.txt"))
    restricted_filename = restricted_marking * ".txt"
    filename_findings = scan_text("", restricted_filename)
    @test !isempty(filename_findings)
    @test !occursin(
        restricted_filename,
        sprint(showerror, sanitization_error("fixture scan", filename_findings)),
    )

    mktemp(ROOT) do path, io
        write(io, secret_email)
        close(io)
        captured = try
            validate_public_text_artifact(path)
            nothing
        catch err
            err
        end
        @test captured isa ErrorException
        @test !occursin(secret_email, sprint(showerror, captured))
    end
    mktemp(ROOT) do path, io
        write(io, UInt8[0x61, 0x00, 0x62])
        close(io)
        @test any(finding -> finding.kind == "binary or NUL-containing file",
                  scan_file(path, basename(path)))
        @test isempty(scan_file(
            path, basename(path); allowed_non_text_paths=Set([basename(path)])))
    end
    mktemp(ROOT) do path, io
        write(io, UInt8[0xff, 0xfe])
        close(io)
        @test any(finding -> finding.kind == "invalid UTF-8 file",
                  scan_file(path, basename(path)))
    end
    mktemp(ROOT) do path, io
        write(io, "12345")
        close(io)
        @test any(finding -> finding.kind == "oversize unreviewed file",
                  scan_file(path, basename(path); max_text_bytes=4))
    end

    mktempdir(ROOT) do directory
        link = joinpath(directory, "fixture-link")
        symlink(joinpath("/", "tmp", "fixture-target"), link)
        @test any(finding -> finding.kind == "absolute symbolic-link target",
                  scan_file(link, relpath(link, ROOT)))
    end

    mktempdir(ROOT) do repository
        run(`git -C $repository init -q`)
        open(joinpath(repository, ".gitignore"), "w") do io
            println(io, "ignored.txt")
        end
        for filename in ("tracked.txt", "untracked.txt", "ignored.txt")
            open(joinpath(repository, filename), "w") do io
                println(io, filename)
            end
        end
        run(`git -C $repository add tracked.txt`)
        @test release_candidate_paths(repository) ==
              [".gitignore", "tracked.txt", "untracked.txt"]
    end

    mktempdir(ROOT) do fixture_root
        package_root = joinpath(fixture_root, "FixtureKit")
        for directory in (
            fixture_root,
            joinpath(fixture_root, "validation"),
            package_root,
            joinpath(package_root, "test"),
            joinpath(package_root, "docs"),
        )
            mkpath(directory)
            write(joinpath(directory, "Manifest.toml"), "generated manifest")
        end
        for generated in (
            joinpath(fixture_root, "validation", "output", "evidence.txt"),
            joinpath(fixture_root, "validation", "cards", "card.pdf"),
            joinpath(package_root, "docs", "build", "index.html"),
            joinpath(package_root, "docs", "site", "index.html"),
            joinpath(package_root, "test", ".CondaPkg", "state"),
        )
            mkpath(dirname(generated))
            write(generated, "generated")
        end
        coverage = joinpath(package_root, "src", "source.jl.123.cov")
        mkpath(dirname(coverage))
        write(coverage, "source copy")
        retained = joinpath(package_root, "src", "source.jl")
        write(retained, "module FixtureKit end")

        @test clean_generated(; root=fixture_root, packages=["FixtureKit"]) > 0
        @test isfile(retained)
        @test !ispath(coverage)
        @test isempty(filter(
            path -> isfile(path) && generated_environment_filename(basename(path)),
            [joinpath(dir, "Manifest.toml") for dir in (
                fixture_root,
                joinpath(fixture_root, "validation"),
                package_root,
                joinpath(package_root, "test"),
                joinpath(package_root, "docs"),
            )],
        ))
        @test !ispath(joinpath(fixture_root, "validation", "output"))
        @test !ispath(joinpath(fixture_root, "validation", "cards"))
        @test !ispath(joinpath(package_root, "docs", "build"))
        @test !ispath(joinpath(package_root, "docs", "site"))
        @test !ispath(joinpath(package_root, "test", ".CondaPkg"))
    end

    mktempdir(ROOT) do directory
        stdout_path = joinpath(directory, "fixture.stdout")
        stderr_path = joinpath(directory, "fixture.stderr")
        result = withenv("QSPKIT_BUG_REPORTS_URL" => private_url) do
            capture_sanitized_transcripts(stdout_path, stderr_path) do stdout, stderr
                println(stdout, "source: $ROOT")
                println(stderr, "endpoint: $private_url")
                7
            end
        end
        @test result == 7
        @test read(stdout_path, String) == "source: <QSPKIT_ROOT>\n"
        @test read(stderr_path, String) == "endpoint: <BUG_REPORTS_URL>\n"

        rejected_path = joinpath(directory, "rejected.stdout")
        @test_throws ErrorException capture_sanitized_transcripts(
            rejected_path, joinpath(directory, "rejected.stderr")) do stdout, _
            println(stdout, secret_email)
            1
        end
        @test !ispath(rejected_path)
    end

    mktempdir(ROOT) do directory
        prefix = joinpath(directory, "FixtureKit_0.1.0")
        for kind in (:tests, :docs)
            suffix = string(kind)
            stdout_path = prefix * ".$suffix.stdout"
            stderr_path = prefix * ".$suffix.stderr"
            check_path = kind == :tests ? prefix * ".check.txt" :
                prefix * ".docs.check.txt"
            open(stdout_path, "w") do io
                println(io, "$suffix standard output")
            end
            open(stderr_path, "w") do io
                write(io, "$suffix standard error without newline")
            end
            exit_code = kind == :tests ? 0 : 7
            write_process_check(
                check_path, "FixtureKit", kind, exit_code, stdout_path, stderr_path)
            @test validate_process_evidence("FixtureKit", prefix, kind, exit_code)
            @test first(eachline(check_path)) == process_status(exit_code)
            @test occursin(read(stdout_path, String), read(check_path, String))
            @test occursin(read(stderr_path, String), read(check_path, String))
            @test process_score(exit_code) == (exit_code == 0 ? 1.0 : 0.0)

            original = read(check_path, String)
            open(check_path, "w") do io
                write(io, original)
                println(io, "tampered check")
            end
            @test_throws ErrorException validate_process_evidence(
                "FixtureKit", prefix, kind, exit_code)
            open(check_path, "w") do io
                write(io, original)
            end
            open(stdout_path, "a") do io
                println(io, "tampered after check generation")
            end
            @test_throws ErrorException validate_process_evidence(
                "FixtureKit", prefix, kind, exit_code)
        end
    end

    mktempdir(ROOT) do directory
        project_path = joinpath(directory, "Project.toml")
        manifest_path = joinpath(directory, "FixtureKit_0.1.0.test.Manifest.toml")
        open(project_path, "w") do io
            println(io, "[deps]")
            println(io, "Example = \"7876af07-990d-54b4-ab0e-23690620f79a\"")
            println(io)
            println(io, "[compat]")
            println(io, "Example = \"0.5\"")
        end
        project_hash = current_project_resolve_hash(project_path)
        open(manifest_path, "w") do io
            println(io, "manifest_format = \"2.0\"")
            println(io, "project_hash = \"$project_hash\"")
        end
        project_relative = relpath(project_path, ROOT)
        binding = resolved_manifest_binding(manifest_path, project_relative)
        @test validate_resolved_manifest_binding(
            binding, manifest_path, project_relative)
        @test binding["sha256"] == file_sha256(manifest_path)
        @test binding["policy"] == MANIFEST_BINDING_POLICY

        bad_binding = deepcopy(binding)
        bad_binding["sha256"] = repeat("0", 64)
        @test_throws ErrorException validate_resolved_manifest_binding(
            bad_binding, manifest_path, project_relative)
        open(manifest_path, "a") do io
            println(io, "# altered evidence")
        end
        @test_throws ErrorException validate_resolved_manifest_binding(
            binding, manifest_path, project_relative)
    end

    fixture_rows = Dict(
        "AlphaKit" => [Dict(
            "entrypoint" => "alpha",
            "code" => "src/alpha.jl",
            "doc" => "docs/src/alpha.md",
            "tests" => ["test/alpha_test.jl"],
        )],
        "BetaKit" => [Dict(
            "entrypoint" => "beta",
            "code" => "src/beta.jl",
            "doc" => "README.md",
            "tests" => ["test/beta_test.jl"],
        )],
    )
    fixture_matrix = aggregate_matrix_text(
        packages=["AlphaKit", "BetaKit"], matrix_reader=pkg -> fixture_rows[pkg])
    @test startswith(fixture_matrix, "# Generated from the validated package matrices")
    @test occursin("AlphaKit.alpha", fixture_matrix)
    altered_rows = deepcopy(fixture_rows)
    altered_rows["BetaKit"][1]["tests"] = ["test/changed.jl"]
    @test fixture_matrix != aggregate_matrix_text(
        packages=["AlphaKit", "BetaKit"], matrix_reader=pkg -> altered_rows[pkg])

    aggregate_components = [
        Dict(
            "package" => "AlphaKit",
            "status" => "available",
            "scores" => Dict("testing" => Dict("check" => 1.0)),
        ),
        Dict(
            "package" => "BetaKit",
            "status" => "available",
            "scores" => Dict("testing" => Dict("check" => 0.0)),
        ),
    ]
    aggregate_checks = Dict(
        "AlphaKit" => "PASS\npackage: AlphaKit\n",
        "BetaKit" => "FAIL\npackage: BetaKit\n",
    )
    aggregate_check = canonical_aggregate_check(aggregate_components, aggregate_checks)
    @test first(eachline(IOBuffer(aggregate_check))) == "FAIL"
    @test occursin("===== BEGIN AlphaKit CHECK =====", aggregate_check)
    @test occursin(aggregate_checks["BetaKit"], aggregate_check)
    altered_checks = deepcopy(aggregate_checks)
    altered_checks["AlphaKit"] *= "tampered\n"
    @test aggregate_check != canonical_aggregate_check(aggregate_components, altered_checks)

    mktempdir(ROOT) do output_root
        result_name = "FixtureKit_0.1.0"
        result_root = joinpath(output_root, result_name)
        mkpath(result_root)
        open(joinpath(result_root, "safe.txt"), "w") do io
            println(io, "public evidence")
        end
        open(joinpath(result_root, result_name * ".tar.gz"), "w") do io
            write(io, UInt8[0x00, 0xff])
        end
        @test validate_output_privacy(output_root)
        unexpected_archive = joinpath(result_root, "unexpected.tar.gz")
        open(unexpected_archive, "w") do io
            write(io, UInt8[0x00, 0xff])
        end
        @test_throws ErrorException validate_output_privacy(output_root)
        rm(unexpected_archive)
        open(joinpath(result_root, "unsafe.txt"), "w") do io
            println(io, internal_url)
        end
        @test_throws ErrorException validate_output_privacy(output_root)
    end

    @test expected_scorecard_result_names() == [
        "BookKit_0.1.0",
        "CondaR_0.1.0",
        "ConfigKit_0.1.1",
        "InjecKit_0.1.0",
        "QSPKitCore_0.1.0",
        "QSPKitIO_0.1.0",
        "QSPReports_0.1.0",
        "ShowKit_0.1.0",
        "SimKit_0.1.0",
        "SpecKit_0.1.0",
        "StoreKit_0.1.0",
        "TargKit_0.4.0",
        "QSPKit_0.1.0-alpha.1",
    ]
    @test length(expected_scorecard_pdf_names()) == 13
    @test all(endswith(".scorecard.pdf"), expected_scorecard_pdf_names())

    mktempdir(ROOT) do cards_root
        expected = [
            "AlphaKit_0.1.0.scorecard.pdf",
            "BetaKit_0.2.0.scorecard.pdf",
        ]
        for filename in expected
            open(joinpath(cards_root, filename), "w") do io
                write(io, "%PDF-1.7\nsynthetic test fixture\n")
            end
        end
        safe_extractor = (_, text_path) -> open(text_path, "w") do io
            println(io, "public scorecard text")
        end
        safe_metadata_extractor = (_, metadata_path) -> open(metadata_path, "w") do io
            println(io, "Title: QSPKit scorecard")
            println(io, "Creator: pinned public renderer")
        end
        @test validate_rendered_scorecard_privacy(
            cards_root;
            expected_names=expected,
            extractor=safe_extractor,
            metadata_extractor=safe_metadata_extractor,
        )

        unexpected = joinpath(cards_root, "unexpected.pdf")
        open(unexpected, "w") do io
            write(io, "%PDF-1.7\n")
        end
        @test_throws ErrorException validate_rendered_scorecard_privacy(
            cards_root;
            expected_names=expected,
            extractor=safe_extractor,
            metadata_extractor=safe_metadata_extractor,
        )
        rm(unexpected)

        unsafe_extractor = (_, text_path) -> open(text_path, "w") do io
            println(io, internal_url)
        end
        @test_throws ErrorException validate_rendered_scorecard_privacy(
            cards_root;
            expected_names=expected,
            extractor=unsafe_extractor,
            metadata_extractor=safe_metadata_extractor,
        )

        unsafe_metadata_extractor = (_, metadata_path) -> open(metadata_path, "w") do io
            println(io, "Author: $internal_url")
        end
        @test_throws ErrorException validate_rendered_scorecard_privacy(
            cards_root;
            expected_names=expected,
            extractor=safe_extractor,
            metadata_extractor=unsafe_metadata_extractor,
        )

        empty_extractor = (_, text_path) -> touch(text_path)
        @test_throws ErrorException validate_rendered_scorecard_privacy(
            cards_root;
            expected_names=expected,
            extractor=empty_extractor,
            metadata_extractor=safe_metadata_extractor,
        )
        empty_metadata_extractor = (_, metadata_path) -> touch(metadata_path)
        @test_throws ErrorException validate_rendered_scorecard_privacy(
            cards_root;
            expected_names=expected,
            extractor=safe_extractor,
            metadata_extractor=empty_metadata_extractor,
        )

        open(joinpath(cards_root, expected[1]), "w") do io
            write(io, "not a PDF")
        end
        @test_throws ErrorException validate_rendered_scorecard_privacy(
            cards_root;
            expected_names=expected,
            extractor=safe_extractor,
            metadata_extractor=safe_metadata_extractor,
        )
    end

    workflow_path = joinpath(ROOT, ".github", "workflows", "scorecards.yaml")
    workflow = read(workflow_path, String)
    @test YAML.load_file(workflow_path) isa AbstractDict
    action_commit = "d3c5be51b12e724e68f33216ca3c148b66d5f0b6"
    renderer_commit = "116cf0d89b952f6fb92f00c4bef261742e819a75"
    @test count(action_commit, workflow) == 4
    @test count(renderer_commit, workflow) >= 2
    @test occursin("runs-on: ubuntu-24.04", workflow)
    @test occursin("r-version: '4.5.1'", workflow)
    @test occursin("pandoc-version: '3.1.11'", workflow)
    @test occursin("TINYTEX_VERSION: '2026.01'", workflow)
    @test occursin("cran/__linux__/noble/2026-01-16", workflow)
    @test occursin("validation/render-scorecards.R", workflow)
    @test occursin("pdf-privacy validation/cards", workflow)
    @test occursin("path: validation/cards/*.pdf", workflow)
    @test occursin("needs: privacy-preflight", workflow)
    @test occursin(
        "QSPKIT_PRIVATE_SANITIZATION_MARKERS: \${{ secrets.QSPKIT_PRIVATE_SANITIZATION_MARKERS }}",
        workflow,
    )
    @test count("secrets.QSPKIT_PRIVATE_SANITIZATION_MARKERS", workflow) == 4
    @test count("QSPKIT_REQUIRE_PRIVATE_SANITIZATION_MARKERS: 'true'", workflow) == 4
    @test count("julia --startup-file=no --project=validation validation/generate.jl privacy", workflow) == 2
    workflow_location(needle) = begin
        found = findfirst(needle, workflow)
        found === nothing && error("workflow fixture is missing `$needle`")
        first(found)
    end
    @test workflow_location("Verify all 13 scorecards") <
          workflow_location("Set up R 4.5.1") <
          workflow_location("Render exactly 13 scorecard PDFs") <
          workflow_location("Extract and validate rendered-card privacy") <
          workflow_location("Upload 13 rendered scorecard PDFs")

    renderer = read(joinpath(ROOT, "validation", "render-scorecards.R"), String)
    @test occursin(renderer_commit, renderer)
    @test occursin("mpn.scorecard::render_scorecard", renderer)
    @test occursin("does not contain exactly the 13 expected PDFs", renderer)
    @test all(
        result -> occursin("\"$result\"", renderer),
        expected_scorecard_result_names(),
    )

    @test changelog_line_current("- ConfigKit 0.1.1\n", "ConfigKit", "0.1.1")
    @test !changelog_line_current(
        "- ConfigKit is included\n- another package is 0.1.1\n",
        "ConfigKit",
        "0.1.1",
    )
    fixture_commit = repeat("a", 40)
    stale_commit = repeat("b", 40)
    @test release_commit((fixture_commit, true)) == fixture_commit
    @test_throws ErrorException release_commit((nothing, false))
    @test_throws ErrorException release_commit((fixture_commit, false))
    @test_throws ErrorException release_commit(("abc123", true))

    release_source = Dict(
        "alpha_commit" => fixture_commit,
        "alpha_worktree_clean" => true,
        "archive_mode" => "git-archive:$fixture_commit",
        "workspace_archive_mode" => "git-archive:$fixture_commit",
    )
    @test validate_release_source_info(
        release_source, fixture_commit; require_workspace_archive=true)
    for (field, bad_value) in (
        "alpha_commit" => stale_commit,
        "alpha_worktree_clean" => false,
        "archive_mode" => "working-tree",
        "workspace_archive_mode" => "git-archive:$stale_commit",
    )
        stale_source = deepcopy(release_source)
        stale_source[field] = bad_value
        @test_throws ErrorException validate_release_source_info(
            stale_source, fixture_commit; require_workspace_archive=true)
    end

    mktempdir(ROOT) do repository
        run(`git -C $repository init -q`)
        mkpath(joinpath(repository, "PackageKit"))
        mkpath(joinpath(repository, "validation"))
        open(joinpath(repository, "PackageKit", "source.txt"), "w") do io
            println(io, "canonical source")
        end
        matrix_source = joinpath(repository, "validation", "matrix-FixtureKit.yaml")
        open(matrix_source, "w") do io
            println(io, "- entrypoint: fixture")
        end
        run(`git -C $repository add PackageKit/source.txt validation/matrix-FixtureKit.yaml`)
        run(`git -C $repository -c user.name=release-test -c user.email=release-test commit -qm initial`)
        commit = strip(read(`git -C $repository rev-parse HEAD`, String))
        @test occursin(r"^[0-9a-f]{40}$", commit)
        @test git_blob_bytes(
            commit, "validation/matrix-FixtureKit.yaml"; root=repository) == read(matrix_source)

        matrix_copy = joinpath(repository, "matrix-copy.yaml")
        cp(matrix_source, matrix_copy)
        @test validate_package_matrix_copy(
            matrix_copy, "FixtureKit"; release=true, commit, root=repository)
        open(matrix_copy, "a") do io
            println(io, "# tampered")
        end
        @test_throws ErrorException validate_package_matrix_copy(
            matrix_copy, "FixtureKit"; release=true, commit, root=repository)

        workspace_archive = joinpath(repository, "workspace.tar.gz")
        identical_archive = joinpath(repository, "workspace-copy.tar.gz")
        package_archive = joinpath(repository, "package.tar.gz")
        write_git_archive(workspace_archive, commit; root=repository)
        write_git_archive(identical_archive, commit; root=repository)
        write_git_archive(
            package_archive, commit; package="PackageKit", root=repository)
        @test read(workspace_archive) == read(identical_archive)
        cache = Dict{Tuple{String, String, String}, String}()
        @test validate_git_archive(workspace_archive, commit; root=repository, cache)
        @test length(cache) == 1
        @test validate_git_archive(identical_archive, commit; root=repository, cache)
        @test length(cache) == 1
        @test validate_git_archive(
            package_archive, commit; package="PackageKit", root=repository, cache)
        @test length(cache) == 2

        open(joinpath(repository, "PackageKit", "source.txt"), "w") do io
            println(io, "changed source")
        end
        run(`git -C $repository add PackageKit/source.txt`)
        run(`git -C $repository -c user.name=release-test -c user.email=release-test commit -qm changed`)
        changed_commit = strip(read(`git -C $repository rev-parse HEAD`, String))
        write_git_archive(workspace_archive, changed_commit; root=repository)
        @test_throws ErrorException validate_git_archive(
            workspace_archive, commit; root=repository, cache)
    end

    covered, executable, percent = weighted_coverage([
        Dict("covered_lines" => 90, "executable_lines" => 100),
        Dict("covered_lines" => 1, "executable_lines" => 10),
    ])
    @test (covered, executable) == (91, 110)
    @test percent == 100 * 91 / 110
    @test percent != (90 + 10) / 2

    available_components = [
        Dict(
            "status" => "available",
            "coverage_counts" => Dict("covered_lines" => 90, "executable_lines" => 100),
        ),
        Dict(
            "status" => "available",
            "coverage_counts" => Dict("covered_lines" => 1, "executable_lines" => 10),
        ),
    ]
    @test aggregate_coverage(available_components) == (91, 110, 100 * 91 / 110)
    invalid_components = deepcopy(available_components)
    invalid_components[2]["status"] = "missing"
    @test aggregate_coverage(invalid_components) == (0, 110, 0.0)

    score_fixture = Dict(
        "testing" => Dict("check" => 0.0, "coverage" => 0.5),
        "documentation" => Dict("has_website" => 1.0, "has_news" => 1.0),
        "maintenance" => Dict("has_maintainer" => 1.0, "news_current" => 0.0),
        "transparency" => Dict("has_source_control" => 1.0, "has_bug_reports_url" => 0.0),
    )
    @test validate_score_schema(score_fixture, Dict("overall" => 50.0, "files" => Any[]))
    @test_throws ErrorException validate_score_schema(
        score_fixture, Dict("overall" => 51.0, "files" => Any[]))
    @test validate_process_score_bindings("FixtureKit", score_fixture, 1, 0)
    altered_process_scores = deepcopy(score_fixture)
    altered_process_scores["testing"]["check"] = 1.0
    @test_throws ErrorException validate_process_score_bindings(
        "FixtureKit", altered_process_scores, 1, 0)
    altered_process_scores = deepcopy(score_fixture)
    altered_process_scores["documentation"]["has_website"] = 0.0
    @test_throws ErrorException validate_process_score_bindings(
        "FixtureKit", altered_process_scores, 1, 0)

    components = [
        Dict("scores" => Dict("testing" => Dict("check" => 1.0))),
        Dict("scores" => Dict("testing" => Dict("check" => 0.0))),
    ]
    @test minimum(component["scores"]["testing"]["check"] for component in components) == 0.0

    twelve_components = [
        Dict("scores" => Dict(
            "testing" => Dict("check" => 1.0, "coverage" => i / 24),
            "documentation" => Dict("has_website" => 1.0, "has_news" => i % 2),
            "maintenance" => Dict("has_maintainer" => 1.0, "news_current" => i % 3 == 0 ? 1.0 : 0.0),
            "transparency" => Dict("has_source_control" => 1.0, "has_bug_reports_url" => 0.0),
        ))
        for i in 1:12
    ]
    aggregate_fixture = aggregate_scores(twelve_components, 50.0)
    @test aggregate_fixture["testing"]["check"] == 1.0
    @test aggregate_fixture["testing"]["coverage"] == 0.5
    @test aggregate_fixture["documentation"]["has_news"] == 0.5
    @test validate_aggregate_scores(aggregate_fixture, twelve_components, 50.0)
    failed_components = deepcopy(twelve_components)
    failed_components[12]["scores"]["testing"]["check"] = 0.0
    @test aggregate_scores(failed_components, 50.0)["testing"]["check"] == 0.0
    altered_aggregate = deepcopy(aggregate_fixture)
    altered_aggregate["maintenance"]["news_current"] = 1.0
    @test_throws ErrorException validate_aggregate_scores(
        altered_aggregate, twelve_components, 50.0)

    component_scores = deepcopy(aggregate_fixture)
    component_counts = Dict("covered_lines" => 10, "executable_lines" => 20)
    component_fixture = Dict(
        "package" => "FixtureKit",
        "version" => "0.1.0",
        "status" => "available",
        "scores" => component_scores,
        "coverage_counts" => component_counts,
    )
    @test validate_component_snapshot(
        component_fixture, "FixtureKit", "0.1.0", component_scores, component_counts)
    stale_component = deepcopy(component_fixture)
    stale_component["coverage_counts"]["covered_lines"] = 9
    @test_throws ErrorException validate_component_snapshot(
        stale_component, "FixtureKit", "0.1.0", component_scores, component_counts)

    unavailable = missing_component("BookKit")
    @test validate_unavailable_component(unavailable, "BookKit")
    unavailable["scores"]["testing"]["coverage"] = 0.1
    @test_throws ErrorException validate_unavailable_component(unavailable, "BookKit")
end
