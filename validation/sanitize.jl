#!/usr/bin/env julia

const SANITIZATION_MAX_TEXT_BYTES = 5_000_000

const SANITIZATION_PRIVATE_MARKERS_ENV =
    "QSPKIT_PRIVATE_SANITIZATION_MARKERS"
const SANITIZATION_REQUIRE_PRIVATE_MARKERS_ENV =
    "QSPKIT_REQUIRE_PRIVATE_SANITIZATION_MARKERS"

function sanitization_truthy(value)
    lowercase(strip(String(value))) in ("1", "true", "yes", "on")
end

private_sanitization_markers_required() = sanitization_truthy(
    get(ENV, SANITIZATION_REQUIRE_PRIVATE_MARKERS_ENV, "false"))

"""Load case-insensitive literal review markers supplied outside the public tree."""
function private_sanitization_markers(; required=private_sanitization_markers_required())
    raw = get(ENV, SANITIZATION_PRIVATE_MARKERS_ENV, "")
    if isempty(strip(raw))
        required && error(
            "the private sanitization marker set is required but was not configured")
        return String[]
    end
    occursin('\0', raw) && error("the private sanitization marker set is malformed")
    markers = unique!(filter(!isempty, lowercase.(strip.(split(raw, '\n')))))
    all(marker -> length(marker) >= 4, markers) ||
        error("every private sanitization marker must contain at least four characters")
    return markers
end

const SANITIZATION_CONFIDENTIALITY_REGEXES = [
    Regex("(?i)\\b" * ("confid" * "ential") * "\\b"),
    Regex("(?i)\\b" * ("propri" * "etary") * "\\b"),
    Regex("(?i)\\b" * ("trade" * " secret") * "\\b"),
    Regex("(?i)\\b" * ("internal" * " use only") * "\\b"),
    Regex("(?i)\\b" * ("do not" * " distribute") * "\\b"),
    Regex("(?i)\\b" * ("non" * "-public") * "\\b"),
    Regex("(?i)\\b" * ("n" * "da") * "\\b"),
]

const SANITIZATION_ALLOWED_URL_HOSTS = Set([
    "cloud.r-project.org",
    "example.invalid",
    "ggplot2.tidyverse.org",
    "metrumresearchgroup.github.io",
    "packagemanager.posit.co",
    "vpc.ronkeizer.com",
])

const SANITIZATION_ALLOWED_GITHUB_PATHS = Set(lowercase.([
    "/JuliaObjects/Accessors.jl",
    "/SciML/ModelingToolkit.jl",
    "/metrumresearchgroup/mrggsave",
    "/ronkeizer/vpc",
]))

const SANITIZATION_URL_REGEX = Regex(
    "(?i)(?<![A-Za-z0-9+.-])([a-z][a-z0-9+.-]*)://" *
    "(?:[^@\\s/]+@)?(\\[[^\\]]+\\]|[A-Za-z0-9.-]+)" *
    "(/[^\\s\\\"'<>\\)\\]\\},;]*)?",
)
const SANITIZATION_HOSTLESS_URI_REGEX = Regex(
    "(?i)(?<![A-Za-z0-9+.-])([a-z][a-z0-9+.-]*):/{3,}",
)
const SANITIZATION_PROTOCOL_RELATIVE_URL_REGEX = Regex(
    "(?i)(?<![:/])//(?:[^@\\s/]+@)?" *
    "(\\[[^\\]]+\\]|localhost|[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+)(?=[:/])",
)
const SANITIZATION_EMAIL_REGEX = r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
const SANITIZATION_COMPANY_SUFFIX_REGEX = Regex(
    "(?i)\\b(?:" * join([
        "In" * "c\\.?",
        "L" * "LC",
        "Lt" * "d\\.?",
        "Gm" * "bH",
        "Corpor" * "ation",
    ], "|") * ")\\b",
)
const SANITIZATION_HOME_REGEXES = [
    Regex("(?i)/" * "(?:Users|home)/[^/\\s\\\"']+"),
    Regex("(?i)[A-Za-z]:(?:\\\\+|/+)Users(?:\\\\+|/+)[^\\\\/\\s\\\"']+"),
    Regex("(?i)\\b[A-Za-z]:\\\\+[^\\\\/:\\s\\\"']+[\\\\/]+[^\\s\\\"']+"),
    Regex("(?i)/" * "(?:private/)?var/folders/[^\\s\\\"']+"),
    Regex("(?i)/" * "(?:(?:private/)?tmp|var/tmp)/[^\\s\\\"']+"),
    Regex("(?i)/" * "(?:Volumes|mnt)/[^/\\s\\\"']+(?:/[^\\s\\\"']*)?"),
    Regex("(?i)\\\\\\\\[A-Za-z0-9._-]{2,}[\\\\/]+[A-Za-z0-9._-]+" *
          "(?:[\\\\/][^\\s\\\"']*)?"),
    Regex("~" * "[\\\\/](?:Projects|Documents|Desktop)[\\\\/]"),
]

