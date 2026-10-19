.libPaths(c("/home/grauk/Work/relm-phase9/source-install-build/library", "/home/grauk/.local/share/relm/phase8/R-library", .libPaths()))
ns <- asNamespace("relm")
helpers <- c("next_spill_path", "next_trace_id", "spill_session_dir", "spill_root_dir")
source_env <- new.env()
for (expr in parse("rebirth/R/zzz.R")) {
  if (is.call(expr) && identical(expr[[1]], as.name("<-")) && as.character(expr[[2]]) %in% helpers) eval(expr, source_env)
}
for (name in helpers) {
  stopifnot(identical(body(get(name, ns)), body(get(name,source_env))),
            identical(formals(get(name, ns)), formals(get(name,source_env))))
}
test <- parse("rebirth/tests/testthat/test-llm-trace-spill-session.R")[[1L]]
e <- new.env(parent=ns)
for (name in c("test_that", "expect_false", "expect_identical")) e[[name]] <- getExportedValue("testthat",name)
file <- "/home/grauk/Work/relm-phase9/spill-path-correction/test-focused.R"
writeLines(deparse(test, width.cutoff=120L), file)
results <- testthat::test_file(file, env=e, reporter="summary", stop_on_failure=TRUE)
saveRDS(results, "/home/grauk/Work/relm-phase9/spill-path-correction/results.rds")
stopifnot(length(results)==1L, length(results[[1]]$results)==5L,
          all(vapply(results[[1]]$results,inherits,logical(1),"expectation_success")))
cat("SPILL_PATH_CORRECTION_PASS cases=1 expectations=5 helpers_unchanged=4 models=0 native_builds=0\n")
