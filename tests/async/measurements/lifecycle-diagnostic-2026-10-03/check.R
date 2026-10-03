.libPaths(c('/private/tmp/relm-maintenance/d040-library', '/private/tmp/relm-wp10/library', '/private/tmp/relm-service/library', .libPaths()))
library(relm)
stopifnot(normalizePath(find.package('relm')) == '/private/tmp/relm-maintenance/d040-library/relm')
out <- '/private/tmp/relm-maintenance/lifecycle-diagnostics-local'
dir.create(out, showWarnings=FALSE)
expressions <- parse('rebirth/tests/testthat/test-llm-async-lifecycle.R')
titles <- c('real synthetic models defer close and GC while a fixture owns native execution',
 'lifecycle diagnostics do not deliver callbacks after the drain deadline')
selected <- Filter(function(x) is.call(x) && identical(x[[1]], as.name('test_that')) && as.character(x[[2]]) %in% titles, as.list(expressions))
stopifnot(length(selected) == 2L)
file <- file.path(out, 'test-selected.R')
writeLines(c(deparse(expressions[[1]], width.cutoff=500L),
 "synthetic_model_path <- function() '/Users/alessandrovadala/DOCUDESK/R-ebirth/rebirth/tests/testthat/fixtures/synthetic-llama-2l.gguf'",
 unlist(lapply(selected, deparse, width.cutoff=500L))), file)
result <- testthat::test_file(file, reporter='summary', package='relm')
counts <- as.data.frame(result); counts <- counts[, !vapply(counts,is.list,logical(1)), drop=FALSE]
write.csv(counts,file.path(out,'counts.csv'),row.names=FALSE)
writeLines(capture.output(sessionInfo()),file.path(out,'session.txt'))
stopifnot(nrow(counts)==2L, sum(counts$passed)==6L, sum(counts$failed)==0L, sum(counts$error)==0L, sum(counts$skipped)==0L)
cat('LIFECYCLE_DIAGNOSTIC_GATES_PASSED\n')
