# Deferred webR preflight: execute the actual generator in target R against
# tiny Wasm DLLs. No engine, Rust build, package model or inference is involved.
args <- commandArgs(TRUE)
stopifnot(length(args) == 1L, nzchar(Sys.which("emcc")),
          nzchar(Sys.getenv("RELM_WEBR_RUNTIME")))
dir.create(args[[1L]], recursive = TRUE, showWarnings = FALSE)
root <- normalizePath(args[[1L]], mustWork = TRUE)
generator <- normalizePath("rebirth/tools/generate-wrappers.R", mustWork = TRUE)
rscript <- file.path(R.home("bin"), "Rscript")
run <- function(command, args, log) {
  system2(command, shQuote(args), stdout = log, stderr = log)
}
for (mode in c("valid", "invalid-text", "wrong-arity")) {
  work <- file.path(root, paste("fixture", mode)); dir.create(work)
  dll <- file.path(work, "relm.so")
  output <- file.path(work, "wrappers.R")
  # Only the four public R ABI declarations used by this metadata fixture.
  # In particular both registration functions return int, not void.
  fixture <- c(
    "typedef void *SEXP; typedef struct DllInfo DllInfo; typedef void (*DL_FUNC)(void);",
    "typedef struct { const char *name; DL_FUNC fun; int numArgs; } R_CallMethodDef;",
    "extern SEXP Rf_mkString(const char *);",
    "extern int R_registerRoutines(DllInfo *, const void *, const R_CallMethodDef *, const void *, const void *);",
    "extern int R_useDynamicSymbols(DllInfo *, int);",
    "_Static_assert(sizeof(void *) == 4, \"Wasm32 fixture\");",
    "static SEXP wrappers(SEXP symbols, SEXP module) { (void)symbols; (void)module;",
    if (mode == "invalid-text") 'return Rf_mkString("invalid <- function("); }' else
      'return Rf_mkString("rebirth_probe <- function(x) .Call(wrap__rebirth_probe, x)\\n"); }',
    "static SEXP probe(SEXP x) { return x; }",
    "static const R_CallMethodDef entries[] = {",
    sprintf('{"wrap__make_relm_wrappers", (DL_FUNC)&wrappers, %d},',
            if (mode == "wrong-arity") 1L else 2L),
    '{"wrap__rebirth_probe", (DL_FUNC)&probe, 1}, {0, 0, 0}};',
    "void R_init_relm(DllInfo *dll) { R_registerRoutines(dll, 0, entries, 0, 0); R_useDynamicSymbols(dll, 0); }")
  source <- file.path(work, "fixture.c"); writeLines(fixture, source)
  stopifnot(run("emcc", c("-shared", "-fPIC", "-sSIDE_MODULE=1", source, "-o", dll),
                file.path(work, "compile.log")) == 0L)
  writeLines("sentinel", output); before <- readBin(output, "raw", 100L)
  status <- run(rscript, c("--vanilla", generator, dll, output),
                file.path(work, "generator.log"))
  if (mode == "valid") {
    stopifnot(status == 0L)
    text <- readLines(output)
    stopifnot(sum(text == "rebirth_probe <- function(x) .Call(wrap__rebirth_probe, x)") == 1L,
              any(grepl("RELM_WASM_R_HOSTED_WRAPPERS_OK", readLines(file.path(work, "generator.log")), fixed = TRUE)))
    invisible(parse(output))
  } else {
    stopifnot(status != 0L, identical(before, readBin(output, "raw", 100L)))
    error <- readLines(file.path(work, "generator.log"))
    expected <- if (mode == "wrong-arity") "symbol$numParameters" else "unexpected end of input"
    stopifnot(any(grepl(expected, error, fixed = TRUE)))
  }
}
# Missing inputs and runtime fail closed without replacing a prior wrapper file.
work <- file.path(root, "refusals"); dir.create(work)
output <- file.path(work, "wrappers.R"); writeLines("sentinel", output)
before <- readBin(output, "raw", 100L)
dll <- file.path(root, "fixture valid", "relm.so")
status <- run(rscript, c("--vanilla", generator, paste0(dll, ".missing"), output),
              file.path(work, "missing-dll.log"))
stopifnot(status != 0L, identical(before, readBin(output, "raw", 100L)))
runtime <- Sys.getenv("RELM_WEBR_RUNTIME"); Sys.unsetenv("RELM_WEBR_RUNTIME")
status <- run(rscript, c("--vanilla", generator, dll, output), file.path(work, "missing-runtime.log"))
Sys.setenv(RELM_WEBR_RUNTIME = runtime)
stopifnot(status != 0L, identical(before, readBin(output, "raw", 100L)),
          any(grepl("requires RELM_WEBR_RUNTIME", readLines(file.path(work, "missing-runtime.log")), fixed = TRUE)))
cat("WASM_WRAPPER_GENERATOR_OK valid=1 refusals=4 engine_builds=0 models=0\n")
