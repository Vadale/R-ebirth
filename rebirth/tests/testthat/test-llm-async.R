# WP9. Model-free validation/controlled native worker tests run on every R PR
# matrix leg. The native fixture exercises scheduling, not LLM text quality.
# Real generation parity below is explicitly [MODEL]-gated.

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

test_that("async dependencies are present on required R CI legs", {
  expect_true(requireNamespace("later", quietly = TRUE))
  expect_true(requireNamespace("promises", quietly = TRUE))
  expect_no_error(relm:::async_check_dependencies())
})

test_that("async argument and admission failures preserve the RNG", {
  m <- stub_llm()
  set.seed(913)
  before <- .Random.seed
  for (bad in list(NA, 1, NULL, c(TRUE, FALSE))) {
    expect_error(llm_generate(m, "hi", async = bad), class = "relm_error_argument")
  }
  expect_error(llm_generate(m, "hi", on_progress = identity), class = "relm_error_argument")
  expect_error(llm_generate(m, "hi", async = TRUE, on_progress = 1), class = "relm_error_argument")
  expect_error(llm_generate(m, rep("hi", 129), async = TRUE), class = "relm_error_argument")
  expect_error(llm_generate(m, "hi", max_tokens = 8193, async = TRUE), class = "relm_error_argument")
  expect_error(llm_generate(m, "hi", temperature = Inf, async = TRUE), class = "relm_error_argument")
  expect_error(llm_generate(m, "hi", top_p = 1i, async = TRUE), class = "relm_error_argument")
  for (seed in list(Inf, 2^64, 1i, -1, NA, "x", numeric())) {
    expect_error(llm_generate(m, "hi", seed = seed, async = TRUE), class = "relm_error_argument")
  }
  local_mocked_bindings(rebirth_async_ready = function(ptr) list(ok = FALSE,
    class = "relm_error_busy", message = "Fixture busy.",
    fields = list(operation = "generate", reason = "active_job")), .package = "relm")
  expect_error(llm_generate(m, "hi", async = TRUE), class = "relm_error_busy")
  expect_identical(.Random.seed, before)
})

test_that("missing or outdated optional packages fail before admission or RNG", {
  local_mocked_bindings(
    async_package_version = function(package) NA_character_,
    rebirth_async_ready = function(ptr) stop("Admission must not run"),
    .package = "relm")
  set.seed(31)
  before <- .Random.seed
  error <- tryCatch(llm_generate(stub_llm(), "hi", async = TRUE), error = identity)
  expect_s3_class(error, "relm_error_generation")
  expect_identical(error$reason, "async_dependency")
  expect_identical(error$package, "later")
  expect_identical(error$required_version, "1.4.8")
  expect_identical(.Random.seed, before)
  local_mocked_bindings(async_package_version = function(package) "1.0.0", .package = "relm")
  old <- tryCatch(llm_generate(stub_llm(), "hi", async = TRUE), error = identity)
  expect_s3_class(old, "relm_error_generation")
  expect_identical(old$installed_version, "1.0.0")
  expect_identical(.Random.seed, before)
  # No async namespace check or admission on the ordinary generation path.
  local_mocked_bindings(rebirth_generate = function(...) list(ok = TRUE, text = "sync"),
    .package = "relm")
  expect_identical(unname(llm_generate(stub_llm(), "hi", seed = 9))[[1]], "sync")
})