const SANITIZATION_ALLOWED_NON_TEXT_PATHS = Set{String}()

const SanitizationFinding = NamedTuple{
    (:path, :line, :kind),
    Tuple{String, Int, String},
}

normalize_sanitization_path(path) = replace(normpath(String(path)), '\\' => '/')

sanitization_finding(path, line, kind) = (
    path=normalize_sanitization_path(path),
    line=Int(line),
    kind=String(kind),
)

function allowed_sanitization_match(label, relative_path, matched)
    normalized = normalize_sanitization_path(relative_path)
    if label == "email"
        return normalized == "InjecKit/LICENSE"
    elseif label == "company suffix"
        return normalized == "ConfigKit/LICENSE"
    end
    return false
end

function scan_sanitization_line(line::AbstractString, relative_path, line_number;
                                private_markers=private_sanitization_markers())
    findings = SanitizationFinding[]
    lowered = lowercase(line)
    for marker in private_markers
        occursin(marker, lowered) || continue
        push!(findings, sanitization_finding(
            relative_path, line_number, "private review marker"))
    end
    for regex in SANITIZATION_CONFIDENTIALITY_REGEXES
        occursin(regex, line) || continue
        push!(findings, sanitization_finding(
            relative_path, line_number, "confidentiality marker"))
    end
    for regex in SANITIZATION_HOME_REGEXES
        occursin(regex, line) || continue
        push!(findings, sanitization_finding(
            relative_path, line_number, "private filesystem path"))
    end
    for _ in eachmatch(SANITIZATION_HOSTLESS_URI_REGEX, line)
        push!(findings, sanitization_finding(
            relative_path, line_number, "hostless network location"))
    end
    for matched in eachmatch(SANITIZATION_URL_REGEX, line)
        scheme = lowercase(matched.captures[1])
        host = lowercase(strip(matched.captures[2], ['[', ']', '.']))
        path = matched.captures[3]
        if scheme in ("http", "https")
            host in SANITIZATION_ALLOWED_URL_HOSTS && continue
            if host == "github.com" && path !== nothing
                normalized_path = lowercase(rstrip(path, '/'))
                normalized_path in SANITIZATION_ALLOWED_GITHUB_PATHS && continue
            end
        end
        push!(findings, sanitization_finding(
            relative_path, line_number, "unreviewed network location"))
    end
    for matched in eachmatch(SANITIZATION_PROTOCOL_RELATIVE_URL_REGEX, line)
        host = lowercase(strip(matched.captures[1], '.'))
        host in SANITIZATION_ALLOWED_URL_HOSTS && continue
        push!(findings, sanitization_finding(
            relative_path, line_number, "unreviewed network location"))
    end
    for matched in eachmatch(SANITIZATION_EMAIL_REGEX, line)
        allowed_sanitization_match("email", relative_path, matched.match) && continue
        push!(findings, sanitization_finding(relative_path, line_number, "email"))
    end
    for matched in eachmatch(SANITIZATION_COMPANY_SUFFIX_REGEX, line)
        allowed_sanitization_match("company suffix", relative_path, matched.match) && continue
        push!(findings, sanitization_finding(
            relative_path, line_number, "company suffix"))
    end
    occursin(Regex("(?i)\\bgit" * "@[A-Za-z0-9.-]+:"), line) && push!(
        findings,
        sanitization_finding(relative_path, line_number, "SSH repository location"),
    )
    return findings
