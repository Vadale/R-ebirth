async_lifecycle_process <- function(body, timeout = 30, setup = NULL, setup_timeout = 0) {
    script <- tempfile(fileext = ".R")
    log <- tempfile(fileext = ".log")
    on.exit(unlink(c(script, log)), add = TRUE)
    libraries <- paste(capture.output(dput(.libPaths())), collapse = "\n")
    instrument <- function(lines, phase) {
        expressions <- parse(text = lines, keep.source = FALSE)
        unlist(lapply(seq_along(expressions), function(i) {
            code <- deparse(expressions[[i]], width.cutoff = 500L)
            label <- encodeString(sprintf("%s %03d %s", phase, i, code[[1L]]), quote = "\"")
            c(paste0(".relm_lifecycle_step('begin', ", label, ")"), code, paste0(".relm_lifecycle_step('end', ", label, ")"))
        }), use.names = FALSE)
    }
    instrumented <- instrument(body, "lifecycle")
    prelude <- c(".relm_lifecycle_started <- proc.time()", ".relm_lifecycle_step <- function(phase, label) {", "  t <- proc.time() - .relm_lifecycle_started", "  cat(sprintf('ASYNC_STAGE %s elapsed=%.3f cpu=%.3f %s\\n', phase, t[['elapsed']], t[['user.self']] + t[['sys.self']], label))", "  flush(stdout())", "}", ".relm_lifecycle_step('begin', 'load namespaces')", paste0(".libPaths(", libraries, ")"), "library(relm)", "stopifnot(requireNamespace('later'), requireNamespace('promises'))", ".relm_lifecycle_step('end', 'load namespaces')", 
        "new_fixture <- function(mode = 'success', steps = 100L, delay = 2L) {", "  m <- relm:::new_llm(relm:::relm_check(relm:::rebirth_async_test_handle()), '<fixture>')", "  relm:::relm_check(relm:::rebirth_async_test_config(m$ptr, mode, steps, delay))", "  m", "}", "observe <- function(p, diagnostic = FALSE) {", "  x <- new.env(); x$done <- FALSE; x$count <- 0L", "  observer <- promises::then(p, function(value) { x$value <- value; x$count <- x$count + 1L; x$done <- TRUE; NULL },", "    function(error) { x$error <- error; x$count <- x$count + 1L; x$done <- TRUE; NULL })", 
        "  if (diagnostic) { x$parent <- p; x$observer <- observer }", "  x", "}", "drain <- function(x, timeout = 10) {", "  started <- proc.time(); until <- started[['elapsed']] + timeout", "  samples <- transitions <- list(); previous <- NULL; polls <- 0L; max_pump <- 0", "  snapshot <- function() list(native = relm:::rebirth_async_test_stats(),", "    job_present = !is.null(relm:::.relm_async$job), done = x$done, count = x$count,", "    parent = attr(x$parent, 'promise_impl')$status(),", "    observer = attr(x$observer, 'promise_impl')$status())", 
        "  while (!x$done && proc.time()[['elapsed']] < until) {", "    before <- proc.time()[['elapsed']]; later::run_now(0.05)", "    if (!is.null(x$parent)) {", "      timing <- proc.time() - started; pump <- proc.time()[['elapsed']] - before", "      polls <- polls + 1L; max_pump <- max(max_pump, pump); state <- snapshot()", "      sample <- c(list(elapsed = timing[['elapsed']], cpu = timing[['user.self']] +", "        timing[['sys.self']], pump = pump), state)", "      samples <- tail(c(samples, list(sample)), 8L)", 
        "      if (!identical(state, previous)) transitions <- c(transitions, list(sample))", "      previous <- state", "    }", "  }", "  if (!is.null(x$parent)) {", "    timing <- proc.time() - started", "    queue <- tryCatch(lapply(getFromNamespace('list_queue', 'later')(", "      later::current_loop()), function(item) item[c('id', 'when')]), error = conditionMessage)", "    x$diagnostic <- c(list(timeout = timeout, elapsed = timing[['elapsed']],", "      cpu = timing[['user.self']] + timing[['sys.self']], polls = polls, max_pump = max_pump,", 
        "      current_loop = later::current_loop()$id, global_loop = later::global_loop()$id,", "      last_polls = samples, transitions = transitions, queue = queue,", "      R = R.version.string, later = as.character(packageVersion('later')),", "      promises = as.character(packageVersion('promises'))), snapshot())", "    cat('ASYNC_LIFECYCLE_DRAIN_DIAGNOSTIC\\n'); dput(x$diagnostic); flush(stdout())", "  }", "  stopifnot(x$done, x$count == 1L, is.null(relm:::.relm_async$job))", "}")
    preparation <- if (is.null(setup)) 
        character()
    else c(instrument(setup, "setup"), sprintf("stopifnot((proc.time() - .relm_lifecycle_started)[['elapsed']] <= %s)", setup_timeout))
    writeLines(c(prelude, preparation, ".relm_lifecycle_budget_start <- proc.time()[['elapsed']]", instrumented, sprintf("stopifnot(proc.time()[['elapsed']] - .relm_lifecycle_budget_start <= %s)", timeout), "cat('ASYNC_LIFECYCLE_OK\\n')"), script)
    status <- system2(file.path(R.home("bin"), "Rscript"), c("--vanilla", shQuote(script)), stdout = log, stderr = log, timeout = timeout + setup_timeout)
    output <- paste(readLines(log, warn = FALSE), collapse = "\n")
    if (!identical(status, 0L)) {
        dir.create("_problems", showWarnings = FALSE)
        file.copy(c(script, log), "_problems", overwrite = TRUE)
    }
    expect_equal(status, 0L, info = output)
    expect_match(output, "ASYNC_LIFECYCLE_OK", fixed = TRUE)
    expect_false(grepl("panicked at|thread.*panicked|fatal error|segmentation fault", output, ignore.case = TRUE), info = output)
    invisible(output)
}
synthetic_model_path <- function() '/Users/alessandrovadala/DOCUDESK/R-ebirth/rebirth/tests/testthat/fixtures/synthetic-llama-2l.gguf'
test_that("real synthetic models defer close and GC while a fixture owns native execution", {
    path <- normalizePath(synthetic_model_path(), mustWork = TRUE)
    literal <- paste(capture.output(dput(path)), collapse = "\n")
    setup <- c(paste0("path <- ", literal), "parent <- llm(path, backend = 'cpu', gpu_layers = 0)", "sibling <- llm_ablate(parent, layer = 1, neurons = 1)", "unrelated <- llm(path, backend = 'cpu', gpu_layers = 0)")
    async_lifecycle_process(c("worker <- new_fixture('success', 500L, 2L)", "result <- observe(llm_generate(worker, 'hold native execution', seed = 1, async = TRUE), diagnostic = TRUE)", "stopifnot(relm:::rebirth_async_test_stats()$active_jobs == 1)", "close(parent); close(parent)", "stopifnot(relm:::rebirth_async_test_stats()$deferred_handles == 1)", "rm(sibling, unrelated); gc()", "stats <- relm:::rebirth_async_test_stats()", "stopifnot(stats$active_jobs == 1, stats$deferred_handles == 3)", "drain(result); stopifnot(is.null(result$error), is.character(result$value))", 
        "stats <- relm:::rebirth_async_test_stats()", "stopifnot(stats$active_jobs == 0, stats$worker_threads == 0, stats$deferred_handles == 0)", "close(worker); rm(parent, worker); gc()"), setup = setup, setup_timeout = 90)
})
test_that("lifecycle diagnostics do not deliver callbacks after the drain deadline", {
    async_lifecycle_process(c("p <- promises::promise(function(resolve, reject) resolve('ready'))", "result <- observe(p, diagnostic = TRUE)", "err <- tryCatch(drain(result, timeout = 0), error = identity)", "stopifnot(inherits(err, 'error'), !result$done, result$count == 0L)", "stopifnot(result$diagnostic$polls == 0L, result$diagnostic$parent == 'fulfilled',", "  result$diagnostic$observer == 'pending', !result$diagnostic$done)", "drain(result); stopifnot(result$done, result$count == 1L, result$value == 'ready')"))
})
