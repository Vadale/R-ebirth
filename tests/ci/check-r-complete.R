# Fail closed when check-r-package reports success after R CMD check aborts.
# Used after the ordinary R matrix and both production check-r-package routes.
verify_r_check_complete <- function(path) {
  if (!file.exists(path)) stop("R CMD check completion log is missing: ", path)
  lines <- trimws(readLines(path, warn = FALSE))
  lines <- lines[nzchar(lines)]
  # R's check log ends with these two records. Install's '* DONE (relm)' is
  # not completion, and a partial log must never inherit the action's green.
  if (length(lines) < 2L || sum(lines == "* DONE") != 1L ||
      !identical(tail(lines, 2L)[[1L]], "* DONE")) {
    stop("R CMD check did not reach its completion footer: ", path)
  }
  # Existing CI rejects errors/warnings but permits notes (e.g. new submission).
  if (!grepl("^Status: (OK|[1-9][0-9]* NOTEs?)$", tail(lines, 1L))) {
    stop("R CMD check has an unsuccessful or unrecognized final status: ",
         tail(lines, 1L))
  }
  invisible(TRUE)
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 1L) stop("Usage: Rscript tests/ci/check-r-complete.R <00check.log>")
  verify_r_check_complete(args[[1L]])
  cat("R_CHECK_COMPLETE_OK: completed check, no errors or warnings; notes allowed\n")
}
