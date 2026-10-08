# Model-free source controls, before native execution. No relm DLL is loaded.
.libPaths(c('/private/tmp/relm-f6d/library', .libPaths()))
repo <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'
out <- Sys.getenv('F6E_LEDGER_RUN'); stopifnot(nzchar(out))
env <- new.env(parent = globalenv())
for (f in c('conditions.R','direction-schema.R','direction-arithmetic.R',
 'direction-encoding.R','direction-validation.R','directions.R','live-state.R','projection-memory.R'))
 sys.source(file.path(repo,'rebirth/R',f),envir=env)
sys.source(file.path(repo,'rebirth/tests/testthat/helper-directions.R'),envir=env)
text <- readLines(file.path(repo,'rebirth/tests/testthat/test-projection-memory.R'))
old <- parse(file.path(repo,'rebirth/tests/testthat/test-directions-boundaries.R'))
selected <- Filter(function(x) is.call(x) && identical(x[[1]],as.name('test_that')) &&
 identical(x[[2]],'recorded capture and splits fail closed without silent reconciliation'), as.list(old))
stopifnot(length(selected)==1L)
text <- c(text, deparse(selected[[1]],width.cutoff=500L))
text <- gsub('relm:::', '',text,fixed=TRUE)
writeLines(text,file.path(out,'source-test.R'))
path <- tempfile('.projection-ledger-',tmpdir=file.path(repo,'rebirth/tests/testthat'),fileext='.R')
tryCatch({
 writeLines(text,path)
 result <- testthat::test_file(path,env=env,reporter='summary',stop_on_failure=FALSE)
 frame <- as.data.frame(result)
 saveRDS(result,file.path(out,'r-test-results.rds'))
 write.csv(frame[,setdiff(names(frame),'result'),drop=FALSE],file.path(out,'r-test-results.csv'),row.names=FALSE)
 stopifnot(nrow(frame)==7L,all(frame$passed>0),sum(frame$failed)==0L,
  sum(frame$error)==0L,sum(frame$skipped)==0L,sum(frame$warning)==0L)
 cat(sprintf('F6E_LEDGER_R_SOURCE cases=%d expectations=%d failures=0 errors=0 skips=0 warnings=0\n',nrow(frame),sum(frame$passed)))
},finally=unlink(path))
