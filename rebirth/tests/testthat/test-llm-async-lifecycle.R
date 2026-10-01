# WP9 lifecycle gates: run in fresh Rscript processes on every R PR matrix leg.
# Controlled-worker and synthetic-model tests need no download or additional
# process package. The cached-Qwen ownership test is explicitly [MODEL]-gated.
# Child-process exit/panic-output assertions complement native drop counters.

async_lifecycle_process <- function(body, timeout = 30) {
  script <- tempfile(fileext = ".R")
  log <- tempfile(fileext = ".log")
  on.exit(unlink(c(script, log)), add = TRUE)
  libraries <- paste(capture.output(dput(.libPaths())), collapse = "\n")
  # Keep the existing deadline and assertions. Per-expression timing identifies
  # whether a remote timeout is in model setup, deferred destruction or draining.
  expressions <- parse(text = body, keep.source = FALSE)
  instrumented <- unlist(lapply(seq_along(expressions), function(i) {
    code <- deparse(expressions[[i]], width.cutoff = 500L)
    label <- encodeString(sprintf("%03d %s", i, code[[1L]]), quote = '"')
    c(paste0(".relm_lifecycle_step('begin', ", label, ")"), code,
      paste0(".relm_lifecycle_step('end', ", label, ")"))
  }), use.names = FALSE)
  prelude <- c(
    ".relm_lifecycle_started <- proc.time()",
    ".relm_lifecycle_step <- function(phase, label) {",
    "  t <- proc.time() - .relm_lifecycle_started",
    "  cat(sprintf('ASYNC_STAGE %s elapsed=%.3f cpu=%.3f %s\\n', phase, t[['elapsed']], t[['user.self']] + t[['sys.self']], label))",
    "  flush(stdout())",
    "}",
    ".relm_lifecycle_step('begin', 'load namespaces')",
    paste0(".libPaths(", libraries, ")"),
    "library(relm)", "stopifnot(requireNamespace('later'), requireNamespace('promises'))",
    ".relm_lifecycle_step('end', 'load namespaces')",
    "new_fixture <- function(mode = 'success', steps = 100L, delay = 2L) {",
    "  m <- relm:::new_llm(relm:::relm_check(relm:::rebirth_async_test_handle()), '<fixture>')",
    "  relm:::relm_check(relm:::rebirth_async_test_config(m$ptr, mode, steps, delay))",
    "  m",
    "}",
    "observe <- function(p) {",
    "  x <- new.env(); x$done <- FALSE; x$count <- 0L",
    "  promises::then(p, function(value) { x$value <- value; x$count <- x$count + 1L; x$done <- TRUE; NULL },",
    "    function(error) { x$error <- error; x$count <- x$count + 1L; x$done <- TRUE; NULL })",
    "  x",
    "}",
    "drain <- function(x, timeout = 10) {",
    "  until <- proc.time()[['elapsed']] + timeout",
    "  while (!x$done && proc.time()[['elapsed']] < until) later::run_now(0.05)",
    "  stopifnot(x$done, x$count == 1L, is.null(relm:::.relm_async$job))",
    "}")
  writeLines(c(prelude, instrumented, "cat('ASYNC_LIFECYCLE_OK\\n')"), script)
  status <- system2(file.path(R.home("bin"), "Rscript"),
    c("--vanilla", shQuote(script)), stdout = log, stderr = log, timeout = timeout)
  output <- paste(readLines(log, warn = FALSE), collapse = "\n")
  if (!identical(status, 0L)) {
    # R CMD check artifacts retain these even after its temporary child exits.
    dir.create("_problems", showWarnings = FALSE)
    file.copy(c(script, log), "_problems", overwrite = TRUE)
  }
  expect_equal(status, 0L, info = output)
  expect_match(output, "ASYNC_LIFECYCLE_OK", fixed = TRUE)
  expect_false(grepl("panicked at|thread.*panicked|fatal error|segmentation fault", output,
    ignore.case = TRUE), info = output)
  invisible(output)
}

