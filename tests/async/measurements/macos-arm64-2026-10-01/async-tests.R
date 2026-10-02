# Fresh installed native package; cached models only, no downloads.
root <- "/private/tmp/relm-wp9"
repo <- "/Users/alessandrovadala/DOCUDESK/R-ebirth"
.libPaths(c(file.path(root, "library"), .libPaths()))
library(relm)
stopifnot(normalizePath(find.package("relm")) == file.path(root, "library", "relm"),
  "llm_cancel" %in% getNamespaceExports("relm"))
cache <- "/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm"
models <- c(RELM_TEST_MODEL_QWEN = "qwen2.5-0.5b-instruct-q8_0.gguf",
  RELM_TEST_MODEL_VLM = "Qwen2-VL-2B-Instruct-Q4_K_M.gguf",
  RELM_TEST_MMPROJ_VLM = "mmproj-Qwen2-VL-2B-Instruct-f16.gguf")
paths <- file.path(cache, models)
stopifnot(all(file.exists(paths)))
do.call(Sys.setenv, as.list(setNames(paths, names(models))))
writeLines(capture.output(sessionInfo()), file.path(root, "r-session.txt"))
result <- testthat::test_dir(file.path(repo, "rebirth/tests/testthat"),
  filter = "^llm-async", package = "relm", load_package = "installed",
  stop_on_failure = TRUE, reporter = "summary")
saveRDS(result, file.path(root, "async-tests.rds"))
counts <- as.data.frame(result)
counts <- counts[, !vapply(counts, is.list, logical(1)), drop = FALSE]
utils::write.csv(counts, file.path(root, "async-test-counts.csv"), row.names = FALSE)
