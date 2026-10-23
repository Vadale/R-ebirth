# Native R matrix and pinned rwasm: isolated actual dependency, no engine/models.
args <- commandArgs(TRUE)
stopifnot(length(args) == 1L || (length(args) == 2L && args[[2L]] == "wasm"))
wasm <- length(args) == 2L && identical(args[[2L]], "wasm")
repo <- normalizePath(".", mustWork = TRUE)
fixture <- file.path(repo, "tests/cran/extendr-lookup")
dir.create(args[[1L]], recursive = TRUE, showWarnings = FALSE)
root <- normalizePath(args[[1L]], mustWork = TRUE)
work <- file.path(root, "fixture"); dir.create(file.path(work, "src"), recursive = TRUE)
stopifnot(file.copy(file.path(fixture, c("Cargo.toml", "Cargo.lock")), work),
          file.copy(file.path(fixture, "src/lib.rs"), file.path(work, "src/lib.rs")))
# Exact offline product sources, independent of the developer paths override.
stopifnot(utils::untar(file.path(repo, "rebirth/src/rust/vendor.tar.xz"), exdir = root) == 0L)
old <- setwd(work)
run <- function(command, arguments, name) {
  status <- system2(command, shQuote(arguments), stdout = file.path(root, name), stderr = file.path(root, name))
  if (status != 0L) {
    cat(readLines(file.path(root, name), warn = FALSE), sep = "\n")
    stop(name, " failed; retained complete log", call. = FALSE)
  }
}
config <- c("--config", 'source.crates-io.replace-with="vendored-sources"',
            "--config", paste0('source.vendored-sources.directory="', gsub("\\", "/", file.path(root, "vendor"), fixed = TRUE), '"'))
target <- file.path(root, "target")
Sys.setenv(CARGO_BUILD_JOBS = "2", CARGO_TARGET_DIR = target)
flags <- c("build", "--offline", "--locked", "--release", config)
if (wasm) {
  stopifnot(nzchar(Sys.getenv("WEBR_ROOT")), nzchar(Sys.getenv("RELM_WEBR_RUNTIME")))
  homes <- Sys.glob(file.path(Sys.getenv("WEBR_ROOT"), "wasm", "R-*", "lib", "R"))
  headers <- Sys.glob(file.path(Sys.getenv("WEBR_ROOT"), "R", "build", "R-*", "build", "include", "Rversion.h"))
  stopifnot(length(homes) == 1L, length(headers) == 1L)
  Sys.setenv(R_HOME = homes, R_INCLUDE_DIR = dirname(headers),
             CARGO_PROFILE_RELEASE_PANIC = "abort")
  manifest <- readLines("Cargo.toml")
  writeLines(sub('crate-type = ["cdylib"]', 'crate-type = ["staticlib"]', manifest, fixed = TRUE), "Cargo.toml")
  flags <- c(flags, "--target=wasm32-unknown-emscripten")
}
run("cargo", flags, "cargo-build.log")
if (wasm) {
  writeLines(c("typedef struct DllInfo DllInfo;", "void R_init_lookup_extendr(DllInfo *);",
               "void R_init_lookup(DllInfo *dll) { R_init_lookup_extendr(dll); }"), "entrypoint.c")
  dll <- file.path(root, "lookup.so")
  run("emcc", c("-shared", "-fPIC", "-sSIDE_MODULE=1", "-sWASM_BIGINT", "-fwasm-exceptions",
                "-sSUPPORT_LONGJMP=wasm", "entrypoint.c",
                file.path(target, "wasm32-unknown-emscripten/release/liblookup.a"), "-lc++", "-o", dll), "link.log")
  run("node", c(file.path(fixture, "run-webr.mjs"), dll), "runtime.log")
} else {
  extension <- if (identical(Sys.info()[["sysname"]], "Darwin")) ".dylib" else .Platform$dynlib.ext
  dll <- file.path(target, "release", paste0(if (.Platform$OS.type == "windows") "" else "lib", "lookup", extension))
  run(file.path(R.home("bin"), "Rscript"), c("--vanilla", file.path(fixture, "check.R"), dll), "runtime.log")
}
setwd(old)
cat(readLines(file.path(root, "runtime.log")), sep = "\n")
cat("\nEXTENDR_LOOKUP_BUILD_OK offline=true models=0 target=", if (wasm) "wasm" else R.version$platform, "\n", sep = "")
