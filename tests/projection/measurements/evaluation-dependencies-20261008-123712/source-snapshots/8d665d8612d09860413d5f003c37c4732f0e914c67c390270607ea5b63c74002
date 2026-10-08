# New model-free runtime and carried-construction checks only.
args <- commandArgs(TRUE); stopifnot(length(args) %in% c(1L,2L))
source('/Users/alessandrovadala/DOCUDESK/R-ebirth/tests/projection/evaluation/run.R')
cfg <- jsonlite::read_json(args[[1L]])
setwd(dirname(args[[1L]]))
library(relm)
stopifnot(normalizePath(find.package('relm'))==normalizePath(cfg$library),
  f6e_hash(getLoadedDLLs()[['relm']][['path']])==cfg$dll_sha256)
record <- attr(readRDS('artifacts/mlp.rds'),'direction')$context$model
f6e_runtime_preflight(cfg)
artifacts <- f6e_carried_construction(cfg,record)
stopifnot(length(artifacts)==3L, identical(names(artifacts),c('residual','mlp','random_mlp')))
stopifnot(file.rename('dependency-preflight.json','dependency-preflight-before-load.json'),
  file.rename('carried-construction.json','carried-construction-preflight.json'))
if(length(args)==2L) {
  refused <- function(expr) stopifnot(inherits(tryCatch({force(expr);NULL},error=identity),'error'))
  x <- cfg; x$dependency_packages[[1L]]$version <- '0.0.0'; refused(f6e_runtime_preflight(x))
  x <- cfg; x$dependency_packages[[1L]]$path <- '/nonexistent-f6e-package'; refused(f6e_runtime_preflight(x))
  x <- cfg; x$dependency_manifest_sha256 <- paste(rep('0',64),collapse=''); refused(f6e_runtime_preflight(x))
  x <- cfg; x$construction_files[[1L]] <- paste(rep('0',64),collapse=''); refused(f6e_carried_construction(x,record))
  r <- record; r$hidden_size <- 1L; refused(f6e_carried_construction(cfg,r))
  cat('F6E_RESUME_CONTROLS positive=2 negative=5 models=0 inference=0\n')
}
cat('F6E_RESUME_PREFLIGHT dependencies=PASS carried_artifacts=3 carried_captures=24 models=0 inference=0\n')
