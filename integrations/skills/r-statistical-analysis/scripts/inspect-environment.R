#!/usr/bin/env Rscript
# Inspect only the requested packages without installing or loading them.
args <- unique(commandArgs(trailingOnly = TRUE))
if (any(!grepl("^[A-Za-z][A-Za-z0-9.]*$", args))) {
  stop("Provide R package names, not expressions or paths.", call. = FALSE)
}
cat("R_version\t", as.character(getRversion()), "\n", sep = "")
cat("platform\t", R.version$platform, "\n", sep = "")
cat("package\tversion\tlibrary\tstatus\n")
if (length(args)) {
  installed <- utils::installed.packages(noCache = TRUE)
  for (pkg in args) {
    index <- match(pkg, installed[, "Package"])
    if (is.na(index)) {
      cat(pkg, "NA", "NA", "missing", sep = "\t"); cat("\n")
    } else {
      cat(pkg, installed[index, "Version"], installed[index, "LibPath"],
          "available", sep = "\t"); cat("\n")
    }
  }
}
