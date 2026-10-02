root <- '/private/tmp/relm-wp9'
.libPaths(c(file.path(root, 'library'), .libPaths()))
Sys.unsetenv(grep('^RELM_TEST_MODEL_|^RELM_TEST_MMPROJ_', names(Sys.getenv()), value = TRUE))
library(relm)
result <- testthat::test_dir('rebirth/tests/testthat', package = 'relm', load_package = 'installed', filter = '^llm-async(-lifecycle)?$', reporter = 'summary', stop_on_failure = TRUE)
counts <- as.data.frame(result)
counts <- counts[, !vapply(counts, is.list, logical(1)), drop = FALSE]
write.csv(counts, file.path(root, 'ci-diagnostic-counts.csv'), row.names = FALSE)
