root <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'; setwd(root)
library(relm)
stopifnot(normalizePath(find.package('relm')) == '/private/tmp/relm-f6c/library/relm')
# Validate the already executed receipts; do not rerun their tests.
parent <- '/private/tmp/relm-f6c/ci-package-20261007-142016'
rows <- read.csv(file.path(parent,'focused-tests.csv'))
stopifnot(nrow(rows)==7L, identical(as.integer(rows$passed),c(1L,1L,7L,8L,4L,4L,3L)),
 sum(rows$passed)==28L, all(rows$failed==0L), !any(rows$error), !any(rows$skipped), all(rows$warning==0L))
cat('F6C_PARENT_TEST_RECEIPTS_VERIFIED: 7 cases / 28 expectations, executed at ci-package-20261007-142016\n')
notes <- capture.output(codetools::checkUsagePackage('relm'))
writeLines(notes,file.path(Sys.getenv('RELM_F6C_EVIDENCE'),'code-usage.txt'))
stopifnot(length(notes)==0L)
cat('F6C_NAMESPACE_CODE_USAGE_PASSED\n')
