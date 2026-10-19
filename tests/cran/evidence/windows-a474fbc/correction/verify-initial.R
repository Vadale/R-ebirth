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
reporter <- testthat::ListReporter$new()
testthat::with_reporter(reporter, eval(test, e))
results <- reporter$get_results()
stopifnot(length(results)==1L, length(results[[1]]$results)==5L,
          all(vapply(results[[1]]$results,inherits,logical(1),"expectation_success")))
# Compare the recorded Windows parent spellings without filesystem access.
log <- readLines("/home/grauk/Work/relm-phase9/ci-a474fbc/artifact/R-ebirth/R-ebirth/rebirth/check/relm.Rcheck/00check.log")
actual <- sub('^  - ', '', grep('^  - "C:',log,value=TRUE))
expected <- sub('^  \+ ', '', grep('^  \+ "C:',log,value=TRUE))
actual <- eval(parse(text=actual)); expected <- eval(parse(text=expected))
stopifnot(!identical(actual,expected),identical(actual,gsub("\\", "/",expected,fixed=TRUE)))
cat("SPILL_PATH_CORRECTION_PASS cases=1 expectations=5 helpers_unchanged=4 raw_windows_separator_only=1 models=0 native_builds=0\n")