test_that("async UTF-8 and aggregate limits include names stop schema and image paths", {
  validate <- function(prompt = "hi", stop = character(), schema = NULL, images = NULL) {
    relm:::async_validate_inputs(prompt, stop, schema, images, 2, 0, 1)
  }
  one_mib <- strrep("x", 1048576)
  expect_no_error(validate(one_mib))
  expect_error(validate(paste0(one_mib, "x")), class = "relm_error_argument")
  expect_error(validate(strrep("é", 524289)), class = "relm_error_argument")
  large <- strrep("x", 16777216)
  for (args in list(list(stop = large), list(schema = large),
    list(images = list(large)), list(prompt = setNames("hi", large)))) {
    expect_error(do.call(validate, args), class = "relm_error_argument")
  }
  expect_error(validate(rep(one_mib, 17)), class = "relm_error_argument")
  bytes <- "hi"
  Encoding(bytes) <- "bytes"
  # ASCII strings have no byte encoding tag in R; use a non-ASCII byte string.
  bytes <- rawToChar(as.raw(255)); Encoding(bytes) <- "bytes"
  expect_error(validate(bytes), class = "relm_error_argument")
  expect_identical(names(validate(setNames("hi", NA_character_))$prompt), NA_character_)
  count <- floor((relm:::relm_async_max_descriptor_bytes - 96) / 64)
  expect_no_error(validate(stop = rep("", count)))
  storage <- tryCatch(validate(stop = rep("", count + 1)), error = identity)
  expect_s3_class(storage, "relm_error_argument")
  expect_identical(storage$reason, "async_input_storage")
})

test_that("native async promise is responsive and services independent R heartbeats", {
  # Hold the real native worker for the same nominal two seconds with one sleep.
  # Hundreds of short relative sleeps accumulate runner scheduling delays; CI
  # observed collection at 10.136 s with the old 200 x 10 ms fixture. This case
  # tests R responsiveness, not the host's short-sleep precision. Progress and
  # cancellation have separate multi-step fixtures below. Keep every gate intact.
  m <- async_test_handle(steps = 1L, delay_ms = 2000L)
  on.exit(close(m), add = TRUE)
  beats <- 0L
  done <- FALSE
  heartbeat <- function() {
    if (done) return(invisible(NULL))
    beats <<- beats + 1L
    later::later(heartbeat, 0.05, loop = later::global_loop())
  }
  timer <- later::later(heartbeat, 0.05, loop = later::global_loop())
  on.exit({ done <- TRUE; timer() }, add = TRUE)
  started <- proc.time()[["elapsed"]]
  p <- llm_generate(m, c(first = "hello", second = "world"),
    seed = 17, max_tokens = 4, async = TRUE)
  returned <- proc.time()[["elapsed"]] - started
  expect_s3_class(p, "promise")
  expect_lt(returned, 0.25)
  result <- async_test_observe(p, diagnostic = TRUE)
  async_test_wait(result, promise = p)
  done <- TRUE
  expect_null(result$error)
  expect_gte(beats, 10L)
  expect_type(result$value, "character")
  expect_length(result$value, 2L)
  expect_identical(names(result$value), c("first", "second"))
  expect_identical(attr(result$value, "seed"), 17)
  expect_identical(result$settlements, 1L)
  expect_null(relm:::.relm_async$job)
  size <- as.numeric(object.size(result$value))
  expect_lte(size, relm:::async_result_size_bound(2,
    sum(nchar(result$value, type = "bytes")), sum(nchar(names(result$value), type = "bytes"))))
})

test_that("progress is fresh coalesced data with exactly one final snapshot", {
  m <- async_test_handle(steps = 50L, delay_ms = 5L)
  on.exit(close(m), add = TRUE)
  snapshots <- list()
  result <- async_test_observe(llm_generate(m, "hello", seed = 1, max_tokens = 4,
    async = TRUE, on_progress = function(state) {
      snapshots[[length(snapshots) + 1L]] <<- state
      state$phase <- "modified locally"
      123
    }))
  async_test_wait(result)
  expect_null(result$error)
  expect_gt(length(snapshots), 0L)
  phases <- vapply(snapshots, function(x) x$phase, character(1))
  expect_identical(tail(phases, 1L), "complete")
  expect_identical(sum(phases == "complete"), 1L)
  expect_identical(tail(snapshots, 1)[[1]]$prompts_completed, 1L)
  for (state in snapshots) {
    expect_s3_class(state, "data.frame")
    expect_identical(names(state), c("prompt_id", "prompts_completed", "prompts_total",
      "generated_tokens", "max_tokens", "phase"))
    expect_identical(vapply(state, typeof, character(1)),
      c(prompt_id = "integer", prompts_completed = "integer", prompts_total = "integer",
        generated_tokens = "integer", max_tokens = "integer", phase = "character"))
    expect_equal(nrow(state), 1)
  }
})