test_that("close and forced GC during a native job are safe in a fresh process", {
  async_lifecycle_process(c(
    "m <- new_fixture(); sibling <- new_fixture()",
    "result <- observe(llm_generate(m, 'hello', seed = 1, async = TRUE))",
    "close(sibling); close(sibling); rm(sibling); gc()",
    "close(m); close(m)",
    "stopifnot(m$state$closed)",
    "drain(result)",
    "stopifnot(inherits(result$error, 'relm_error_cancelled'))",
    "rm(m); gc()"
  ))
})

test_that("pending job roots survive dropped model and promise references", {
  async_lifecycle_process(c(
    "m <- new_fixture()",
    "result <- observe(llm_generate(m, 'hello', seed = 1, async = TRUE))",
    "rm(m); gc()",
    "drain(result); stopifnot(is.character(result$value), is.null(result$error))",
    "m <- new_fixture()",
    "llm_generate(m, 'unobserved success', seed = 1, async = TRUE)",
    "rm(m); gc()",
    "until <- proc.time()[['elapsed']] + 10",
    "while (!is.null(relm:::.relm_async$job) && proc.time()[['elapsed']] < until) later::run_now(0.05)",
    "stopifnot(is.null(relm:::.relm_async$job)); gc()"
  ))
})

test_that("normal failures cancel and panic release native ownership in subprocesses", {
  async_lifecycle_process(c(
    "for (mode in c('error', 'panic')) {",
    "  m <- new_fixture(mode, 1L, 1L)",
    "  result <- observe(llm_generate(m, 'hello', seed = 1, async = TRUE))",
    "  drain(result)",
    "  stopifnot(inherits(result$error, if (mode == 'panic') 'relm_error_internal' else 'relm_error_generation'))",
    "  stopifnot(identical(m$state$closed, mode == 'panic')); close(m)",
    "}",
    "m <- new_fixture('success', 2L, 1L)",
    "result <- observe(llm_generate(m, 'recovery', seed = 1, async = TRUE))",
    "drain(result); stopifnot(is.null(result$error)); close(m)"
  ))
})

test_that("namespace shutdown joins work and retains the DLL for live finalizers", {
  async_lifecycle_process(c(
    "m <- new_fixture('success', 1000L, 2L)",
    "other <- new_fixture()",
    "close_handle <- getS3method('close', 'llm')",
    "print_handle <- getS3method('print', 'llm')",
    "summary_handle <- getS3method('summary', 'llm')",
    "stats_fn <- relm:::rebirth_async_test_stats",
    "dll_path <- getLoadedDLLs()[['relm']][['path']]",
    "calls <- 0L",
    "result <- observe(llm_generate(m, 'hello', seed = 1, async = TRUE,",
    "  on_progress = function(state) calls <<- calls + 1L))",
    "detach('package:relm'); unloadNamespace('relm')",
    "stopifnot(!('relm' %in% loadedNamespaces()))",
    "stopifnot(identical(getLoadedDLLs()[['relm']][['path']], dll_path))",
    "stats <- stats_fn()",
    "stopifnot(stats$ok, stats$active_jobs == 0, stats$worker_threads == 0, stats$deferred_handles == 0,",
    "  stats$snapshot_slots == 0, stats$terminal_slots == 0, stats$queued_jobs == 0)",
    "later::run_now(0.1)",
    "stopifnot(calls == 0L, result$done, inherits(result$error, 'relm_error_cancelled'))",
    "stopifnot(inherits(tryCatch(print_handle(other), error = identity), 'relm_error_closed'))",
    "stopifnot(other$state$closed, inherits(tryCatch(summary_handle(other), error = identity), 'relm_error_closed'))",
    "close_handle(m); close_handle(m); close_handle(other); rm(m, other); gc()"
  ))
})

