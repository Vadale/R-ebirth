args <- commandArgs(TRUE)
library(relm)
stopifnot(identical(normalizePath(find.package("relm")), normalizePath(args[[1]])))
ns <- asNamespace("relm")
source_env <- new.env(parent = ns)
for (p in sort(list.files(file.path(args[[2]], "R"), full.names = TRUE))) sys.source(p, source_env)
functions <- Filter(function(n) is.function(source_env[[n]]), ls(source_env, all.names = TRUE))
for (n in functions) {
  stopifnot(exists(n, ns, inherits = FALSE),
    identical(body(source_env[[n]]), body(ns[[n]])),
    identical(formals(source_env[[n]]), formals(ns[[n]])))
}
codetools::checkUsagePackage("relm")
cat("INSTALLED_FUNCTIONS", length(functions), "\n")
result <- testthat::test_dir(file.path(args[[3]], "rebirth/tests/testthat"),
  filter = if (Sys.getenv("RELM_ENABLE_SELFTESTS") == "1") NULL else "^(selftest-registration|package)$",
  package = "relm", load_package = "installed", reporter = "summary", stop_on_failure = FALSE)
saveRDS(result, file.path(args[[4]], "test-results.rds"))
counts <- as.data.frame(result)
write.csv(counts[c("file", "test", "nb", "failed", "skipped", "error", "warning", "passed")],
  file.path(args[[4]], "test-counts.csv"), row.names = FALSE)
stopifnot(!any(counts$failed > 0), !any(counts$error))
cat("MAINTENANCE_R_OK cases=", nrow(counts), " expectations=", sum(counts$passed),
    " skips=", sum(counts$skipped), "\n", sep = "")
