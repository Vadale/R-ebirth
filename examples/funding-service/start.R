#!/usr/bin/env Rscript
script <- sub('^--file=', '', grep('^--file=', commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(normalizePath(script)), 'common.R'))
source(file.path(svc_module, 'runtime.R'))
app_cli({
  Sys.umask('0077')
  args <- app_options(commandArgs(TRUE), c('environment', 'store', 'port'))
  if (!all(c('environment', 'store') %in% names(args))) app_abort('Supply --environment and --store.')
  port <- if (is.null(args$port)) 8765L else app_integer(as.numeric(args$port), 'port', 1024L, 65535L)
  svc_run(svc_environment(args$environment), args$store, port = port)
})
