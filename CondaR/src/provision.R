# Runs in an isolated managed R subprocess, never in the user's embedded R.
args <- commandArgs(TRUE)
action <- args[[1L]]
source(args[[2L]], local = TRUE)
plan_file <- args[[3L]]
library <- args[[4L]]
options(timeout = max(300, getOption("timeout")))
base_library <- .Library
.libPaths(c(if (nzchar(library)) library, base_library), include.site = FALSE)

option_for <- function(pkg, repo) {
    out <- list(Suggests = config$suggests, Env = list())
    for (entry in list(config$repo_options[[repo]], config$package_options[[pkg]])) {
        if (!is.null(entry)) {
            out$Env <- modifyList(out$Env, entry$Env %||% list())
            out <- modifyList(out, entry[setdiff(names(entry), "Env")])
        }
    }
    out
}
`%||%` <- function(x, y) if (is.null(x)) y else x

download_metadata <- function(url, file, headers = NULL) {
    tryCatch({
        status <- download.file(url, file, quiet = TRUE, mode = "wb", headers = headers)
        if (status != 0L) stop("download.file returned ", status)
    }, error = function(e) {
        message("Cannot fetch ", url, ": ", conditionMessage(e))
        quit(status = 75L)
    })
}

read_github <- function(pkg) {
    message("CondaR: Resolving GitHub source for ", pkg)
    repo <- paste0("metrumresearchgroup/", pkg)
    file <- tempfile()
    on.exit(unlink(file))
    # GitHub's SHA media type avoids bootstrapping a JSON parser in fresh R.
    download_metadata(paste0("https://api.github.com/repos/", repo, "/commits/HEAD"),
                      file, c(Accept = "application/vnd.github.sha"))
    sha <- trimws(paste(readLines(file, warn = FALSE), collapse = ""))
    if (!grepl("^[0-9a-f]{40}$", sha)) stop("Invalid GitHub commit response for ", repo)
    download_metadata(paste0("https://raw.githubusercontent.com/", repo, "/", sha, "/DESCRIPTION"), file)
    rec <- as.list(read.dcf(file)[1L, ])
    if (!identical(rec$Package, pkg)) stop("Unexpected package DESCRIPTION for ", repo)
    rec$Repository <- "GitHub"
    rec$ContribURL <- paste0("https://github.com/", repo)
    rec$TarURL <- paste0("https://codeload.github.com/", repo, "/tar.gz/", sha)
    rec$Commit <- sha
    rec
}

read_repo <- function(repo) {
    message("CondaR: Reading repository ", repo$name)
    url <- paste0(sub("/$", "", repo$url), "/src/contrib")
    file <- tempfile(fileext = ".gz")
    on.exit(unlink(file))
    download_metadata(paste0(url, "/PACKAGES.gz"), file)
    con <- gzfile(file)
    on.exit(close(con), add = TRUE)
    db <- read.dcf(con)
    if (!all(c("Package", "Version") %in% colnames(db))) stop("Invalid package index: ", repo$url)
    rows <- lapply(seq_len(nrow(db)), function(i) {
        rec <- as.list(db[i, ])
        rec$Repository <- repo$name
        rec$ContribURL <- url
        filename <- if (is.null(rec$File) || is.na(rec$File)) paste0(rec$Package, "_", rec$Version, ".tar.gz") else rec$File
        rec$TarURL <- paste0(url, "/", filename)
        rec
    })
    rows
}

field <- function(rec, key) {
    x <- rec[[key]]
    if (is.null(x) || is.na(x)) "" else x
}

dependencies <- function(rec, suggests = FALSE) {
    fields <- c("Depends", "Imports", "LinkingTo", if (suggests) "Suggests")
    text <- paste(vapply(fields, function(k) field(rec, k), ""), collapse = ",")
    parts <- trimws(strsplit(text, ",", fixed = TRUE)[[1L]])
    parts[nzchar(parts)]
}

parse_dep <- function(text) {
    match <- regmatches(text, regexec("^([A-Za-z][A-Za-z0-9.]*)[[:space:]]*(\\(([<>=!]+)[[:space:]]*([^ )]+)\\))?$", text))[[1L]]
    if (!length(match)) stop("Unsupported R dependency declaration: ", text)
    list(name = match[[2L]], op = match[[4L]], version = match[[5L]])
}

satisfies <- function(actual, dep) {
    if (!nzchar(dep$op)) return(TRUE)
    cmp <- compareVersion(as.character(actual), dep$version)
    switch(dep$op, ">=" = cmp >= 0, "<=" = cmp <= 0, "==" = cmp == 0,
           ">" = cmp > 0, "<" = cmp < 0, "!=" = cmp != 0,
           stop("Unsupported dependency operator: ", dep$op))
}

