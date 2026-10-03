# Two installed-package phases. Model-free ownership fails before model download;
# actual vision keeps its named non-skipping gates without the whole async suite.
vision_suite_spec <- function(phase) {
  switch(phase,
    preflight = list(filter = '^llm-async-lifecycle$', required = c(
      'close and forced GC during a native job are safe in a fresh process',
      'real synthetic models defer close and GC while a fixture owns native execution',
      'lifecycle diagnostics do not deliver callbacks after the drain deadline')),
    vision = list(filter = '^llm-vision', required = c(
      '[MODEL] the CPU greedy continuation matches the unpatched upstream reference',
      "[MODEL] the cat image embeds closer to 'a cat' than to 'a car'",
      '[MODEL] async vision matches the existing image generation path',
      '[MODEL] a multimodal prompt with a text portion over n_batch decodes (rule 8a)')),
    stop('Unknown vision test phase: ', phase))
}

validate_vision_results <- function(df, phase) {
  spec <- vision_suite_spec(phase)
  needed <- c('test', 'failed', 'error', 'passed', 'skipped')
  if (!is.data.frame(df) || nrow(df) == 0L || !all(needed %in% names(df)) ||
      anyNA(df[, needed, drop = FALSE])) stop('Missing or incomplete test results')
  if (any(df$failed != 0L) || any(df$error)) stop('The test suite failed')
  for (name in spec$required) {
    hit <- df[df$test == name, , drop = FALSE]
    if (nrow(hit) != 1L || isTRUE(hit$skipped) || hit$passed <= 0L) {
      stop('Required gate did not run exactly once without skipping: ', name)
    }
  }
  invisible(TRUE)
}

run_vision_phase <- function(phase, candidate_library, evidence, root = '.') {
  spec <- vision_suite_spec(phase)
  root <- normalizePath(root, mustWork = TRUE)
  candidate_library <- normalizePath(candidate_library, mustWork = TRUE)
  evidence <- normalizePath(evidence, mustWork = FALSE)
  dir.create(evidence, recursive = TRUE, showWarnings = FALSE)
  .libPaths(c(candidate_library, .libPaths()))
  library(relm)
  stopifnot(identical(normalizePath(find.package('relm')),
    normalizePath(file.path(candidate_library, 'relm'), mustWork = TRUE)))
  if (phase == 'preflight') {
    # A preflight cannot inherit a real-model workload from the caller.
    keys <- c('RELM_TEST_MODEL_QWEN', 'RELM_TEST_MODEL_VLM', 'RELM_TEST_MMPROJ_VLM')
    old <- Sys.getenv(keys, unset = NA_character_)
    on.exit({
      Sys.unsetenv(keys[is.na(old)])
      if (any(!is.na(old))) do.call(Sys.setenv, as.list(old[!is.na(old)]))
    }, add = TRUE)
    Sys.unsetenv(keys)
  } else {
    model <- Sys.getenv('RELM_TEST_MODEL_VLM')
    projector <- Sys.getenv('RELM_TEST_MMPROJ_VLM')
    if (!nzchar(model) || !file.exists(model) || !nzchar(projector) ||
        !file.exists(projector)) stop('The pinned VLM and projector are required')
    m <- llm(model, projector = projector)
    on.exit(close(m), add = TRUE)
    stopifnot(identical(m$architecture, 'qwen2vl'), m$hidden_size == 1536L,
      isTRUE(m$vision))
    close(m)
  }
  result <- testthat::test_dir(file.path(root, 'rebirth/tests/testthat'),
    filter = spec$filter, reporter = 'summary', stop_on_failure = FALSE,
    package = 'relm', load_package = 'installed')
  df <- as.data.frame(result)
  # Save per-test elapsed/CPU, counts, skips and failures before enforcing gates.
  # A nonzero script exit remains a failure even though diagnostics exist.
  columns <- !vapply(df, is.list, logical(1))
  write.csv(df[, columns, drop = FALSE], file.path(evidence, 'test-results.csv'),
    row.names = FALSE)
  saveRDS(result, file.path(evidence, 'results.rds'))
  writeLines(capture.output(sessionInfo()), file.path(evidence, 'session.txt'))
  writeLines(c(paste('phase', phase), paste('source', Sys.getenv('GITHUB_SHA')),
    paste('library', candidate_library)), file.path(evidence, 'scope.txt'))
  validate_vision_results(df, phase)
  cat(sprintf('VISION_PHASE_PASSED phase=%s passed=%d skipped=%d failed=%d\n',
    phase, sum(df$passed), sum(df$skipped), sum(df$failed)))
  invisible(df)
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 3L) stop('Usage: run-vision.R preflight|vision LIBRARY EVIDENCE')
  run_vision_phase(args[[1L]], args[[2L]], args[[3L]])
}
