# The resolved binary environment must load without a compiler or Apple SDK.
args <- commandArgs(TRUE)
source(args[[1L]], local = TRUE)
.libPaths(.Library, include.site = FALSE)
for (i in seq_along(packages)) {
    rec <- packages[[i]]
    desc <- file.path(.Library, rec$package, "DESCRIPTION")
    if (!file.exists(desc) || read.dcf(desc, fields = "Version")[[1L]] != rec$version)
        stop("Missing or mismatched R binary in managed runtime: ", rec$package)
    loadNamespace(rec$package, lib.loc = .Library)
    if (i %% 20L == 0L || i == length(packages))
        message("CondaR: Verified R binaries [", i, "/", length(packages), "]")
}
message("CondaR: Resolved R binaries verified")
