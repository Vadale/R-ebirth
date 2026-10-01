# Model-free package regression pass against the freshly installed native build.
root <- '/private/tmp/relm-wp9'
.libPaths(c(file.path(root, 'library'), .libPaths()))
model_keys <- grep('^RELM_TEST_MODEL_|^RELM_TEST_MMPROJ_', names(Sys.getenv()), value = TRUE)
Sys.unsetenv(model_keys)
library(relm)
stopifnot(normalizePath(find.package('relm')) == file.path(root, 'library', 'relm'))
result <- testthat::test_dir('rebirth/tests/testthat', package = 'relm',
  load_package = 'installed', filter = '^llm-async', invert = TRUE,
  reporter = 'summary', stop_on_failure = TRUE)
saveRDS(result, file.path(root, 'integration-tests.rds'))
counts <- as.data.frame(result)
counts <- counts[, !vapply(counts, is.list, logical(1)), drop = FALSE]
utils::write.csv(counts, file.path(root, 'integration-test-counts.csv'), row.names = FALSE)
