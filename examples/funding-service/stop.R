#!/usr/bin/env Rscript
script <- sub('^--file=', '', grep('^--file=', commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(normalizePath(script)), 'common.R'))
source(file.path(svc_module, 'runtime.R'))
app_cli({
  args <- app_options(commandArgs(TRUE), c('environment', 'store'))
  if (!all(c('environment', 'store') %in% names(args))) app_abort('Supply --environment and --store.')
  svc_library(file.path(args$environment, 'library'))
  svc_stop(args$store)
  cat('Stop requested.\n')
})
