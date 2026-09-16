# Run with: Rscript --vanilla provisioning.R /absolute/path/to/src/provision.R
worker <- normalizePath(commandArgs(TRUE)[[1L]])
root <- tempfile("condar-test-")
dir.create(root)
repos <- file.path(root, c("first", "second"))
for (repo in repos) dir.create(file.path(repo, "src", "contrib"), recursive = TRUE)
make_package <- function(repo, name, version, imports = NULL) {
    pkg <- file.path(root, paste0(name, "-", version))
    dir.create(file.path(pkg, "R"), recursive = TRUE)
    writeLines(c(paste("Package:", name), paste("Version:", version), "Title: CondaR test fixture",
                 "Description: A tiny package for isolated installer integration tests.",
                 "Author: QSPKit", "Maintainer: QSPKit <test@example.org>", "License: MIT",
                 if (!is.null(imports)) paste("Imports:", imports)), file.path(pkg, "DESCRIPTION"))
    writeLines("export(value)", file.path(pkg, "NAMESPACE"))
    writeLines(paste0('value <- function() "', version, '"'), file.path(pkg, "R", "value.R"))
    old <- setwd(file.path(repo, "src", "contrib"))
    status <- system2(file.path(R.home("bin"), "R"), c("CMD", "build", "--no-build-vignettes", shQuote(pkg)), stdout = TRUE)
    setwd(old)
    stopifnot(is.null(attr(status, "status")))
}
make_package(repos[[1]], "condarfixture", "1.0.0")
make_package(repos[[2]], "condarfixture", "2.0.0")
make_package(repos[[1]], "condardependent", "1.0.0", "condarfixture (>= 1.0.0)")
for (repo in repos) tools::write_PACKAGES(file.path(repo, "src", "contrib"), type = "source")
config <- list(packages = list("condardependent"), suggests = FALSE,
               repos = list(list(name = "first", url = paste0("file://", repos[[1]])),
                            list(name = "second", url = paste0("file://", repos[[2]]))),
               package_options = list(), repo_options = list())
config_file <- file.path(root, "config.R")
# The worker expects an assignment.
write_config <- function() writeLines(c("config <-", capture.output(dput(config))), config_file)
plan <- file.path(root, "plan.rds")
lib <- file.path(root, "library")
dir.create(lib)
run_worker <- function(action, expected = 0L) {
    status <- system2(file.path(R.home("bin"), "Rscript"),
                     c("--vanilla", shQuote(worker), action, shQuote(config_file), shQuote(plan), shQuote(lib)))
    stopifnot(status == expected)
}
write_config()
run_worker("resolve")
records <- readRDS(plan)
stopifnot(records$condarfixture$Version == "1.0.0", names(records)[[1]] == "condarfixture")
# Repository policy wins over binary availability, including same-version
# sources that differ. Binaries are a transport optimization, not a resolver.
config$prebuilt <- list(condarfixture = list(version = "1.0.0",
    source_md5 = records$condarfixture$MD5sum, artifact = "https://example.org/fixture.conda"))
write_config()
# Attaching verified binaries does not reread repository metadata.
run_worker("select")
stopifnot(!is.null(readRDS(plan)$condarfixture$Binary),
          readRDS(plan)$condarfixture$Repository == "first",
          file.info(paste0(plan, ".build"))$size == 0)
config$prebuilt$condarfixture$source_md5 <- paste(rep("0", 32), collapse = "")
write_config()
run_worker("resolve")
stopifnot(is.null(readRDS(plan)$condarfixture$Binary))
config$prebuilt$condarfixture$source_md5 <- records$condarfixture$MD5sum
config$package_options <- list(condarfixture = list(Type = "source"))
write_config()
run_worker("resolve")
stopifnot(is.null(readRDS(plan)$condarfixture$Binary))
config$package_options <- list(condarfixture = list(Env = list(BUILD_FLAG = "custom")))
write_config()
run_worker("resolve")
stopifnot(is.null(readRDS(plan)$condarfixture$Binary))
config$package_options <- list()
config$prebuilt <- list()
write_config()
run_worker("resolve")
run_worker("install")
run_worker("validate")
# An interrupted install resumes existing valid packages without overwriting them.
marker <- file.info(file.path(lib, "condarfixture", "DESCRIPTION"))$mtime
run_worker("install")
stopifnot(identical(file.info(file.path(lib, "condarfixture", "DESCRIPTION"))$mtime, marker))
# Repository overrides take precedence over ordering, and changes select new versions.
config$package_options <- list(condarfixture = list(Repo = "second", Env = list(TEST_VALUE = "quotes'\"$()\\text")))
write_config()
run_worker("resolve")
stopifnot(readRDS(plan)$condarfixture$Version == "2.0.0")
# Fresh target: never update a library that might be loaded in another process.
lib <- file.path(root, "updated-library")
dir.create(lib)
run_worker("install")
run_worker("validate")
stopifnot(read.dcf(file.path(root, "library", "condarfixture", "DESCRIPTION"), fields="Version")[[1]] == "1.0.0")
# Missing namespaces fail validation instead of reporting success from directory presence.
unlink(file.path(lib, "condarfixture"), recursive = TRUE)
run_worker("validate", expected = 1L)
# Required dependency constraints cannot silently select incompatible versions.
config$package_options <- list()
config$packages <- list("missingpackage")
write_config()
run_worker("resolve", expected = 1L)
unlink(root, recursive = TRUE)
cat("R installer integration checks passed\n")
