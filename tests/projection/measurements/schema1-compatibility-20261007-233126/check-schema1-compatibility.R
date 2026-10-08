# Source-only checks: no relm namespace/DLL load, no model or installed acceptance.
.libPaths(c('/private/tmp/relm-f6d/library', .libPaths()))
repo <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'
out <- Sys.getenv('F6E_SCHEMA_RUN'); stopifnot(nzchar(out))
env <- new.env(parent = globalenv())
for (f in c('conditions.R', 'direction-schema.R', 'direction-arithmetic.R',
            'direction-encoding.R', 'direction-validation.R', 'directions.R')) {
  sys.source(file.path(repo, 'rebirth/R', f), envir = env)
}
sys.source(file.path(repo, 'rebirth/tests/testthat/helper-directions.R'), envir = env)
sys.source(file.path(repo, 'rebirth/tests/testthat/helper-direction-goldens.R'), envir = env)
# Preserve test expressions, replacing only relm::: lookups with these exact
# sourced definitions. The later installed-package run will use real namespaces.
original <- readLines(file.path(repo,'rebirth/tests/testthat/test-directions-goldens.R'))
selected <- Filter(function(x) is.call(x) && identical(x[[1L]], as.name('test_that')) && as.character(x[[2L]]) %in% c('canonical R bytes exactly match all independent typed streams', 'independent binary artifact survives full validation and rejects edits'), as.list(parse(text = original)))
stopifnot(length(selected) == 2L)
derived <- gsub('relm:::', '', unlist(lapply(selected, deparse), use.names = FALSE), fixed = TRUE)
writeLines(derived, file.path(out,'source-test.R'))
path <- tempfile('.projection-source-', tmpdir=file.path(repo,'rebirth/tests/testthat'),fileext='.R')
on.exit <- NULL
tryCatch({
 writeLines(derived,path)
 result <- testthat::test_file(path, env=env, reporter='summary', stop_on_failure=TRUE)
 frame <- as.data.frame(result)
 saveRDS(result,file.path(out,'test-results.rds'))
 write.csv(frame[,setdiff(names(frame),'result'),drop=FALSE],file.path(out,'test-results.csv'),row.names=FALSE)
 stopifnot(nrow(frame)==2L, sum(frame$failed)==0L, sum(frame$error)==0L,
           sum(frame$skipped)==0L, sum(frame$warning)==0L)
 cat(sprintf('F6E_SCHEMA1_COMPATIBILITY cases=%d expectations=%d failures=0 errors=0 skips=0 warnings=0\n',nrow(frame),sum(frame$passed)))
},finally=unlink(path))
