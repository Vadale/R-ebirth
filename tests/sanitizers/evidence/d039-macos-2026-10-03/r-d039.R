library(relm)
stopifnot(normalizePath(find.package('relm')) == '/private/tmp/relm-maintenance/d039-library/relm')
result <- testthat::test_dir('rebirth/tests/testthat',
  filter='llm-(generate|trace|async|stream|steer)', package='relm', load_package='installed', reporter='summary', stop_on_failure=FALSE)
out <- Sys.getenv('RELM_MAINTENANCE_EVIDENCE')
saveRDS(result,file.path(out,'r-final.rds'))
counts <- as.data.frame(result)
counts <- counts[,!vapply(counts,is.list,logical(1)),drop=FALSE]
write.csv(counts,file.path(out,'r-final-counts.csv'),row.names=FALSE)
writeLines(capture.output(sessionInfo()),file.path(out,'r-session.txt'))
stopifnot(nrow(counts)>50L,sum(counts$passed)>500L,sum(counts$failed)==0L,sum(counts$error)==0L)
