# Verify the managed build environment before downloading any R packages.
# No project R packages or host package libraries are used by this check.
prefix <- normalizePath(commandArgs(TRUE)[[1L]], winslash = "/", mustWork = TRUE)
native <- if (.Platform$OS.type == "windows") file.path(prefix, "Library") else prefix
message("CondaR: Checking managed development headers and libraries")
required <- c("include/libxml2/libxml/tree.h", "lib/pkgconfig/libxml-2.0.pc",
              "include/curl/curl.h", "include/openssl/ssl.h", "include/zlib.h",
              "include/expat.h", "include/poppler/cpp/poppler-document.h")
link <- if (.Platform$OS.type == "windows") "lib/libxml2.lib" else
    if (Sys.info()[["sysname"]] == "Darwin") "lib/libxml2.dylib" else "lib/libxml2.so"
missing <- c(required, link)[!file.exists(file.path(native, c(required, link)))]
if (length(missing)) stop("Managed native development files are missing: ",
                          paste(missing, collapse = ", "), ". Runtime: ", prefix,
                          ". This is a CondaR runtime packaging failure.")

pkgconfig <- Sys.which("pkg-config")
if (!nzchar(pkgconfig)) stop("Managed pkg-config executable is missing")
pc <- function(args) {
    out <- system2(pkgconfig, args, stdout = TRUE)
    if (!is.null(attr(out, "status")) && attr(out, "status") != 0L)
        stop("Managed pkg-config failed: ", paste(args, collapse = " "))
    paste(out, collapse = " ")
}
modules <- c("libxml-2.0", "libcurl", "openssl", "zlib", "expat", "poppler-cpp",
             "cairo", "fontconfig", "freetype2", "harfbuzz", "fribidi")
for (module in modules) {
    pc(c("--print-errors", "--exists", module))
    message("CondaR: Found managed ", module, " ", pc(c("--modversion", module)))
}

directory <- tempfile("condar-native-check-")
dir.create(directory)
oldwd <- setwd(directory)
# The short-lived worker also cleans up after an unsuccessful compilation.
main <- function() {
    on.exit({ setwd(oldwd); unlink(directory, recursive = TRUE) })
    writeLines(c(
        "#include <libxml/parser.h>", "#include <curl/curl.h>",
        "#include <openssl/crypto.h>", "#include <zlib.h>", "#include <expat.h>",
        "void condar_c_probe(int *ok) {",
        "  xmlDocPtr doc = xmlNewDoc(BAD_CAST \"1.0\");",
        "  *ok = doc != 0 && curl_version() != 0 && OpenSSL_version_num() != 0",
        "    && zlibVersion() != 0 && XML_ExpatVersion() != 0;",
        "  xmlFreeDoc(doc);", "}"
    ), "native.c")
    cpp_probe <- if (.Platform$OS.type == "windows") c(
        # conda-forge Poppler has the MSVC C++ ABI on Windows. R package
        # Makevars.win scripts select their own MinGW-compatible dependencies.
        "#include <string>",
        "extern \"C\" void condar_cpp_probe(int *ok) {",
        "  *ok = std::string(\"x\").length() == 1;", "}"
    ) else c(
        "#include <poppler-global.h>",
        "extern \"C\" void condar_cpp_probe(int *ok) {",
        "  *ok = poppler::ustring::from_utf8(\"x\").length() == 1;", "}"
    )
    writeLines(cpp_probe, "native_cpp.cpp")
    writeLines(c("      subroutine condar_fortran_probe(ok)", "      integer ok",
                 "      ok = 1", "      end"), "native_fortran.f")
    build_modules <- c("libxml-2.0", "libcurl", "openssl", "zlib", "expat",
                       if (.Platform$OS.type != "windows") "poppler-cpp")
    Sys.setenv(PKG_CPPFLAGS = pc(c("--cflags", build_modules)),
               PKG_LIBS = pc(c("--libs", build_modules)))
    message("CondaR: Compiling and loading C, C++ and Fortran probes")
    r <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "R.exe" else "R")
    output <- paste0("condar_native", .Platform$dynlib.ext)
    status <- system2(r, c("CMD", "SHLIB", "-o", output, "native.c", "native_cpp.cpp", "native_fortran.f"))
    if (status != 0L) stop("Managed R native compilation/linking failed (exit ", status, ")")
    dll <- dyn.load(file.path(directory, output))
    on.exit(dyn.unload(dll[["path"]]), add = TRUE, after = FALSE)
    stopifnot(.C("condar_c_probe", ok = 0L, PACKAGE = dll[["name"]])$ok == 1L,
              .C("condar_cpp_probe", ok = 0L, PACKAGE = dll[["name"]])$ok == 1L,
              .Fortran("condar_fortran_probe", ok = 0L, PACKAGE = dll[["name"]])$ok == 1L)
    message("CondaR: Native build environment verified")
}
main()
