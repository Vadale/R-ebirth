# Shared async test helpers: ordinary model-free CI and the real VLM gate.
# No model is loaded until a test explicitly calls these helpers.

async_test_handle <- function(mode = "success", steps = 20L, delay_ms = 10L) {
  m <- relm:::new_llm(relm:::relm_check(relm:::rebirth_async_test_handle()),
    "<async-controlled-fixture>")
  relm:::relm_check(relm:::rebirth_async_test_config(m$ptr, mode, steps, delay_ms))
  m
}

async_test_observe <- function(promise, diagnostic = FALSE) {
  result <- new.env(parent = emptyenv())
  result$done <- FALSE
  result$value <- NULL
  result$error <- NULL
  result$settlements <- 0L
  observer <- promises::then(promise, onFulfilled = function(value) {
    result$value <- value
    result$settlements <- result$settlements + 1L
    result$done <- TRUE
    NULL
  }, onRejected = function(error) {
    result$error <- error
    result$settlements <- result$settlements + 1L
    result$done <- TRUE
    NULL
  })
  if (diagnostic) result$observer <- observer
  result
}

async_test_wait <- function(result, timeout = 10, promise = NULL) {
  started <- proc.time()
  wall_started <- Sys.time()
  deadline <- unname(started[["elapsed"]]) + timeout
  # A collected native result can still have an undelivered promise continuation.
  # Record the boundary without pumping extra callbacks or extending the gate.
  samples <- transitions <- list()
  last_state <- NULL
  polls <- 0L
  max_poll_seconds <- 0
  while (!result$done && unname(proc.time()[["elapsed"]]) < deadline) {
    before <- proc.time()[["elapsed"]]
    later::run_now(0.05, loop = later::global_loop())
    if (!is.null(promise)) {
      timing <- proc.time() - started
      poll_seconds <- proc.time()[["elapsed"]] - before
      polls <- polls + 1L
      max_poll_seconds <- max(max_poll_seconds, poll_seconds)
      state <- list(job_present = !is.null(relm:::.relm_async$job),
        promise = attr(promise, "promise_impl")$status(), observed = result$done)
      sample <- c(list(elapsed = unname(timing[["elapsed"]]),
        cpu = unname(timing[["user.self"]] + timing[["sys.self"]]),
        poll_seconds = unname(poll_seconds)), state)
      samples <- tail(c(samples, list(sample)), 8L)
      if (!identical(state, last_state)) transitions <- c(transitions, list(sample))
      last_state <- state
    }
  }
  if (!is.null(promise)) {
    # Read-only internal diagnostics for the pinned later/promises versions.
    # A missing diagnostic interface is recorded, not made into another failure.
    queue <- tryCatch(lapply(getFromNamespace("list_queue", "later")(
      later::global_loop()), function(x) x[c("id", "when")]), error = conditionMessage)
    receipt <- list(timeout = timeout, elapsed = unname(proc.time()[["elapsed"]] -
      started[["elapsed"]]), wall_seconds = as.numeric(difftime(Sys.time(),
      wall_started, units = "secs")), polls = polls, max_poll_seconds = max_poll_seconds,
      current_loop = later::current_loop()$id, global_loop = later::global_loop()$id,
      transitions = transitions, last_polls = samples, queue_at_boundary = queue,
      native = relm:::rebirth_async_test_stats(), observer_done = result$done,
      R = R.version.string, later = as.character(packageVersion("later")),
      promises = as.character(packageVersion("promises")),
      testthat = as.character(packageVersion("testthat")),
      parent_status = attr(promise, "promise_impl")$status(),
      observer_status = if (is.null(result$observer)) NULL else
        attr(result$observer, "promise_impl")$status())
    dir.create("_diagnostics", showWarnings = FALSE)
    dput(receipt, file = "_diagnostics/async-responsiveness.txt")
    cat("ASYNC_RESPONSIVENESS_DIAGNOSTIC\n")
    dput(receipt)
  }
  diagnostic <- "async promise did not settle before test timeout"
  if (!result$done) {
    # Distinguish a still-running worker from a terminal result whose R callback
    # was not delivered. Read-only counters do not collect or cancel the job.
    counters <- relm:::rebirth_async_test_stats()
    diagnostic <- paste(diagnostic,
      paste(capture.output(str(counters)), collapse = "\n"), sep = "\n")
  }
  expect_true(result$done, info = diagnostic)
  invisible(result)
}

