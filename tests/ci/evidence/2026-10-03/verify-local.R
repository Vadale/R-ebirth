.libPaths(c('/private/tmp/relm-maintenance/d040-library', '/private/tmp/relm-wp10/library', '/private/tmp/relm-service/library', .libPaths()))
root <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'; setwd(root)
out <- '/private/tmp/relm-ci-efficiency'
old <- parse(text = system2('git', c('show', 'daee903f8bca53715b658fae148828d769f45081:rebirth/tests/testthat/test-llm-async.R'), stdout = TRUE))
new <- c(as.list(parse('rebirth/tests/testthat/helper-async.R')),
 as.list(parse('rebirth/tests/testthat/test-llm-async.R')),
 as.list(parse('rebirth/tests/testthat/test-llm-vision-async.R')))
# Every original top-level expression is preserved exactly once, only moved.
stopifnot(length(old) == length(new))
for (x in as.list(old)) stopifnot(sum(vapply(new, function(y) identical(x,y), logical(1))) == 1L)
cat('ASYNC_TEST_MOVEMENT_PASSED expressions=',length(old),'\n')
source('tests/ci/test-vision-runner.R')
Sys.unsetenv(c('RELM_TEST_MODEL_QWEN','RELM_TEST_MODEL_VLM','RELM_TEST_MMPROJ_VLM'))
err <- tryCatch(run_vision_phase('vision', '/private/tmp/relm-maintenance/d040-library',
 file.path(out,'no-model-rejected')), error=identity)
stopifnot(inherits(err,'error'), grepl('pinned VLM', conditionMessage(err), fixed=TRUE))
cat('MISSING_MODEL_REJECTED_BEFORE_SUITE\n')
run_vision_phase('preflight', '/private/tmp/relm-maintenance/d040-library',
 file.path(out,'preflight'))
result <- testthat::test_dir('rebirth/tests/testthat', filter='^llm-async$|^llm-vision-async$',
 package='relm', load_package='installed', reporter='summary', stop_on_failure=FALSE)
df <- as.data.frame(result); write.csv(df[,!vapply(df,is.list,logical(1)),drop=FALSE],
 file.path(out,'async-results.csv'), row.names=FALSE)
stopifnot(sum(df$failed)==0L, !any(df$error), nrow(df)>20L, sum(df$passed)>1000L)
cat('FOCUSED_ASYNC_PASSED cases=',nrow(df),' expectations=',sum(df$passed),' skips=',sum(df$skipped),'\n')
