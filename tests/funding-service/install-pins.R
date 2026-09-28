#!/usr/bin/env Rscript
# Explicit preparation only. Never sourced by the running service.
args <- commandArgs(TRUE)
if (length(args) != 1L) stop('Usage: Rscript install-pins.R /absolute/library')
target <- args[[1L]]
dir.create(target, recursive=TRUE, showWarnings=FALSE, mode='0700')
target <- normalizePath(target)
pins <- read.csv('tests/service-contract/dependencies.csv', stringsAsFactors=FALSE)
installed <- installed.packages()
for (i in seq_len(nrow(pins))) {
  pkg <- pins$package[[i]]
  choices <- which(installed[, 'Package'] == pkg & installed[, 'Version'] == pins$version[[i]])
  if (length(choices) && !dir.exists(file.path(target, pkg))) {
    from <- file.path(installed[choices[[1L]], 'LibPath'], pkg)
    if (!file.copy(from, target, recursive=TRUE)) stop('Copy failed: ', pkg)
  }
}
.libPaths(c(target, .libPaths()))
missing <- pins$package[!dir.exists(file.path(target, pins$package))]
if (length(missing)) {
  binary <- if (Sys.info()[['sysname']] == 'Darwin') available.packages(repos='https://cran.r-project.org', type='binary') else NULL
  matches <- if (is.null(binary)) character() else missing[vapply(missing, function(pkg)
    pkg %in% rownames(binary) && binary[pkg, 'Version'] == pins$version[match(pkg, pins$package)], logical(1))]
  if (length(matches)) install.packages(matches, lib=target, repos='https://cran.r-project.org', type='binary', dependencies=FALSE)
  # Dependency order of the frozen closure, including packages requiring compilation.
  order <- c('R6','Rcpp','cli','crayon','curl','fastmap','jsonlite','magrittr','mime','otel','ps','rlang','sodium','stringi','webutils','lifecycle','later','processx','swagger','promises','callr','httpuv','plumber')
  for (pkg in order[order %in% missing]) {
    dest <- file.path(target,pkg)
    want <- pins$version[match(pkg,pins$package)]
    if (dir.exists(dest) && read.dcf(file.path(dest,'DESCRIPTION'),'Version')[[1L]] == want) next
    filename <- paste0(pkg, '_', want, '.tar.gz')
    tmp <- tempfile(fileext='.tar.gz')
    urls <- c(paste0('https://cran.r-project.org/src/contrib/',filename), paste0('https://cran.r-project.org/src/contrib/Archive/',pkg,'/',filename))
    ok <- FALSE
    for (url in urls) {
      ok <- tryCatch({download.file(url,tmp,mode='wb',quiet=TRUE); TRUE}, error=function(e) FALSE)
      if (ok) break
    }
    if (!ok) stop('Pinned source unavailable: ', pkg)
    install.packages(tmp, lib=target, repos=NULL, type='source', dependencies=FALSE)
    unlink(tmp)
  }
}
for (i in seq_len(nrow(pins))) {
  file <- file.path(target,pins$package[[i]],'DESCRIPTION')
  if (!file.exists(file) || read.dcf(file,'Version')[[1L]] != pins$version[[i]]) stop('Unprepared pin: ',pins$package[[i]])
}
cat('Prepared all 23 approved application package pins.\n')
