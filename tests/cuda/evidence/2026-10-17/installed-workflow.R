args <- commandArgs(TRUE)
stopifnot(length(args) == 4L)
repo <- normalizePath(args[[1L]], mustWork = TRUE)
output <- normalizePath(args[[2L]], mustWork = TRUE)
model <- normalizePath(args[[3L]], mustWork = TRUE)
logger <- normalizePath(args[[4L]], mustWork = TRUE)
library(relm)
stopifnot('cuda' %in% relm:::rebirth_available_backends())
shim <- dyn.load(logger)
status <- .C('f6e_log_start', getLoadedDLLs()[['relm']][['path']],
  file.path(output, 'cuda-placement.log'), status = integer(1), PACKAGE = shim[['name']])$status
stopifnot(status == 0L)
run <- function() {
  on.exit(stopifnot(.C('f6e_log_stop', status = integer(1), PACKAGE = shim[['name']])$status == 0L))
  example <- new.env(parent = globalenv())
  sys.source(file.path(repo, 'examples/research-workflow/run.R'), example)
  # New texts only; preserve the example's IDs, roles and fixed coefficients.
  original_prompts <- example$research_prompts()
  prompts <- original_prompts
  prompts$text <- c(
    'Explain why a lighthouse sends light over the sea in one short sentence.',
    'Explain why a lighthouse sends light over the sea in a detailed paragraph.',
    'Explain why a gardener turns compost in one short sentence.',
    'Explain why a gardener turns compost in a detailed paragraph.',
    'What does a barometer measure? Answer in one short sentence.',
    'Why does an insulated flask keep a drink warm? Answer in one short sentence.'
  )
  stopifnot(identical(prompts[c('id', 'split')], original_prompts[c('id', 'split')]),
    !any(prompts$text %in% original_prompts$text))
  example$research_prompts <- function() prompts
  example$run_research_workflow(model, file.path(output, 'workflow'),
    'b10828/49f780edda8a7da6bfb3f49af162dc1a57848aa91e4ee96ba75fc8372b724dfc',
    backend = 'cuda')
  # Exactly the existing bounded workflow: one load, four construction traces,
  # eight short async/live generations and six derived handles. No tuning.
  stopifnot(is.null(relm:::.relm_async$job))
  log <- readLines(file.path(output, 'cuda-placement.log'), warn = FALSE)
  flat <- gsub('[[:space:]]+', ' ', log)
  for (receipt in c('offloaded 25/25 layers', 'CUDA0 model buffer size',
                    'CUDA0 KV buffer size', 'CUDA0 compute buffer size')) {
    stopifnot(any(grepl(receipt, flat, fixed = TRUE)))
  }
  settings <- readRDS(file.path(output, 'workflow/settings.rds'))
  stopifnot(identical(settings$backend, 'cuda'), settings$max_tokens == 32L,
    settings$temperature == 0, settings$seed == 1707L)
  cat('WP13_INSTALLED_CUDA_WORKFLOW_COMPLETE loads=1 traces=4 generations=8 derives=6\n')
}
run()
