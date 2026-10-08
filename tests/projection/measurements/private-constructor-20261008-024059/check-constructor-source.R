# New version-2 R arithmetic only, not installed/native acceptance.
repo <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'
out <- Sys.getenv('F6E_CONSTRUCTOR_RUN'); stopifnot(nzchar(out))
env <- new.env(parent = globalenv())
for (f in c('conditions.R','direction-schema.R','live-state.R','projection-memory.R'))
 sys.source(file.path(repo,'rebirth/R',f),envir=env)
old <- parse(file.path(repo,'rebirth/tests/testthat/test-projection-memory.R'))
helper_names <- c('projection_test_profile','projection_test_inputs')
helpers <- Filter(function(x) is.call(x) && identical(x[[1]],as.name('<-')) &&
 as.character(x[[2]]) %in% helper_names,as.list(old))
stopifnot(length(helpers)==2L)
text <- c(unlist(lapply(helpers,deparse,width.cutoff=500L)),
 readLines(file.path(repo,'rebirth/tests/testthat/test-projection-constructor-memory.R')))
text <- gsub('relm:::', '',text,fixed=TRUE)
path <- file.path(out,'source-test.R');writeLines(text,path)
result <- testthat::test_file(path,env=env,reporter='summary',stop_on_failure=FALSE)
frame <- as.data.frame(result)
saveRDS(result,file.path(out,'r-source-results.rds'))
write.csv(frame[,setdiff(names(frame),'result'),drop=FALSE],file.path(out,'r-source-results.csv'),row.names=FALSE)
stopifnot(nrow(frame)==3L,identical(as.integer(frame$passed),c(9L,48L,4L)),
 sum(frame$failed)==0L,sum(frame$error)==0L,sum(frame$skipped)==0L,sum(frame$warning)==0L)
cat('F6E_CONSTRUCTOR_R_SOURCE cases=3 expectations=61 failures=0 errors=0 skips=0 warnings=0 models=0\n')
