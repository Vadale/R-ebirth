# Exercise the complete base preflight with a Windows-default path spelling
# ONLY at its expected-path call; actual directory and .libPaths behavior are real.
root <- '/home/grauk/Work/relm-phase9/vignette-path-correction'
path <- 'tests/cran/vignette-library.R'
old <- system2('git', c('show', paste0('HEAD:', path)), stdout=TRUE)
writeLines(old, file.path(root, 'original.R'))
writeLines(deparse(.libPaths), file.path(root, 'actual-libPaths.R'))
run <- function(code, name) {
  dest <- file.path(root, name)
  stopifnot(dir.create(dest))
  e <- new.env(parent=globalenv())
  e$commandArgs <- function(...) dest
  e$normalizePath <- function(path, winslash='\\', mustWork=NA) {
    value <- base::normalizePath(path, winslash='/', mustWork=mustWork)
    if (endsWith(path, 'temporary library with spaces') && winslash=='\\')
      value <- gsub('/', '\\', value, fixed=TRUE)
    value
  }
  tryCatch({eval(parse(text=code), e); NULL}, error=identity)
}
failure <- run(old, 'old-spelling')
stopifnot(inherits(failure,'error'),
          grepl('identical(.libPaths()[[1]], normalizePath(lib))', conditionMessage(failure),fixed=TRUE))
writeLines(conditionMessage(failure), file.path(root,'expected-old-failure.txt'))
stopifnot(is.null(run(readLines(path), 'current-spelling')))
cat('VIGNETTE_PATH_REGRESSION_PASS old_default_rejected=1 current_base_cases=3 models=0 native_builds=0\n')
