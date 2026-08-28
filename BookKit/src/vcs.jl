# VCS description helpers.
# Detects git or svn and returns a short ref string.

"""
    _vcs_describe() -> (ref::String, dirty::Bool)

Detect the current VCS state. Tries git first, then svn.
Set `ENV["BOOKKIT_VCS"]` to `"git"`, `"svn"`, or `"auto"` (default).

Returns a tuple of `(ref_string, is_dirty)`.
"""
function _vcs_describe()
    mode = lowercase(get(ENV, "BOOKKIT_VCS", "auto"))

    if mode == "git" || mode == "auto"
        try
            ref = String(strip(read(`git describe --always --dirty`, String)))
            dirty = endswith(ref, "-dirty")
            return (ref, dirty)
        catch
            if mode == "git"
                return ("git:unknown", false)
            end
        end
    end

    if mode == "svn" || mode == "auto"
        try
            rev = String(strip(read(`svnversion`, String)))
            dirty = occursin("M", rev)
            return ("svn:r$rev", dirty)
        catch
            if mode == "svn"
                return ("svn:unknown", false)
            end
        end
    end

    return ("unknown", false)
end
