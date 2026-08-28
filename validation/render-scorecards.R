MPN_SCORECARD_VERSION <- "0.5.4"
MPN_SCORECARD_COMMIT <- "116cf0d89b952f6fb92f00c4bef261742e819a75"

RESULT_NAMES <- c(
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
  "QSPKit_0.1.0-alpha.1"
)

RENDER_INPUT_SUFFIXES <- c(
  "pkg.json",
  "check.txt",
  "coverage.json",
  "scores.json",
  "metadata.json",
  "matrix.yaml",
  "comments.txt"
)

scorecard_pdf_name <- function(result_name) {
  paste0(result_name, ".scorecard.pdf")
}

expected_pdf_names <- function() {
  vapply(RESULT_NAMES, scorecard_pdf_name, character(1), USE.NAMES = FALSE)
}

require_regular_file <- function(path, label) {
  if (!identical(Sys.readlink(path), "")) {
    stop(sprintf("%s must not be a symbolic link", label))
  }
  info <- file.info(path)
  if (is.na(info$isdir) || isTRUE(info$isdir)) {
    stop(sprintf("%s is not a regular file", label))
  }
  if (is.na(info$size) || info$size <= 0) {
    stop(sprintf("%s is missing or empty", label))
  }
  invisible(path)
}

require_pdf <- function(path, label) {
  require_regular_file(path, label)
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  signature <- rawToChar(readBin(con, what = "raw", n = 5L))
  if (!identical(signature, "%PDF-")) {
    stop(sprintf("%s does not have a PDF signature", label))
  }
  invisible(path)
}

verify_renderer_install <- function() {
  if (!requireNamespace("mpn.scorecard", quietly = TRUE)) {
    stop("mpn.scorecard is not installed")
  }
  installed_version <- as.character(utils::packageVersion("mpn.scorecard"))
  if (!identical(installed_version, MPN_SCORECARD_VERSION)) {
    stop(sprintf(
      "mpn.scorecard version mismatch: expected %s, found %s",
      MPN_SCORECARD_VERSION,
      installed_version
    ))
  }
  description <- utils::packageDescription("mpn.scorecard")
  remote_sha <- description[["RemoteSha"]]
  if (is.null(remote_sha) || is.na(remote_sha) ||
      !identical(tolower(remote_sha), MPN_SCORECARD_COMMIT)) {
    stop(sprintf(
      "mpn.scorecard source mismatch: expected immutable commit %s",
      MPN_SCORECARD_COMMIT
    ))
  }
  invisible(TRUE)
}

validate_result_layout <- function(output_root) {
  if (!dir.exists(output_root) || !identical(Sys.readlink(output_root), "")) {
    stop("scorecard evidence root is missing or is a symbolic link")
  }
  actual <- sort(list.files(
    output_root,
    all.files = TRUE,
    no.. = TRUE,
    full.names = FALSE
  ))
  expected <- sort(RESULT_NAMES)
  if (!identical(actual, expected)) {
    stop("scorecard evidence root does not contain exactly the 13 expected result directories")
  }

  inputs <- vector("list", length(RESULT_NAMES))
  names(inputs) <- RESULT_NAMES
  for (result_name in RESULT_NAMES) {
    results_dir <- file.path(output_root, result_name)
    if (!dir.exists(results_dir) || !identical(Sys.readlink(results_dir), "")) {
      stop(sprintf("scorecard results directory is missing or unsafe: %s", result_name))
    }
    required <- file.path(
      results_dir,
      paste0(result_name, ".", RENDER_INPUT_SUFFIXES)
    )
    for (path in required) {
      require_regular_file(path, sprintf("render input %s", basename(path)))
    }
    inputs[[result_name]] <- required
  }
  inputs
}

