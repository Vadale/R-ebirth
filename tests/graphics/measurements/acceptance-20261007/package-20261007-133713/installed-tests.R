root <- '/Users/alessandrovadala/DOCUDESK/R-ebirth'; setwd(root)
library(relm)
stopifnot(normalizePath(find.package('relm')) == '/private/tmp/relm-f6c/library/relm',
  all(c('llm_compare','llm_timeline') %in% getNamespaceExports('relm')),
  identical(formals(llm_compare)$max_bytes, quote(64 * 1024^2)))
e <- new.env(parent=asNamespace('relm'))
sys.source('rebirth/tests/testthat/helper-llm.R', e)
sys.source('rebirth/tests/testthat/helper-graphics.R', e)
r <- lapply(list.files('rebirth/tests/testthat','^test-graphics.*[.]R$',full.names=TRUE),
 function(f) testthat::test_file(f,env=e,reporter='summary'))
rows <- do.call(rbind,lapply(r,as.data.frame))
out <- Sys.getenv('RELM_F6C_EVIDENCE')
saveRDS(r,file.path(out,'installed-tests.rds'))
write.csv(rows[,setdiff(names(rows),'result')],file.path(out,'installed-tests.csv'),row.names=FALSE)
stopifnot(nrow(rows)>=20L, all(rows$failed==0L), !any(rows$error), !any(rows$skipped), all(rows$warning==0L))
cat('F6C_INSTALLED_TESTS_PASSED',nrow(rows),sum(rows$passed),'\n')
example('llm_compare',package='relm',ask=FALSE,echo=FALSE)
example('llm_timeline',package='relm',ask=FALSE,echo=FALSE)
cat('F6C_EXAMPLES_PASSED\n')
