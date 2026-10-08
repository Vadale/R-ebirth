args <- commandArgs(TRUE)
stopifnot(length(args) == 3L)
mode <- args[[1L]]; root <- args[[2L]]; output <- args[[3L]]
library(relm)
stopifnot(normalizePath(find.package('relm')) == '/private/tmp/relm-f6e/public-library-budget/relm')
err <- tryCatch({relm:::async_check_dependencies(); NULL}, error = identity)
packages <- lapply(c('later','promises'), function(p) {
  found <- requireNamespace(p, quietly = TRUE)
  list(package = p, available = found, path = if (found) find.package(p) else NULL,
    version = if (found) as.character(packageVersion(p)) else NULL)
})
if (mode == 'original') {
  stopifnot(inherits(err, 'relm_error_generation'), identical(err$reason, 'async_dependency'),
    identical(err$package, 'later'), identical(err$required_version, '1.4.8'), is.na(err$installed_version))
  rows <- read.csv(file.path(root, 'selection.csv'), stringsAsFactors = FALSE)
  stopifnot(nrow(rows) == 72L, all(rows$status == 'error'))
  for (id in rows$run_id) {
    r <- readRDS(file.path(root, 'raw', paste0(id, '.rds')))
    stopifnot(is.null(r$value), nrow(r$events) == 0L, identical(r$settlements, 0L),
      identical(r$done, TRUE), identical(r$timed_out, FALSE),
      identical(class(r$error), class(err)), identical(as.list(r$error), as.list(err)))
  }
} else {
  stopifnot(mode == 'corrected', is.null(err),
    normalizePath(find.package('later')) == '/private/tmp/relm-service/library/later',
    normalizePath(find.package('promises')) == '/private/tmp/relm-service/library/promises')
}
jsonlite::write_json(list(mode=mode, library_paths=.libPaths(), packages=packages,
  dependency_gate=if(is.null(err)) 'PASS' else 'async_dependency',
  error=if(is.null(err)) NULL else as.list(err), models=0, inference=0,
  raw_failed_settings_verified=if(mode=='original') 72L else 0L), output,
  auto_unbox=TRUE, pretty=TRUE, null='null', na='null')
cat('F6E_DEPENDENCY_DIAGNOSIS mode=',mode,' models=0 inference=0\n',sep='')
