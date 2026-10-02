.libPaths(c('/private/tmp/relm-wp10/library', .libPaths()))
library(relm)
library(testthat)
cat('Runtime:', R.version.string, 'promises', as.character(packageVersion('promises')), 'later', as.character(packageVersion('later')), '\n')
stopifnot(normalizePath(find.package('relm')) == '/private/tmp/relm-wp10/library/relm')
expressions <- parse('/Users/alessandrovadala/DOCUDESK/R-ebirth/rebirth/tests/testthat/test-llm-async.R')
for (expr in expressions) {
  if (identical(expr[[1]], as.name('<-'))) eval(expr)
}
trace('async_settle', where=asNamespace('relm'), tracer=quote(cat('SETTLE', proc.time()[['elapsed']], '\n')), print=FALSE)
selected <- Filter(function(e) identical(e[[1]],as.name('test_that')) && identical(e[[2]], 'native async promise is responsive and services independent R heartbeats'), as.list(expressions))
stopifnot(length(selected)==1L)
eval(selected[[1]])
cat('FOCUSED_ASYNC_REPRO_COMPLETE\n')


receipt <- dget('_diagnostics/async-responsiveness.txt')
stopifnot(receipt$elapsed >= 1.9, receipt$elapsed < 10,
          receipt$observer_done, receipt$parent_status == 'fulfilled',
          receipt$observer_status == 'fulfilled')
cat('SINGLE_HOLD_RESPONSIVENESS_PASSED\n')
