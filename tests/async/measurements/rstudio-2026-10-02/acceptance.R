# Run in a verified fresh, empty RStudio R session; preserve all editor documents.
# This intentionally starts a foreground-console async call, not a background job.
stopifnot(length(setdiff(ls(.GlobalEnv, all.names = TRUE), '.Random.seed')) == 0L,
  !'relm' %in% loadedNamespaces(), Sys.getenv('RSTUDIO') == '1')
saveRDS(list(globals = ls(.GlobalEnv, all.names = TRUE), seed = if (exists('.Random.seed', .GlobalEnv, inherits = FALSE)) .Random.seed else NULL, library = .libPaths(),
  search = search(), pid = Sys.getpid(), session = sessionInfo()),
  '/private/tmp/relm-wp9/rstudio/preflight.rds')
root <- '/private/tmp/relm-wp9'
.libPaths(c(file.path(root, 'library'), '/private/tmp/relm-service/library', .libPaths()))
if ('relm' %in% loadedNamespaces()) {
  stopifnot(normalizePath(find.package('relm')) == file.path(root, 'library', 'relm'))
}
library(relm)
stopifnot('llm_cancel' %in% getNamespaceExports('relm'), Sys.getenv('RSTUDIO') == '1')
.relm_wp9_acceptance <- new.env(parent = globalenv())
a <- .relm_wp9_acceptance
a$root <- root
a$status <- 'running'
a$probe <- NULL
a$heartbeats <- 0L
a$receipt <- function() {
  value <- list(status = a$status, pid = Sys.getpid(), rstudio = Sys.getenv('RSTUDIO'),
    version = as.character(packageVersion('relm')), library = find.package('relm'),
    started_at = a$started_at, finished_at = a$finished_at, probe = a$probe,
    heartbeat_count = a$heartbeats, error = a$error,
    rstudio_version = as.character(rstudioapi::versionInfo()$version))
  jsonlite::write_json(value, file.path(a$root, 'rstudio', 'status.tmp'),
    auto_unbox = TRUE, pretty = TRUE, null = 'null')
  stopifnot(file.rename(file.path(a$root, 'rstudio', 'status.tmp'),
    file.path(a$root, 'rstudio', 'status.json')))
}
a$model <- llm('/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf',
  backend = 'cpu', context_length = 2048)
a$started_at <- as.numeric(Sys.time())
a$started_elapsed <- proc.time()[['elapsed']]
a$beat <- function() {
  if (identical(a$status, 'running')) {
    a$heartbeats <- a$heartbeats + 1L
    later::later(a$beat, 0.05)
  }
}
later::later(a$beat, 0.05)
a$promise <- llm_generate(a$model,
  rep('Count integers from 1 to 1000, separated by commas. Do not explain.', 4),
  max_tokens = 512, temperature = 0, seed = 17, async = TRUE)
a$submission_seconds <- proc.time()[['elapsed']] - a$started_elapsed
a$observe <- promises::then(a$promise, function(value) {
  a$finished_at <- as.numeric(Sys.time())
  a$duration <- a$finished_at - a$started_at
  good <- a$duration >= 5 && !is.null(a$probe) && isTRUE(a$probe$was_running) &&
    identical(a$probe$value, 2) && a$probe$elapsed < 0.5 && a$heartbeats >= 10L
  a$status <- if (good) 'passed' else 'failed'
  if (!good) a$error <- 'Interactive duration/probe/heartbeat acceptance gate failed.'
  saveRDS(list(value = value, duration = a$duration, submission_seconds = a$submission_seconds),
    file.path(a$root, 'rstudio', 'result.rds'))
  close(a$model)
  a$receipt()
  cat('WP9_RSTUDIO_COMPLETE:', a$status, '\n')
  NULL
}, function(error) {
  a$status <- 'failed'; a$error <- conditionMessage(error)
  a$finished_at <- as.numeric(Sys.time())
  close(a$model); a$receipt(); NULL
})
a$receipt()
cat('WP9_RSTUDIO_RUNNING: submit the independent 1 + 1 probe now.\n')