test_that("the omitted seed is drawn once on submission and callbacks do not draw it", {
  m <- async_test_handle()
  on.exit(close(m), add = TRUE)
  set.seed(311)
  expected <- as.double(sample.int(.Machine$integer.max, 1L))
  after <- .Random.seed
  set.seed(311)
  result <- async_test_observe(llm_generate(m, "hello", async = TRUE))
  expect_identical(.Random.seed, after)
  async_test_wait(result)
  expect_identical(attr(result$value, "seed"), expected)
  expect_identical(.Random.seed, after)
})

test_that("empty image sets remain ordinary text input", {
  m <- async_test_handle(steps = 1L, delay_ms = 1L)
  on.exit(close(m), add = TRUE)
  result <- async_test_observe(llm_generate(m, "hello", images = list(character()),
    seed = 1, async = TRUE))
  async_test_wait(result)
  expect_null(result$error)
  expect_type(result$value, "character")
})

test_that("callback cancellation and reentrancy leave one settlement and reusable handle", {
  m <- async_test_handle(steps = 100L, delay_ms = 5L)
  on.exit(close(m), add = TRUE)
  calls <- 0L
  result <- async_test_observe(llm_generate(m, "hello", seed = 1, async = TRUE,
    on_progress = function(state) {
      calls <<- calls + 1L
      if (calls == 1L) {
        expect_error(llm_generate(m, "compete", async = TRUE), class = "relm_error_busy")
        expect_true(llm_cancel(m))
        expect_false(llm_cancel(m))
        # Pumping the loop from user code cannot re-enter this job's callback.
        later::run_now(0, loop = later::global_loop())
      }
    }))
  async_test_wait(result)
  expect_s3_class(result$error, "relm_error_cancelled")
  expect_null(result$value)
  expect_identical(result$settlements, 1L)
  expect_false(llm_cancel(m))
  expect_false(m$state$closed)
  expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
})

test_that("callback failures retain the original condition and drain native work", {
  m <- async_test_handle(steps = 100L, delay_ms = 5L)
  on.exit(close(m), add = TRUE)
  parent <- simpleError("callback sentinel")
  calls <- 0L
  result <- async_test_observe(llm_generate(m, "hello", seed = 5, async = TRUE,
    on_progress = function(state) { calls <<- calls + 1L; stop(parent) }))
  async_test_wait(result)
  expect_s3_class(result$error, "relm_error_callback")
  expect_identical(result$error$parent, parent)
  expect_identical(calls, 1L)
  expect_identical(result$settlements, 1L)
  expect_null(relm:::.relm_async$job)
  expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
})

test_that("a callback failing on final completion rejects instead of resolving", {
  m <- async_test_handle(steps = 1L, delay_ms = 1L)
  on.exit(close(m), add = TRUE)
  result <- async_test_observe(llm_generate(m, "hello", seed = 1, async = TRUE,
    on_progress = function(state) if (state$phase == "complete") stop("final callback")))
  async_test_wait(result)
  expect_s3_class(result$error, "relm_error_callback")
  expect_match(conditionMessage(result$error$parent), "final callback", fixed = TRUE)
  expect_null(result$value)
  expect_identical(result$settlements, 1L)
})

test_that("native fixture errors and panics become typed promise rejections", {
  for (mode in c("error", "panic")) {
    m <- async_test_handle(mode, steps = 1L, delay_ms = 1L)
    result <- async_test_observe(llm_generate(m, "hello", seed = 7, async = TRUE))
    async_test_wait(result)
    expect_s3_class(result$error, if (mode == "panic") "relm_error_internal" else "relm_error_generation")
    expect_identical(result$settlements, 1L)
    expect_identical(m$state$closed, mode == "panic")
    expect_null(relm:::.relm_async$job)
    close(m)
  }
})