validate_pdf_set <- function(cards_root) {
  if (!dir.exists(cards_root) || !identical(Sys.readlink(cards_root), "")) {
    stop("rendered-card root is missing or is a symbolic link")
  }
  actual <- sort(list.files(
    cards_root,
    all.files = TRUE,
    no.. = TRUE,
    full.names = FALSE
  ))
  expected <- sort(expected_pdf_names())
  if (!identical(actual, expected)) {
    stop("rendered-card root does not contain exactly the 13 expected PDFs")
  }
  for (filename in expected_pdf_names()) {
    require_pdf(file.path(cards_root, filename), sprintf("rendered card %s", filename))
  }
  invisible(TRUE)
}

safe_cards_root <- function(cards_root) {
  normalized <- normalizePath(cards_root, mustWork = FALSE)
  parent <- dirname(normalized)
  if (identical(normalized, parent) ||
      !identical(basename(normalized), "cards")) {
    stop("refusing an unsafe rendered-card output path")
  }
  normalized
}

render_scorecards <- function(output_root, cards_root) {
  verify_renderer_install()
  inputs <- validate_result_layout(output_root)
  cards_root <- safe_cards_root(cards_root)
  cards_parent <- dirname(cards_root)
  dir.create(cards_parent, recursive = TRUE, showWarnings = FALSE)

  render_workspace <- tempfile("qspkit-scorecard-render-")
  stage_root <- tempfile(
    paste0(".", basename(cards_root), "-stage-"),
    tmpdir = cards_parent
  )
  dir.create(render_workspace)
  dir.create(stage_root)
  on.exit(unlink(render_workspace, recursive = TRUE, force = TRUE), add = TRUE)
  on.exit(unlink(stage_root, recursive = TRUE, force = TRUE), add = TRUE)

  for (result_name in RESULT_NAMES) {
    isolated_results <- file.path(render_workspace, result_name)
    dir.create(isolated_results)
    copied <- file.copy(inputs[[result_name]], isolated_results, overwrite = FALSE)
    if (!all(copied)) {
      stop(sprintf("failed to stage render inputs for %s", result_name))
    }

    rendered <- mpn.scorecard::render_scorecard(
      results_dir = isolated_results,
      overwrite = FALSE,
      add_traceability = TRUE
    )
    expected_rendered <- file.path(isolated_results, scorecard_pdf_name(result_name))
    if (!identical(
      normalizePath(rendered, mustWork = FALSE),
      normalizePath(expected_rendered, mustWork = FALSE)
    )) {
      stop(sprintf("renderer returned an unexpected PDF path for %s", result_name))
    }
    require_pdf(expected_rendered, sprintf("rendered card %s", result_name))
    if (!file.copy(
      expected_rendered,
      file.path(stage_root, scorecard_pdf_name(result_name)),
      overwrite = FALSE
    )) {
      stop(sprintf("failed to stage rendered card for %s", result_name))
    }
  }

  validate_pdf_set(stage_root)
  if (!identical(Sys.readlink(cards_root), "")) {
    stop("refusing to replace a symbolic-link rendered-card root")
  }
  if (file.exists(cards_root) && !dir.exists(cards_root)) {
    stop("refusing to replace a non-directory rendered-card root")
  }
  if (dir.exists(cards_root)) {
    validate_pdf_set(cards_root)
    unlink(cards_root, recursive = TRUE, force = TRUE)
  }
  if (!file.rename(stage_root, cards_root)) {
    stop("failed to publish the rendered-card directory atomically")
  }
  validate_pdf_set(cards_root)
  cat(sprintf("rendered and validated %d scorecard PDFs\n", length(RESULT_NAMES)))
  invisible(cards_root)
}

main <- function(args = commandArgs(trailingOnly = TRUE)) {
  if (length(args) > 2L) {
    stop("usage: render-scorecards.R [evidence-root] [cards-root]")
  }
  output_root <- if (length(args) >= 1L) args[[1L]] else "output"
  cards_root <- if (length(args) >= 2L) args[[2L]] else "cards"
  render_scorecards(output_root, cards_root)
}

if (sys.nframe() == 0L) {
  main()
}
