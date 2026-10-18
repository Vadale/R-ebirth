# Run from the repository root. Base controls need no installed document tools;
# --quarto also tests the actual Windows build/check subprocesses before relm builds.
main <- function() {
  args <- commandArgs(TRUE)
  stopifnot(length(args) >= 1L)
  root <- normalizePath(args[[1]], mustWork = TRUE)
  out <- file.path(root, "vignette-library")
  stopifnot(!dir.exists(out), dir.create(out))
  docs <- file.path("rebirth", "vignettes")
  setup <- function(name) {
    lines <- readLines(file.path(docs, paste0(name, ".qmd")))
    start <- which(lines == "```{r}")[[1]]
    end <- which(seq_along(lines) > start & lines == "```")[[1]]
    lines[(start + 1L):(end - 1L)]
  }
  code <- setup("contrast-directions")
  stopifnot(identical(code, setup("model-interventions")))
  old_libs <- .libPaths()
  old_build <- Sys.getenv("R_BUILD_TEMPLIB", unset = NA_character_)
  on.exit({
    .libPaths(old_libs)
    if (is.na(old_build)) Sys.unsetenv("R_BUILD_TEMPLIB")
    else Sys.setenv(R_BUILD_TEMPLIB = old_build)
  }, add = TRUE)
  lib <- file.path(out, "temporary library with spaces")
  stopifnot(dir.create(lib))
  Sys.unsetenv("R_BUILD_TEMPLIB")
  eval(parse(text = code), envir = new.env())
  stopifnot(identical(.libPaths(), old_libs))
  Sys.setenv(R_BUILD_TEMPLIB = lib)
  eval(parse(text = code), envir = new.env())
  # .libPaths() normalizes with "/" even on Windows; normalizePath() alone
  # defaults to backslashes there. Compare the same canonical representation.
  expected_library <- normalizePath(lib, winslash = "/", mustWork = TRUE)
  writeLines(c(paste0("observed=", .libPaths()[[1]]),
               paste0("expected=", expected_library)),
             file.path(out, "library-paths.txt"))
  stopifnot(identical(.libPaths()[[1]], expected_library),
            identical(.libPaths()[-1L], old_libs))
  .libPaths(old_libs)
  Sys.setenv(R_BUILD_TEMPLIB = file.path(out, "absent"))
  eval(parse(text = code), envir = new.env())
  stopifnot(identical(.libPaths(), old_libs))
  Sys.unsetenv("R_BUILD_TEMPLIB")
  guarded <- c("anatomy-lab", "topics-without-python", "vision")
  for (name in guarded) {
    lines <- readLines(file.path(docs, paste0(name, ".qmd")))
    stopifnot(!any(grepl("^#\\| eval: !expr", lines)))
  }
  cat("VIGNETTE_LIBRARY_BASE_PASS cases=3 native_builds=0 models=0\n")
  if (!"--quarto" %in% args) return(invisible(NULL))

  # Tangling never executes examples. Keep errors/warnings visible and fatal.
  for (name in guarded) {
    dest <- file.path(out, paste0(name, ".R"))
    messages <- capture.output(withCallingHandlers(
      knitr::purl(file.path(docs, paste0(name, ".qmd")),
                  output = dest, quiet = TRUE),
      warning = function(w) stop(w)), type = "message")
    writeLines(messages, paste0(dest, ".log"))
    stopifnot(!any(grepl("Error|not found", messages)), length(parse(dest)) > 0L)
  }
  pkg <- file.path(out, "relmvignetteprobe")
  stopifnot(dir.create(pkg), dir.create(file.path(pkg, "vignettes")))
  writeLines(c("Package: relmvignetteprobe", "Version: 0.0.1",
    "Title: Temporary Library Vignette Probe",
    "Description: Checks temporary library visibility in document subprocesses.",
    "Authors@R: person('Test', 'Maintainer', email='test@example.org', role=c('aut','cre'))",
    "License: GPL-3", "Encoding: UTF-8", "Suggests: quarto",
    "VignetteBuilder: quarto"), file.path(pkg, "DESCRIPTION"))
  writeLines(character(), file.path(pkg, "NAMESPACE"))
  writeLines(c("---", "title: Temporary Library Probe", "format: html",
    "engine: knitr", "vignette: >",
    "  %\\VignetteIndexEntry{Temporary Library Probe}",
    "  %\\VignetteEngine{quarto::html}", "  %\\VignetteEncoding{UTF-8}", "---",
    "```{r}", code,
    "if (!nzchar(find.package('relmvignetteprobe', quiet = TRUE)))",
    "  stop('Missing probe; R_BUILD_TEMPLIB=', Sys.getenv('R_BUILD_TEMPLIB'),",
    "       '; R_LIBS=', Sys.getenv('R_LIBS'), '; libraries=', paste(.libPaths(), collapse=';'))",
    "library(relmvignetteprobe)",
    "stopifnot(packageVersion('relmvignetteprobe') == '0.0.1')",
    "run_real <- FALSE", "```", "```{r}",
    "if (run_real) stop('Optional model branch must not execute')",
    "if (isFALSE(run_real)) cat('TEMPORARY_LIBRARY_RENDER_OK')", "```"),
    file.path(pkg, "vignettes", "probe.qmd"))
  old_wd <- setwd(out)
  on.exit(setwd(old_wd), add = TRUE)
  r <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "R.exe" else "R")
  run <- function(name, args, env = character()) {
    log <- paste0(name, ".log")
    status <- system2(r, args, stdout = log, stderr = log, env = env)
    if (status != 0L) {
      cat(readLines(log), sep = "\n")
      stop(name, " failed; full native package build must not start")
    }
  }
  run("build", c("CMD", "build", "--no-manual", "relmvignetteprobe"))
  archive <- "relmvignetteprobe_0.0.1.tar.gz"
  # R normally avoids a separate extracted-script run when rebuilding vignettes.
  # This small probe deliberately checks both paths; leave relm checks unchanged.
  run("check", c("CMD", "check", "--no-manual", "--no-examples", "--no-tests", archive),
      env = "_R_CHECK_VIGNETTES_SKIP_RUN_MAYBE_=FALSE")
  check <- readLines("relmvignetteprobe.Rcheck/00check.log")
  stopifnot(any(grepl("re-building of vignette outputs.*OK", check)),
            any(grepl("running R code from vignettes.*OK", check)),
            !any(grepl("ERROR|WARNING", check)))
  cat("VIGNETTE_LIBRARY_QUARTO_PASS build=1 check=1 tangled=3 native_builds=0 models=0\n")
}
main()
