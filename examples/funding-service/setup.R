#!/usr/bin/env Rscript
script <- sub('^--file=', '', grep('^--file=', commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(normalizePath(script)), 'common.R'))
app_cli({
  args <- app_options(commandArgs(TRUE), c('environment', 'source-library', 'model', 'model-alias', 'backend'))
  required <- c('environment', 'source-library', 'model', 'model-alias', 'backend')
  if (!all(required %in% names(args))) app_abort(paste('Required options:', paste(required, collapse = ', ')))
  svc_setup(args$environment, args[['source-library']], args$model, args[['model-alias']], args$backend)
  cat('Prepared service environment:', normalizePath(args$environment), '\n')
})
