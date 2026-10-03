# Base-R controls for selection and false-green rejection; no package/model load.
source('tests/ci/run-vision.R')
checks <- 0L
reject <- function(expr) {
  result <- tryCatch({ force(expr); NULL }, error = identity)
  stopifnot(inherits(result, 'error')); checks <<- checks + 1L
}
valid <- function(phase) data.frame(test = vision_suite_spec(phase)$required,
  failed = 0L, error = FALSE, passed = 1L, skipped = FALSE)
for (phase in c('preflight', 'vision')) {
  df <- valid(phase); stopifnot(validate_vision_results(df, phase)); checks <- checks + 1L
  reject(validate_vision_results(df[-1L, ], phase))
  reject(validate_vision_results(rbind(df, df[1L, ]), phase))
  changed <- df; changed$skipped[[1L]] <- TRUE
  reject(validate_vision_results(changed, phase)) # skip after passing expectations
  changed <- df; changed$passed[[1L]] <- 0L
  reject(validate_vision_results(changed, phase))
  changed <- rbind(df, data.frame(test='unrelated failure', failed=1L,
    error=FALSE, passed=0L, skipped=FALSE))
  reject(validate_vision_results(changed, phase))
  changed$failed[nrow(changed)] <- 0L; changed$error[nrow(changed)] <- TRUE
  reject(validate_vision_results(changed, phase))
  changed <- df; changed$skipped[[1L]] <- NA
  reject(validate_vision_results(changed, phase))
  reject(validate_vision_results(df[0, ], phase))
  reject(validate_vision_results(df[, -2L], phase))
  files <- list.files('rebirth/tests/testthat', pattern='^test-.*[.]R$', full.names=TRUE)
  selected <- files[grepl(vision_suite_spec(phase)$filter,
    sub('[.]R$', '', sub('^test-', '', basename(files))))]
  names <- unlist(lapply(selected, function(path) {
    nodes <- as.list(parse(path))
    unlist(lapply(nodes, function(x) if (is.call(x) && identical(x[[1]],
      as.name('test_that'))) as.character(x[[2]]) else NULL))
  }))
  stopifnot(all(vapply(vision_suite_spec(phase)$required,
    function(name) sum(names == name) == 1L, logical(1))))
  if (phase == 'vision') stopifnot(
    'test-llm-vision-async.R' %in% basename(selected),
    !any(grepl('^test-llm-async', basename(selected))))
  checks <- checks + 1L
}
reject(vision_suite_spec('typo'))
cat(sprintf('VISION_RUNNER_CONTROLS_PASSED checks=%d (no model execution)\n', checks))
