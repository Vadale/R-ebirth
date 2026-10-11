library(relm)
library(testthat)
parent <- "/private/tmp/relm-maintenance-040/builds-20261011-180737"
prior <- as.data.frame(readRDS(file.path(parent, "selftest/test-results.rds")))
failed <- prior[prior$failed > 0 | prior$error, c("file", "test")]
stopifnot(nrow(failed) == 61L, !anyDuplicated(failed))
results <- list()
for (i in seq_len(nrow(failed))) {
  cat("RESUME_CASE", i, failed$file[[i]], failed$test[[i]], "\n")
  results[[i]] <- testthat::test_file(
    file.path("/Users/alessandrovadala/DOCUDESK/R-ebirth/rebirth/tests/testthat", failed$file[[i]]),
    desc = failed$test[[i]], package = "relm", load_package = "installed",
    reporter = "summary", stop_on_failure = FALSE)
}
saveRDS(results, "/private/tmp/relm-maintenance-040/platform-results.rds")
counts <- do.call(rbind, lapply(results, as.data.frame))
stopifnot(nrow(counts) == nrow(failed), identical(as.character(counts$test), as.character(failed$test)),
  !any(counts$failed > 0), !any(counts$error), !any(counts$skipped))
cat("MAINTENANCE_PLATFORM_RESUME_OK cases=", nrow(counts), " expectations=",sum(counts$passed),"\n",sep="")
