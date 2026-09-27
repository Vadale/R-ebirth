# Run from the repository root: Rscript tests/toolchain/test-msrv.R
# R-CMD-check.yaml runs this on every platform/R/toolchain leg, before building.
# No native compilation or toolchain installation is needed for these guards.

workspace <- readLines("rebirth/src/rust/Cargo.toml")
floor_line <- grep('^rust-version = "[0-9.]+"$', workspace, value = TRUE)
stopifnot(length(floor_line) == 1L)
floor <- sub('^rust-version = "([0-9.]+)"$', "\\1", floor_line)

desc <- read.dcf("rebirth/DESCRIPTION")
required <- unname(sub(".*rustc >= ([0-9.]+).*", "\\1", desc[, "SystemRequirements"]))
stopifnot(identical(required, floor))
for (crate in c("rebirth-llm", "rebirth-ffi")) {
  manifest <- readLines(file.path("rebirth/src/rust", crate, "Cargo.toml"))
  stopifnot(identical(grep("^rust-version", manifest, value = TRUE),
                      "rust-version.workspace = true"))
}

# A newer default toolchain must never mask an untested floor. Pin the CI leg
# to the same version as the package metadata and the configure check.
workflow <- readLines(".github/workflows/R-CMD-check.yaml")
ci_floor_line <- grep("rust: '[0-9.]+'", workflow, value = TRUE)
stopifnot(length(ci_floor_line) == 1L)
ci_floor <- sub(".*rust: '([0-9.]+)'.*", "\\1", ci_floor_line)
stopifnot(identical(ci_floor, floor),
          any(grepl("RUSTUP_TOOLCHAIN: ${{ matrix.config.rust }}", workflow, fixed = TRUE)))

# Execute the real configure script in an isolated environment, stubbing only
# its external commands and PATH mutation. This catches a disabled/ineffective
# version check, not just a disagreement between duplicated version strings.
check_configure <- function(version) {
  env <- new.env(parent = globalenv())
  env$read.dcf <- function(...) desc
  env$Sys.setenv <- function(...) invisible(NULL)
  env$system <- function(command, intern) {
    stopifnot(intern, command %in% c("rustc --version", "cargo --version"))
    paste(sub(" --version", "", command, fixed = TRUE), version, "(test fixture)")
  }
  tryCatch({
    suppressMessages(sys.source("rebirth/tools/msrv.R", envir = env))
    NULL
  }, error = identity)
}

version_parts <- as.integer(strsplit(floor, ".", fixed = TRUE)[[1L]])
stopifnot(length(version_parts) == 3L, version_parts[[2L]] > 0L)
below <- paste(version_parts[[1L]], version_parts[[2L]] - 1L, 0L, sep = ".")
above <- paste(version_parts[[1L]], version_parts[[2L]] + 1L, 0L, sep = ".")
rejected <- check_configure(below)
stopifnot(inherits(rejected, "error"),
          grepl(paste("Minimum supported Rust version is", floor),
                conditionMessage(rejected), fixed = TRUE),
          grepl(paste("Installed Rust version is", below),
                conditionMessage(rejected), fixed = TRUE),
          is.null(check_configure(floor)),
          is.null(check_configure(above)))
cat(sprintf("Rust MSRV %s: declarations agree; configure rejects %s and accepts %s/%s.\n",
            floor, below, floor, above))