test_that("cancel validates handles and targets only the submitting handle", {
  expect_error(llm_cancel(1), class = "relm_error_argument")
  expect_error(llm_cancel(stub_llm(closed = TRUE)), class = "relm_error_closed")
  m <- async_test_handle(steps = 100L, delay_ms = 5L)
  other <- async_test_handle()
  on.exit({ close(m); close(other) }, add = TRUE)
  expect_false(llm_cancel(m))
  result <- async_test_observe(llm_generate(m, "hello", async = TRUE))
  expect_no_error(summary(m))
  expect_no_error(summary(other))
  expect_false(llm_cancel(other))
  expect_true(llm_cancel(m))
  async_test_wait(result)
  expect_s3_class(result$error, "relm_error_cancelled")
})

test_that("R handle state synchronizes after native-only close", {
  m <- async_test_handle()
  expect_false(m$state$closed)
  relm:::rebirth_handle_close(m$ptr)
  expect_error(print(m), class = "relm_error_closed")
  expect_true(m$state$closed)
  expect_error(summary(m), class = "relm_error_closed")
  expect_no_error(close(m))
})

test_that("incomplete native error payloads remain classed internal failures", {
  for (payload in list(NULL, list(), list(class = "relm_error_cancelled", message = "cancelled"))) {
    condition <- relm:::async_payload_condition(payload)
    expect_s3_class(condition, "relm_error_internal")
    expect_identical(condition$reason, "async_protocol")
  }
})

test_that("async tokenizer failures reject classed conditions without model downloads", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  result <- async_test_observe(llm_generate(m, "hello", chat = FALSE,
    seed = 1, async = TRUE))
  async_test_wait(result)
  expect_s3_class(result$error, "relm_error_tokenize")
  expect_false(m$state$closed)
})

test_that("[MODEL] async matches sync for greedy sampled stop and structured generation", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  schema <- '{"type":"object","properties":{"x":{"type":"string","enum":["yes","no"]}},"required":["x"],"additionalProperties":false}'
  for (extra in list(list(temperature = 0), list(temperature = 0.8),
    list(temperature = 0, stop = c(".", "\n")), list(temperature = 0, schema = schema))) {
    args <- c(list(m = m, prompt = c(a = "Answer yes or no.", b = "R is software."),
      max_tokens = 64, seed = 123), extra)
    expected <- do.call(llm_generate, args)
    result <- async_test_observe(do.call(llm_generate, c(args, list(async = TRUE))))
    async_test_wait(result, timeout = 120)
    expect_null(result$error)
    expect_identical(result$value, expected)
  }
})

test_that("schema compilation errors reject their existing class", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  for (schema in c("{}", "")) {
    result <- async_test_observe(llm_generate(m, "hello", chat = FALSE,
      schema = schema, seed = 1, async = TRUE))
    async_test_wait(result)
    expect_s3_class(result$error, "relm_error_schema")
    expect_true(is.character(result$error$reason))
    expect_false(m$state$closed)
  }
})

test_that("terminal callbacks may start a subsequent job without losing its roots", {
  m <- async_test_handle(steps = 1L, delay_ms = 1L)
  on.exit(close(m), add = TRUE)
  next_result <- NULL
  first <- async_test_observe(llm_generate(m, "first", seed = 1, async = TRUE,
    on_progress = function(state) {
      if (state$phase == "complete") {
        next_result <<- async_test_observe(llm_generate(m, "second", seed = 2, async = TRUE))
      }
    }))
  async_test_wait(first)
  expect_null(first$error)
  expect_true(is.environment(next_result))
  async_test_wait(next_result)
  expect_null(next_result$error)
  expect_identical(attr(next_result$value, "seed"), 2)
  expect_null(relm:::.relm_async$job)
})

