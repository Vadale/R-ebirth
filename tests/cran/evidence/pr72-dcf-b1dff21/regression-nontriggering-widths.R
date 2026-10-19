# Run from the repository root: Rscript tests/toolchain/test-msrv.R
# R-CMD-check.yaml runs this on every platform/R/toolchain leg, before building.
# No native compilation or toolchain installation is needed for these guards.

workspace <- readLines("rebirth/src/rust/Cargo.toml")
floor_line <- grep('^rust-version = "[0-9.]+"$', workspace, value = TRUE)
stopifnot(length(floor_line) == 1L)
floor <- sub('^rust-version = "([0-9.]+)"$', "\\1", floor_line)

desc <- read.dcf("rebirth/DESCRIPTION")
required <- unname(sub(".*rustc >= ([0-9.]+).*", "\\1", desc[, "SystemRequirements"]))
cargo_required <- unname(sub(".*Cargo \\(Rust's package manager\\) >= ([0-9.]+).*",
                             "\\1", desc[, "SystemRequirements"]))
stopifnot(identical(required, floor), identical(cargo_required, floor))
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
check_configure <- function(rust = floor, cargo = floor, raw = list(), metadata = desc) {
  env <- new.env(parent = globalenv())
  env$read.dcf <- function(...) metadata
  env$Sys.setenv <- function(...) invisible(NULL)
  env$system <- function(command, intern) {
    stopifnot(intern, command %in% c("rustc --version", "cargo --version"))
    tool <- sub(" --version", "", command, fixed = TRUE)
    if (tool %in% names(raw)) {
      value <- raw[[tool]]
      if (inherits(value, "error")) stop(value)
      return(value)
    }
    paste(tool, if (tool == "rustc") rust else cargo, "(test fixture)")
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
cases <- 0L
expect_error <- function(value, text) {
  stopifnot(inherits(value, "error"), grepl(text, conditionMessage(value), fixed = TRUE))
  cases <<- cases + 1L
}
# Test independently: a new compiler cannot excuse an old Cargo (or vice versa).
expect_error(check_configure(below, above), paste("Installed Rust version is", below))
expect_error(check_configure(above, below), paste("Installed Cargo version is", below))
for (pair in list(c(floor, floor), c(above, floor), c(floor, above), c(above, above))) {
  stopifnot(is.null(check_configure(pair[[1]], pair[[2]])))
  cases <- cases + 1L
}
for (tool in c("rustc", "cargo")) {
  for (bad in list(character(), NA_character_, "unparseable", c("first", "second"),
                  paste("wrong-tool", floor), paste(tool, "1.85"),
                  structure(paste(tool, floor), status = 127L))) {
    expect_error(check_configure(raw = setNames(list(bad), tool)),
                 paste("Cannot determine", tool, "version"))
  }
  expect_error(check_configure(raw = setNames(list(simpleError("missing tool")), tool)),
               paste(tool, "could not run"))
}
missing_floor <- desc
missing_floor[, "SystemRequirements"] <- sub("Cargo (Rust's package manager) >= 1.85.0",
  "Cargo (Rust's package manager)", desc[, "SystemRequirements"], fixed = TRUE)
expect_error(check_configure(metadata = missing_floor), "Declare an explicit Cargo minimum")

# R CMD build serializes DESCRIPTION with folded DCF fields. Exercise the real
# serializer/reader, including Windows line endings, before any native build.
# Version refusals must remain effective after accepting the valid formatting.
description_path <- tempfile("msrv-description-")
serialized_cases <- 0L
tryCatch({
  for (width in c(48L, 80L)) {
    write.dcf(desc, file = description_path, width = width)
    lines <- readLines(description_path)
    for (eol in c("\n", "\r\n")) {
      writeLines(lines, description_path, sep = eol, useBytes = TRUE)
      packaged <- read.dcf(description_path)
      stopifnot(grepl("\n", packaged[1L, "SystemRequirements"], fixed = TRUE))
      result <- check_configure(metadata = packaged)
      if (inherits(result, "error"))
        stop("Serialized DESCRIPTION rejected: ", conditionMessage(result))
      cases <- cases + 1L
      expect_error(check_configure(below, above, metadata = packaged),
                   paste("Installed Rust version is", below))
      expect_error(check_configure(above, below, metadata = packaged),
                   paste("Installed Cargo version is", below))
      serialized_cases <- serialized_cases + 3L
    }
  }
}, finally = unlink(description_path))
cat(sprintf(paste0("RUST_CARGO_FLOOR_OK floor=%s configure_cases=%d ",
                   "serialized_metadata_cases=%d models=0 builds=0\n"),
            floor, cases, serialized_cases))