binary_for <- function(rec) {
    binary <- config$prebuilt[[rec$Package]]
    if (is.null(binary) || !identical(binary$version, rec$Version) ||
        (nzchar(field(rec, "MD5sum")) && !identical(binary$source_md5, rec$MD5sum)) ||
        (!nzchar(field(rec, "MD5sum")) && !identical(binary$source_url, rec$TarURL)) ||
        identical(rec$Options$Type, "source") || length(rec$Options$Env)) return(NULL)
    binary
}

resolve_plan <- function() {
    repos <- lapply(config$repos, read_repo)
    all <- c(lapply(config$github_packages, read_github), unlist(repos, recursive = FALSE))
    base <- installed.packages(lib.loc = base_library)
    base <- base[!is.na(base[, "Priority"]) & base[, "Priority"] == "base", , drop = FALSE]
    candidates <- list()
    for (rec in all) {
        pkg <- rec$Package
        override <- config$package_options[[pkg]]$Repo
        if (!is.null(override) && rec$Repository != override) next
        os <- field(rec, "OS_type")
        if (nzchar(os) && os != .Platform$OS.type) next
        rdeps <- lapply(dependencies(rec), parse_dep)
        if (any(vapply(rdeps, function(d) d$name == "R" && !satisfies(getRversion(), d), FALSE))) next
        # First compatible repository wins, independently of later repo versions.
        previous <- candidates[[pkg]]
        if (is.null(previous) || (previous$Repository == rec$Repository &&
                                 compareVersion(rec$Version, previous$Version) > 0)) candidates[[pkg]] <- rec
    }
    selected <- list()
    visiting <- character()
    visit <- function(pkg) {
        if (pkg %in% names(selected) || pkg %in% rownames(base) || pkg == "R") return()
        if (pkg %in% visiting) return() # Suggests commonly creates cycles.
        rec <- candidates[[pkg]]
        if (is.null(rec)) stop("Package ", pkg, " is unavailable for R ", getRversion(), " in the configured repositories")
        opts <- option_for(pkg, rec$Repository)
        visiting <<- c(visiting, pkg)
        for (deptext in dependencies(rec, isTRUE(opts$Suggests))) {
            dep <- parse_dep(deptext)
            actual <- if (dep$name == "R") getRversion() else if (dep$name %in% rownames(base)) base[dep$name, "Version"] else candidates[[dep$name]]$Version
            if (is.null(actual) || !satisfies(actual, dep)) stop(pkg, " requires ", deptext, "; configured repositories cannot satisfy it")
            visit(dep$name)
        }
        visiting <<- setdiff(visiting, pkg)
        rec$Options <- opts
        rec$Binary <- binary_for(rec)
        selected[[pkg]] <<- rec
    }
    for (pkg in sort(unique(unlist(config$packages)))) visit(pkg)
    # Hard dependencies are installed before their dependents, including when
    # a Suggests cycle influenced the discovery order.
    ordered <- list()
    visiting <- character()
    order_pkg <- function(pkg) {
        if (pkg %in% names(ordered) || !(pkg %in% names(selected))) return()
        if (pkg %in% visiting) stop("Cyclic required R dependencies involving ", pkg)
        visiting <<- c(visiting, pkg)
        for (dep in lapply(dependencies(selected[[pkg]]), parse_dep)) order_pkg(dep$name)
        visiting <<- setdiff(visiting, pkg)
        ordered[[pkg]] <<- selected[[pkg]]
    }
    for (pkg in names(selected)) order_pkg(pkg)
    write_plan(ordered)
}

write_plan <- function(ordered) {
    saveRDS(ordered, plan_file, version = 2)
    records <- do.call(rbind, lapply(ordered[sort(names(ordered))], function(rec) {
        data.frame(Package = rec$Package, Version = rec$Version,
                   Repository = rec$Repository, URL = rec$ContribURL,
                   TarURL = field(rec, "TarURL"), Commit = field(rec, "Commit"),
                   MD5sum = field(rec, "MD5sum"),
                   Install = if (is.null(rec$Binary)) "source" else "binary",
                   BinaryArtifact = rec$Binary$artifact %||% "",
                   BinaryAllowed = !identical(rec$Options$Type, "source") && !length(rec$Options$Env),
                   stringsAsFactors = FALSE)
    }))
    write.table(records, paste0(plan_file, ".tsv"), sep = "\t", row.names = FALSE, quote = TRUE)
    jsonlite::write_json(records, paste0(plan_file, ".json"), dataframe = "rows", auto_unbox = TRUE)
    builds <- Filter(function(rec) is.null(rec$Binary) && identical(field(rec, "NeedsCompilation"), "yes"), ordered)
    writeLines(names(builds) %||% character(), paste0(plan_file, ".build"))
    binary_count <- sum(vapply(ordered, function(rec) !is.null(rec$Binary), FALSE))
    if (identical(action, "resolve"))
        message("CondaR: Selected ", length(ordered), " R packages from repositories")
    else
        message("CondaR: Resolved ", length(ordered), " R packages: ", binary_count,
                " source-verified binaries, ", length(ordered) - binary_count, " source installs")
}