end

"""Apply the release-identification policy to a UTF-8 text payload."""
function scan_text(text::AbstractString, relative_path="<text>";
                   private_markers=private_sanitization_markers())
    findings = SanitizationFinding[]
    append!(findings, scan_sanitization_line(
        normalize_sanitization_path(relative_path), relative_path, 0;
        private_markers))
    for (line_number, line) in enumerate(eachline(IOBuffer(text)))
        append!(findings, scan_sanitization_line(
            line, relative_path, line_number; private_markers))
    end
    unique!(findings)
    return findings
end

function scan_file(path, relative_path;
                   allowed_non_text_paths=SANITIZATION_ALLOWED_NON_TEXT_PATHS,
                   max_text_bytes=SANITIZATION_MAX_TEXT_BYTES,
                   private_markers=private_sanitization_markers())
    findings = scan_text("", relative_path; private_markers)
    normalized = normalize_sanitization_path(relative_path)
    if islink(path)
        target = readlink(path)
        normalized in allowed_non_text_paths || push!(findings, sanitization_finding(
            relative_path, 0, "symbolic link requires an explicit allowance"))
        isabspath(target) && push!(findings, sanitization_finding(
            relative_path, 0, "absolute symbolic-link target"))
        append!(findings, scan_text(target, relative_path; private_markers))
        unique!(findings)
        return findings
    end
    if !isfile(path)
        push!(findings, sanitization_finding(relative_path, 0, "unsupported file type"))
        return findings
    end
    normalized in allowed_non_text_paths && return findings
    size = filesize(path)
    if size > max_text_bytes
        push!(findings, sanitization_finding(relative_path, 0, "oversize unreviewed file"))
        return findings
    end
    bytes = read(path)
    if 0x00 in bytes
        push!(findings, sanitization_finding(relative_path, 0, "binary or NUL-containing file"))
        return findings
    end
    text = String(bytes)
    if !isvalid(text)
        push!(findings, sanitization_finding(relative_path, 0, "invalid UTF-8 file"))
        return findings
    end
    append!(findings, scan_text(text, relative_path; private_markers))
    unique!(findings)
    return findings
end

"""Return tracked plus untracked, nonignored paths eligible for the next commit."""
function release_candidate_paths(root=normpath(joinpath(@__DIR__, "..")))
    isdir(joinpath(root, ".git")) ||
        error("release sanitization requires a Git working tree: $root")
    bytes = read(Cmd([
        "git", "-C", root, "ls-files", "--cached", "--others",
        "--exclude-standard", "-z",
    ]))
    text = String(bytes)
    isvalid(text) || error("Git returned a non-UTF-8 release path")
    paths = filter(!isempty, split(text, '\0'))
    return sort!(unique!(normalize_sanitization_path.(paths)))
end

function scan_release_tree(root=normpath(joinpath(@__DIR__, ".."));
                           paths=release_candidate_paths(root),
                           private_markers=private_sanitization_markers())
    findings = SanitizationFinding[]
    for relative_path in paths
        path = joinpath(root, split(relative_path, '/')...)
        ispath(path) || islink(path) || continue
        append!(findings, scan_file(path, relative_path; private_markers))
    end
    unique!(findings)
    return findings
end

function sanitization_error(label, findings)
    unsafe_paths = Set(
        finding.path for finding in findings if finding.line == 0
    )
    details = join(
        ["$(finding.path in unsafe_paths ? "<redacted-path>" : finding.path):" *
         "$(finding.line): $(finding.kind)" for finding in findings],
        "\n",
    )
    return ErrorException("$label failed:\n$details")
end

function validate_release_sanitization(root=normpath(joinpath(@__DIR__, ".."));
                                       require_private_markers=
                                           private_sanitization_markers_required(),
                                       kwargs...)
    markers = private_sanitization_markers(; required=require_private_markers)
    findings = scan_release_tree(root; private_markers=markers, kwargs...)
    isempty(findings) || throw(sanitization_error("release sanitization scan", findings))
    return true
end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        validate_release_sanitization()
        println("release sanitization scan: PASS")
    catch err
        showerror(stderr, err)
        println(stderr)
        exit(1)
    end
end
