function _tinytex_roots()
    if Sys.isapple()
        return [joinpath(homedir(), "Library", "TinyTeX"), joinpath(homedir(), ".TinyTeX")]
    elseif Sys.iswindows()
        return [joinpath(get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")), "TinyTeX")]
    end
    return [joinpath(homedir(), ".TinyTeX")]
end

function _tinytex_platform_dirs()
    Sys.isapple() && return ("universal-darwin", "$(Sys.ARCH)-darwin")
    Sys.iswindows() && return ("windows", "win32")
    Sys.islinux() && return ("$(Sys.ARCH)-linux", "$(Sys.ARCH)-linuxmusl")
    return ()
end

"""
    ensure_tex_path!(; roots = _tinytex_roots())

Make an existing native TinyTeX installation available to embedded R and its
child processes. Preserve `pdflatex` already on `PATH`; otherwise search the
current platform's TinyTeX binary directories and add the first match to this
process's `PATH`. `roots` can supply custom installation locations.

Return the executable path, or `nothing` if none is found. This does not install
TeX, edit shell configuration, or select binaries built for another platform.
"""
function ensure_tex_path!(; roots = _tinytex_roots())
    lock(_R_LOCK) do
        existing = Sys.which("pdflatex")
        existing === nothing || return existing
        executable = Sys.iswindows() ? "pdflatex.exe" : "pdflatex"
        for root in roots, platform in _tinytex_platform_dirs()
            candidate = Sys.which(joinpath(root, "bin", platform, executable))
            candidate === nothing && continue
            separator = Sys.iswindows() ? ';' : ':'
            old_path = get(ENV, "PATH", "")
            ENV["PATH"] = isempty(old_path) ? dirname(candidate) :
                          string(dirname(candidate), separator, old_path)
            return candidate
        end
        return nothing
    end
end