test_that("real synthetic models defer close and GC while a fixture owns native execution", {
  path <- normalizePath(synthetic_model_path(), mustWork = TRUE)
  literal <- paste(capture.output(dput(path)), collapse = "\n")
  async_lifecycle_process(c(
    paste0("path <- ", literal),
    "parent <- llm(path, backend = 'cpu', gpu_layers = 0)",
    "sibling <- llm_ablate(parent, layer = 1, neurons = 1)",
    "unrelated <- llm(path, backend = 'cpu', gpu_layers = 0)",
    "worker <- new_fixture('success', 500L, 2L)",
    "result <- observe(llm_generate(worker, 'hold native execution', seed = 1, async = TRUE))",
    "stopifnot(relm:::rebirth_async_test_stats()$active_jobs == 1)",
    "close(parent); close(parent)",
    "stopifnot(relm:::rebirth_async_test_stats()$deferred_handles == 1)",
    "rm(sibling, unrelated); gc()",
    "stats <- relm:::rebirth_async_test_stats()",
    "stopifnot(stats$active_jobs == 1, stats$deferred_handles == 3)",
    "drain(result); stopifnot(is.null(result$error), is.character(result$value))",
    "stats <- relm:::rebirth_async_test_stats()",
    "stopifnot(stats$active_jobs == 0, stats$worker_threads == 0, stats$deferred_handles == 0)",
    "close(worker); rm(parent, worker); gc()"
  ))
})

test_that("[MODEL] derived Qwen ownership survives parent sibling and unrelated close or GC", {
  qwen <- normalizePath(qwen_model_path(), mustWork = TRUE)
  tiny <- normalizePath(synthetic_model_path(), mustWork = TRUE)
  literal <- function(path) paste(capture.output(dput(path)), collapse = "\n")
  async_lifecycle_process(c(
    paste0("qwen_path <- ", literal(qwen)),
    paste0("tiny_path <- ", literal(tiny)),
    "parent <- llm(qwen_path, context_length = 2048, backend = 'cpu', gpu_layers = 0)",
    "owner <- llm_ablate(parent, layer = 2, neurons = 1)",
    "sibling <- llm_ablate(parent, layer = 2, neurons = 2)",
    "unrelated <- llm(tiny_path, backend = 'cpu', gpu_layers = 0)",
    "prompt <- paste(rep('This sentence supplies a deterministic prefill workload.', 80), collapse = ' ')",
    "result <- observe(llm_generate(owner, prompt, chat = FALSE, max_tokens = 64,",
    "  temperature = 0, seed = 7, async = TRUE))",
    "stopifnot(relm:::rebirth_async_test_stats()$active_jobs == 1)",
    "close(parent); rm(sibling, unrelated); gc()",
    "stats <- relm:::rebirth_async_test_stats()",
    "stopifnot(stats$active_jobs == 1, stats$deferred_handles == 3)",
    "accepted <- llm_cancel(owner)",
    "close(owner); close(owner); rm(owner, parent); gc()",
    "drain(result, timeout = 90)",
    "if (accepted) stopifnot(inherits(result$error, 'relm_error_cancelled')) else",
    "  stopifnot(is.null(result$error), is.character(result$value))",
    "stats <- relm:::rebirth_async_test_stats()",
    "stopifnot(stats$active_jobs == 0, stats$worker_threads == 0, stats$deferred_handles == 0,",
    "  stats$snapshot_slots == 0, stats$terminal_slots == 0, stats$queued_jobs == 0)",
    "recovery <- llm(tiny_path, backend = 'cpu', gpu_layers = 0); close(recovery); gc()"
  ), timeout = 120)
})

test_that("foreign external pointers fail safely before an extendr downcast", {
  async_lifecycle_process(c(
    "foreign <- getDLLRegisteredRoutines('stats')$.Call[[1]]$address",
    "stopifnot(typeof(foreign) == 'externalptr')",
    "for (ptr in list(foreign, new('externalptr'), NULL)) {",
    "  for (fun in list(relm:::rebirth_async_ready, relm:::rebirth_async_cancel)) {",
    "    payload <- fun(ptr)",
    "    stopifnot(identical(payload$ok, FALSE), identical(payload$class, 'relm_error_closed'))",
    "  }",
    "  relm:::rebirth_handle_close(ptr)",
    "}",
    "gc()"
  ))
})

test_that("session exit joins an active job without an event-loop drain", {
  async_lifecycle_process(c(
    "m <- new_fixture('success', 1000L, 2L)",
    "llm_generate(m, 'exit with pending worker', seed = 1, async = TRUE)",
    "rm(m); gc()"
  ))
})
