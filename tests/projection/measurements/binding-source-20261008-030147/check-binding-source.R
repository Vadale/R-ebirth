repo <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'
out <- Sys.getenv('F6E_BINDING_RUN'); stopifnot(nzchar(out))
e <- new.env(parent = globalenv())
for (file in c('conditions.R','direction-schema.R','live-state.R','llm.R',
    'projection-memory.R','projection-owners.R','projection-binding.R')) {
  sys.source(file.path(repo,'rebirth/R',file), envir=e)
}
helper_files <- c('test-projection-memory.R','test-projection-owners.R')
helper_names <- c('projection_test_profile','projection_test_inputs','projection_owner_model','projection_owner_entry')
helpers <- list()
for (file in helper_files) {
  expressions <- as.list(parse(file.path(repo,'rebirth/tests/testthat',file)))
  helpers <- c(helpers,Filter(function(x) is.call(x) && identical(x[[1]],as.name('<-')) &&
    as.character(x[[2]]) %in% helper_names,expressions))
}
stopifnot(length(helpers)==4L)
text <- c(unlist(lapply(helpers,deparse,width.cutoff=500L)),
  readLines(file.path(repo,'rebirth/tests/testthat/test-projection-public-binding.R')))
text <- gsub('relm:::', '',text,fixed=TRUE)
path <- file.path(out,'source-test.R');writeLines(text,path)
r <- testthat::test_file(path,env=e,reporter='summary',stop_on_failure=FALSE)
f <- as.data.frame(r);saveRDS(r,file.path(out,'results.rds'))
write.csv(f[,setdiff(names(f),'result'),drop=FALSE],file.path(out,'results.csv'),row.names=FALSE)
stopifnot(nrow(f)==6L,identical(as.integer(f$passed),c(3L,7L,10L,7L,3L,7L)),
  sum(f$failed)==0L,sum(f$error)==0L,sum(f$skipped)==0L,sum(f$warning)==0L)
cat('F6E_BINDING_R_SOURCE cases=6 expectations=37 failures=0 errors=0 skips=0 warnings=0 models=0\n')