test_that("repeated small success cancel and error jobs release R roots", {
  m <- async_test_handle()
  on.exit(close(m), add = TRUE)
  for (i in seq_len(100L)) {
    cancel <- i %% 3L == 0L
    mode <- if (i %% 3L == 1L) "error" else "success"
    relm:::relm_check(relm:::rebirth_async_test_config(m$ptr, mode,
      if (cancel) 100L else 1L, 1L))
    result <- async_test_observe(llm_generate(m, "hello", seed = 1, async = TRUE))
    if (cancel) expect_true(llm_cancel(m))
    async_test_wait(result)
    if (cancel) expect_s3_class(result$error, "relm_error_cancelled") else
      if (mode == "error") expect_s3_class(result$error, "relm_error_generation") else
        expect_null(result$error)
    expect_identical(result$settlements, 1L)
    expect_null(relm:::.relm_async$job)
    expect_false(m$state$closed)
    stats <- relm:::relm_check(relm:::rebirth_async_test_stats())
    for (field in c("active_jobs", "worker_threads", "deferred_handles",
      "snapshot_slots", "terminal_slots", "queued_jobs")) {
      expect_equal(stats[[field]], 0, info = field)
    }
  }
})

test_that("a stalled event loop retains one snapshot and one terminal slot", {
  m <- async_test_handle(steps = 100000L, delay_ms = 0L)
  on.exit(close(m), add = TRUE)
  result <- async_test_observe(llm_generate(m, "hello", seed = 1, async = TRUE))
  # Deliberately avoid event-loop draining while the R-free fixture publishes.
  Sys.sleep(0.5)
  stats <- relm:::relm_check(relm:::rebirth_async_test_stats())
  expect_equal(stats$active_jobs, 1)
  expect_equal(stats$snapshot_slots, 1)
  expect_lte(stats$terminal_slots, 1)
  expect_equal(stats$queued_jobs, 0)
  async_test_wait(result)
  expect_null(result$error)
})

test_that("worker startup failure rejects without leaking admission or R roots", {
  m <- async_test_handle("start_error", steps = 1L, delay_ms = 1L)
  on.exit(close(m), add = TRUE)
  result <- async_test_observe(llm_generate(m, "hello", seed = 1, async = TRUE))
  async_test_wait(result)
  expect_s3_class(result$error, "relm_error_generation")
  expect_identical(result$error$reason, "async_start")
  expect_false(m$state$closed)
  expect_null(relm:::.relm_async$job)
  expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
})

test_that("[MODEL] async preserves interventions and cancellation recovery", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  changed <- llm_ablate(m, layer = 2, neurons = 1:3)
  on.exit(close(changed), add = TRUE)
  prompt <- "The capital of Italy is"
  expected <- llm_generate(changed, prompt, max_tokens = 8, temperature = 0, seed = 7)
  result <- async_test_observe(llm_generate(changed, prompt,
    max_tokens = 8, temperature = 0, seed = 7, async = TRUE))
  async_test_wait(result, timeout = 120)
  expect_identical(result$value, expected)
  cancelled <- async_test_observe(llm_generate(changed,
    "Write a long list of numbers.", max_tokens = 512, seed = 7, async = TRUE))
  accepted <- llm_cancel(changed)
  async_test_wait(cancelled, timeout = 120)
  if (accepted) expect_s3_class(cancelled$error, "relm_error_cancelled")
  recovered <- llm_generate(changed, prompt, max_tokens = 8, temperature = 0, seed = 7)
  expect_identical(recovered, expected)
})

test_that("[MODEL] async vision matches the existing image generation path", {
  path <- path.expand(Sys.getenv("RELM_TEST_MODEL_VLM"))
  projector <- path.expand(Sys.getenv("RELM_TEST_MMPROJ_VLM"))
  skip_if_not(nzchar(path) && file.exists(path) && nzchar(projector) && file.exists(projector),
    "RELM_TEST_MODEL_VLM and RELM_TEST_MMPROJ_VLM are required")
  m <- llm(path, projector = projector)
  on.exit(close(m), add = TRUE)
  images <- vision_fixture("red-square.png")
  expected <- llm_generate(m, "What color is shown?", images = images,
    max_tokens = 8, temperature = 0, seed = 11)
  result <- async_test_observe(llm_generate(m, "What color is shown?", images = images,
    max_tokens = 8, temperature = 0, seed = 11, async = TRUE))
  async_test_wait(result, timeout = 120)
  expect_identical(result$value, expected)
})
