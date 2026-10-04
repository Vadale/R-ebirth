root <- "/private/tmp/relm-f6b"
.libPaths(c(file.path(root, "library"), .libPaths()))
library(relm)
stopifnot(normalizePath(find.package("relm")) == file.path(root, "library", "relm"))
path <- "/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf"
stopifnot(file.exists(path))
Sys.setenv(RELM_TEST_MODEL_QWEN = path)
result <- testthat::test_dir("rebirth/tests/testthat", package = "relm",
  load_package = "installed", filter = "^llm-live-(helpers|memory|steering)$", reporter = "summary", stop_on_failure = FALSE)
out <- Sys.getenv("RELM_F6B_EVIDENCE")
saveRDS(result, file.path(out, "live-tests.rds"))
counts <- as.data.frame(result)
counts <- counts[, !vapply(counts, is.list, logical(1)), drop = FALSE]
write.csv(counts, file.path(out, "live-test-counts.csv"), row.names = FALSE)
required <- grepl("^\\[MODEL\\]", counts$test)
stopifnot(nrow(counts) == 19L, sum(required) == 3L, !any(counts$skipped),
  !any(counts$failed > 0), !any(counts$error))
cat("F6B_LIVE_R_GATES_PASSED cases=", nrow(counts), " model_cases=", sum(required),
  " expectations=", sum(counts$passed), "\n", sep = "")