install_one <- function(rec, i, total) {
    pkg <- rec$Package
    desc <- file.path(library, pkg, "DESCRIPTION")
    installed <- file.exists(desc) && tryCatch(
        identical(read.dcf(desc, fields = "Version")[[1L]], rec$Version),
        error = function(e) {
            message("CondaR: invalid DESCRIPTION for ", pkg, ": ", conditionMessage(e))
            FALSE
        })
    if (installed) {
        usable <- tryCatch({ loadNamespace(pkg, lib.loc = c(library, base_library)); TRUE },
                           error = function(e) {
                               message("CondaR: reinstalling unusable ", pkg, ": ", conditionMessage(e))
                               FALSE
                           })
        if (usable) {
            message("CondaR: [", i, "/", total, "] Reusing ", pkg, " ", rec$Version)
            return(invisible(NULL))
        }
    }
    if (!is.null(rec$Binary)) {
        message("CondaR: [", i, "/", total, "] Using prebuilt ", pkg, " ", rec$Version,
                " (source verified against ", rec$Repository, ")")
        origin <- file.path(base_library, pkg)
        original_desc <- file.path(origin, "DESCRIPTION")
        if (!file.exists(original_desc) || read.dcf(original_desc, fields = "Version")[[1L]] != rec$Version)
            stop("Resolved R binary is missing or mismatched: ", pkg)
        target <- file.path(library, pkg)
        if (dir.exists(target)) unlink(target, recursive = TRUE)
        if (!file.copy(origin, library, recursive = TRUE, copy.mode = TRUE, copy.date = TRUE))
            stop("Could not copy managed R binary: ", pkg)
        return(invisible(NULL))
    }
    message("CondaR: [", i, "/", total, "] Installing ", pkg, " ", rec$Version, " from ", rec$Repository)
    url <- rec$TarURL %||% paste0(rec$ContribURL, "/", pkg, "_", rec$Version, ".tar.gz")
    tarball <- tempfile(fileext = ".tar.gz")
    on.exit(unlink(tarball))
    download.file(url, tarball, mode = "wb", quiet = TRUE)
    md5 <- field(rec, "MD5sum")
    if (nzchar(md5) && !identical(unname(tools::md5sum(tarball)), md5)) stop("Checksum mismatch: ", pkg)
    vars <- unlist(rec$Options$Env)
    if (length(vars)) {
        old <- setNames(Sys.getenv(names(vars), unset = NA_character_), names(vars))
        on.exit({
            Sys.unsetenv(names(old)[is.na(old)])
            if (any(!is.na(old))) do.call(Sys.setenv, as.list(old[!is.na(old)]))
        }, add = TRUE)
        do.call(Sys.setenv, as.list(vars))
    }
    install.packages(tarball, repos = NULL, type = "source", lib = library,
                     dependencies = FALSE, quiet = FALSE)
    desc <- file.path(library, pkg, "DESCRIPTION")
    if (!file.exists(desc) || read.dcf(desc, fields = "Version")[[1L]] != rec$Version) stop("Installation failed for ", pkg)
}

validate <- function(plan) {
    for (i in seq_along(plan)) {
        rec <- plan[[i]]
        if (i == 1L || i %% 25L == 0L || i == length(plan)) {
            message("CondaR: Validating [", i, "/", length(plan), "] ", rec$Package)
        }
        desc <- file.path(library, rec$Package, "DESCRIPTION")
        if (!file.exists(desc) || read.dcf(desc, fields = "Version")[[1L]] != rec$Version) stop("Missing or mismatched managed package: ", rec$Package)
        loadNamespace(rec$Package, lib.loc = c(library, base_library))
    }
    message("CondaR: All ", length(plan), " R packages verified")
}

switch(action,
       resolve = resolve_plan(),
       select = {
           plan <- readRDS(plan_file)
           for (pkg in names(plan)) plan[[pkg]]$Binary <- binary_for(plan[[pkg]])
           write_plan(plan)
       },
       install = {
           plan <- readRDS(plan_file)
           for (i in seq_along(plan)) install_one(plan[[i]], i, length(plan))
           message("CondaR: Installation complete (", length(plan), " R packages)")
       },
       validate = validate(readRDS(plan_file)),
       stop("Unknown action: ", action))
