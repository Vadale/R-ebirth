repo <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'
out <- Sys.getenv('F6E_APPLICATION_RUN');stopifnot(nzchar(out))
e <- new.env(parent=globalenv())
for (file in c('conditions','direction-schema','live-state','llm','projection-memory',
    'projection-owners','projection-binding','direction-arithmetic','direction-validation',
    'direction-encoding','directions','intervene','images')) {
  sys.source(file.path(repo,'rebirth/R',paste0(file,'.R')),envir=e)
}
text <- readLines(file.path(repo,'rebirth/tests/testthat/helper-directions.R'))
helper_files <- c('test-projection-memory.R','test-projection-owners.R','test-projection-public-binding.R')
helper_names <- c('projection_test_profile','projection_test_inputs','projection_test_config',
                  'projection_owner_model','projection_owner_entry','projection_binding_fixture')
helpers <- list();affected <- list()
for (file in helper_files) {
  expressions <- as.list(parse(file.path(repo,'rebirth/tests/testthat',file)))
  helpers <- c(helpers,Filter(function(x) is.call(x)&&identical(x[[1L]],as.name('<-'))&&
    as.character(x[[2L]]) %in% helper_names,expressions))
  affected <- c(affected,Filter(function(x) is.call(x)&&identical(x[[1L]],as.name('test_that'))&&
    identical(x[[2L]],'projection responses bind every term and actual model fact before derivation'),expressions))
}
stopifnot(length(helpers)==6L,length(affected)==1L)
text <- c(text,unlist(lapply(helpers,deparse,width.cutoff=500L)),
  readLines(file.path(repo,'rebirth/tests/testthat/test-projection-application.R')),
  unlist(lapply(affected,deparse,width.cutoff=500L)))
text <- gsub('relm:::', '', text,fixed=TRUE)
path <- file.path(out,'source-test.R');writeLines(text,path)
r <- testthat::test_file(path,env=e,reporter='summary',stop_on_failure=FALSE)
f <- as.data.frame(r);saveRDS(r,file.path(out,'results.rds'))
write.csv(f[,setdiff(names(f),'result'),drop=FALSE],file.path(out,'results.csv'),row.names=FALSE)
stopifnot(nrow(f)==9L,identical(as.integer(f$passed),c(9L,20L,5L,8L,6L,8L,5L,5L,31L)),
 sum(f$failed)==0L,sum(f$error)==0L,sum(f$skipped)==0L,sum(f$warning)==0L)
cat('F6E_PUBLIC_APPLICATION_R_SOURCE cases=9 expectations=97 failures=0 errors=0 skips=0 warnings=0 native=0 models=0\n')
