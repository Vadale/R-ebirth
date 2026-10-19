# Base-R preflight in ordinary Unix/Windows package CI. A tiny C fixture tests
# DLL loading, feature-specific metadata, Make ordering and error propagation.
# No relm engine, Rust compiler, package dependencies or models are used.
repo <- normalizePath(".", winslash = "/", mustWork = TRUE)
root <- tempfile("wrapper controls ")
dir.create(root)
args <- commandArgs(TRUE)
if (length(args)) root <- normalizePath(args[[1L]], winslash = "/", mustWork = TRUE)
run <- function(command, args, log, cwd = root) {
  old <- setwd(cwd)
  on.exit(setwd(old))
  status <- system2(command, args, stdout = log, stderr = log)
  if (status != 0L) cat(readLines(log), sep = "\n")
  status
}
r <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "R.exe" else "R")
rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
generator <- file.path(repo, "rebirth/tools/generate-wrappers.R")
for (mode in c("production", "selftest")) {
  work <- file.path(root, mode); dir.create(work)
  package <- file.path(work, "relm"); dir.create(package)
  for (d in c("src", "R", "tools")) dir.create(file.path(package, d))
  writeLines(c("Package: relm", "Version: 0.0.0", "Title: Wrapper Control",
    "Description: Tests wrapper generation without an engine.",
    "License: MIT", "Author: Test", "Maintainer: Test <test@example.org>"),
    file.path(package, "DESCRIPTION"))
  writeLines("useDynLib(relm, .registration = TRUE)", file.path(package, "NAMESPACE"))
  file.copy(generator, file.path(package, "tools"))
  fixture <- c(
    "#include <R.h>", "#include <Rinternals.h>", "#include <R_ext/Rdynload.h>",
    "#include <stdlib.h>",
    "static SEXP probe(SEXP x) { return x; }",
    "static SEXP wrappers(SEXP symbols, SEXP module) {",
    "  if (!Rf_asLogical(symbols)) Rf_error(\"symbols required\");",
    "  if (getenv(\"RELM_INVALID_WRAPPER_FIXTURE\")) return Rf_mkString(\"invalid <- function(\");",
    paste0('  return Rf_mkString("rebirth_probe <- function(x) .Call(wrap__rebirth_probe, x)\\n',
      if (mode == "selftest") 'rebirth_selftest_probe <- function(x) .Call(wrap__rebirth_selftest_probe, x)\\n' else '', '");'),
    "}", "static const R_CallMethodDef entries[] = {",
    '  {"wrap__make_relm_wrappers", (DL_FUNC) &wrappers, 2},',
    '  {"wrap__rebirth_probe", (DL_FUNC) &probe, 1},',
    if (mode == "selftest") '  {"wrap__rebirth_selftest_probe", (DL_FUNC) &probe, 1},',
    "  {NULL, NULL, 0}", "};",
    "void R_init_relm(DllInfo *dll) { R_registerRoutines(dll, NULL, entries, NULL, NULL); R_useDynamicSymbols(dll, FALSE); }")
  writeLines(fixture, file.path(package, "src/fixture.c"))
  # Copy the actual post-link target, substituting only the discovered Rscript
  # and removing cleanup paths which do not exist in this miniature package.
  template <- readLines(file.path(repo, "rebirth/src/Makevars.in"))
  index <- match("rust_clean: $(SHLIB)", template)
  stopifnot(!is.na(index), grepl("@RSCRIPT@", template[[index + 1L]], fixed = TRUE))
  recipe <- gsub("@RSCRIPT@", gsub("$", "$$", shQuote(rscript, type = "sh"), fixed = TRUE),
                 template[[index + 1L]], fixed = TRUE)
  writeLines(c("all: $(SHLIB) rust_clean", "rust_clean: $(SHLIB)", recipe),
             file.path(package, "src/Makevars"))
  library <- file.path(work, "library"); dir.create(library)
  stopifnot(run(r, c("CMD", "INSTALL", paste0("--library=", shQuote(library)), shQuote(package)),
                file.path(work, "install.log")) == 0L)
  check <- file.path(work, "check.R")
  writeLines(c(sprintf("library(relm, lib.loc = %s)", deparse(library)),
    "stopifnot(identical(relm:::rebirth_probe(17L), 17L))",
    sprintf("stopifnot(exists('rebirth_selftest_probe', asNamespace('relm'), inherits=FALSE) == %s)",
      if (mode == "selftest") "TRUE" else "FALSE")), check)
  stopifnot(run(rscript, c("--vanilla", shQuote(check)), file.path(work, "check.log")) == 0L)
  if (mode == "production") {
    output <- file.path(work, "unchanged.R"); writeLines("sentinel", output)
    before <- readBin(output, "raw", 100L)
    dll <- file.path(library, "relm/libs", paste0("relm", .Platform$dynlib.ext))
    if (!file.exists(dll)) dll <- file.path(library, "relm/libs", .Platform$r_arch, paste0("relm", .Platform$dynlib.ext))
    Sys.setenv(RELM_INVALID_WRAPPER_FIXTURE = "1")
    status <- run(rscript, c("--vanilla", shQuote(generator), shQuote(dll), shQuote(output)),
                  file.path(work, "invalid-metadata.log"))
    Sys.unsetenv("RELM_INVALID_WRAPPER_FIXTURE")
    stopifnot(status != 0L, identical(before, readBin(output, "raw", 100L)))
    status <- run(rscript, c("--vanilla", shQuote(generator), shQuote(paste0(dll, ".missing")), shQuote(output)),
                  file.path(work, "missing-dll.log"))
    stopifnot(status != 0L, identical(before, readBin(output, "raw", 100L)))
  }
}
cat("CRAN_WRAPPER_GENERATOR_OK modes=2 installs=2 refusals=2 engine_builds=0 models=0\n")
