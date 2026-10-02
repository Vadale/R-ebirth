# WP10 transport/lifecycle gates: controlled native worker, every R CI matrix leg.
# These fixtures make no claims about real-model numerical output quality.
test_that("stream batches preserve exact schema sequence names seed and ownership phases", {
  m <- stream_test_handle(steps = 300L)
  on.exit(close(m), add = TRUE)
  batches <- list()
  phases <- character()
  set.seed(1001)
  seed <- as.double(sample.int(.Machine$integer.max, 1L))
  after <- .Random.seed
  set.seed(1001)
  result <- stream_test_observe(llm_generate(m, c(same = "a", same = "b"),
    max_tokens = 300, async = TRUE, on_token = function(batch) {
      batches[[length(batches) + 1L]] <<- batch
      expect_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)), class = "relm_error_busy")
      expect_error(llm_generate(m, "nested", async = TRUE), class = "relm_error_busy")
      before <- length(batches)
      # Direct reentry and nested event-loop dispatch must both be inert.
      relm:::async_poll(relm:::.relm_async$job)
      later::run_now(0, loop = later::global_loop())
      expect_length(batches, before)
      batch$text[] <- "local mutation"
      NULL
    }, on_progress = function(state) {
      phases <<- c(phases, state$phase)
      if (state$phase == "complete") {
        expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
        expect_gt(length(batches), 0)
      }
    }))
  expect_identical(.Random.seed, after)
  stream_test_wait(result)
  expect_null(result$error)
  expect_identical(names(result$value), c("same", "same"))
  expect_identical(attr(result$value, "seed"), seed)
  expect_identical(.Random.seed, after)
  expect_identical(result$settlements, 1L)
  expect_identical(tail(phases, 1L), "complete")
  expect_identical(sum(phases == "complete"), 1L)
  expect_gt(length(batches), 1L)
  for (batch in batches) {
    expect_identical(class(batch), "data.frame")
    expect_identical(names(batch), relm:::stream_columns)
    expect_identical(unname(vapply(batch, typeof, character(1))), relm:::stream_types)
    expect_lte(nrow(batch), 64L)
    expect_gt(nrow(batch), 0L)
    expect_lte(sum(nchar(batch$text, type = "bytes")), 65536)
    expect_lte(as.numeric(object.size(batch)), relm:::stream_batch_size_bound())
  }
  events <- do.call(rbind, batches)
  expect_identical(events$event_id, seq_len(nrow(events)))
  expect_true(all(diff(events$elapsed) >= 0))
  expect_true(all(is.na(events$validated)))
  for (i in 1:2) {
    expect_identical(stream_test_reconstruct(events, i), unname(result$value[[i]]))
    tokens <- events[events$event == "token" & events$prompt_id == i, ]
    expect_identical(tokens$token_pos, seq_len(300L))
    expect_true(all(tokens$token_id >= 1L))
    expect_equal(sum(events$event == "prompt_end" & events$prompt_id == i), 1)
  }
  expect_null(relm:::.relm_async$job)
})

test_that("CSV and callback delivery have identical deterministic event content", {
  m <- stream_test_handle("stream_text", steps = 6L)
  on.exit(close(m), add = TRUE)
  batches <- list()
  first <- stream_test_observe(llm_generate(m, "a", seed = 7, async = TRUE,
    on_token = function(batch) batches[[length(batches) + 1L]] <<- batch))
  stream_test_wait(first)
  expect_null(first$error)
  events <- do.call(rbind, batches)
  rownames(events) <- NULL
  expect_gt(length(batches), 4)
  path <- tempfile()
  con <- file(path, "wb")
  on.exit({ close(con); unlink(path) }, add = TRUE)
  second <- stream_test_observe(llm_generate(m, "a", seed = 7, async = TRUE, on_token = con))
  stream_test_wait(second)
  expect_null(second$error)
  expect_identical(second$value, first$value)
  expect_true(isOpen(con, "write"))
  observed <- stream_test_read(path)
  expect_identical(observed[names(observed) != "elapsed"], events[names(events) != "elapsed"])
  expect_identical(stream_test_reconstruct(observed, 1), first$value[[1]])
  expect_identical(sum(observed$event == "prompt_end"), 1L)
})

test_that("consumer errors and interrupts stop callbacks and return ownership without joining", {
  for (parent in list(simpleError("token callback sentinel"),
    structure(list(message = "token interrupt", call = NULL), class = c("interrupt", "condition")))) {
    m <- stream_test_handle(steps = 400L, delay_ms = 1L)
    calls <- 0L
    progresses <- 0L
    local_mocked_bindings(rebirth_async_shutdown = function() stop("must not join"), .package = "relm")
    result <- stream_test_observe(llm_generate(m, "a", seed = 5, async = TRUE,
      on_token = function(batch) { calls <<- calls + 1L; stop(parent) },
      on_progress = function(state) progresses <<- progresses + 1L))
    stream_test_wait(result)
    expect_s3_class(result$error, "relm_error_callback")
    expect_identical(result$error$callback, "on_token")
    expect_identical(result$error$parent, parent)
    expect_identical(calls, 1L)
    expect_identical(progresses, 0L)
    expect_null(result$value)
    expect_identical(result$settlements, 1L)
    expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
    close(m)
  }
})

test_that("the first progress error suppresses future token delivery", {
  m <- stream_test_handle(steps = 400L, delay_ms = 2L)
  on.exit(close(m), add = TRUE)
  tokens <- 0L
  at_failure <- NA_integer_
  parent <- simpleError("progress sentinel")
  result <- stream_test_observe(llm_generate(m, "a", seed = 1, async = TRUE,
    on_token = function(batch) tokens <<- tokens + nrow(batch),
    on_progress = function(state) { at_failure <<- tokens; stop(parent) }))
  stream_test_wait(result)
  expect_s3_class(result$error, "relm_error_callback")
  expect_identical(result$error$callback, "on_progress")
  expect_identical(result$error$parent, parent)
  expect_identical(tokens, at_failure)
  expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
})

test_that("native completion retains busy until delivery and model close abandons it", {
  m <- stream_test_handle(steps = 1L)
  on.exit(close(m), add = TRUE)
  calls <- 0L
  progress <- 0L
  result <- stream_test_observe(llm_generate(m, "a", seed = 3, async = TRUE,
    on_token = function(batch) {
      calls <<- calls + 1L
      expect_true(any(batch$event == "prompt_end"))
      expect_false(llm_cancel(m))
      expect_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)), class = "relm_error_busy")
      close(m)
    }, on_progress = function(state) progress <<- progress + 1L))
  stream_test_wait(result)
  expect_s3_class(result$error, "relm_error_cancelled")
  expect_identical(result$error$reason, "stream_closed")
  expect_identical(calls, 1L)
  expect_identical(progress, 0L)
  expect_null(result$value)
  expect_true(m$state$closed)
})

test_that("consumer error after native completion wins over close and native success", {
  m <- stream_test_handle(steps = 1L)
  on.exit(close(m), add = TRUE)
  parent <- simpleError("last batch failed")
  result <- stream_test_observe(llm_generate(m, "a", seed = 2, async = TRUE,
    on_token = function(batch) { close(m); stop(parent) }))
  stream_test_wait(result)
  expect_s3_class(result$error, "relm_error_callback")
  expect_identical(result$error$parent, parent)
})

test_that("successful final progress can close the model after stream ownership release", {
  m <- stream_test_handle(steps = 1L)
  on.exit(close(m), add = TRUE)
  result <- stream_test_observe(llm_generate(m, c(named = "a"), seed = 9, async = TRUE,
    on_token = identity, on_progress = function(state) {
      if (state$phase == "complete") close(m)
    }))
  stream_test_wait(result)
  expect_null(result$error)
  expect_identical(result$value[[1]], "fixture")
  expect_identical(names(result$value), "named")
  expect_true(m$state$closed)
})

test_that("sink closure is detected at an empty prefill poll and cannot reuse a slot", {
  m <- stream_test_handle(steps = 400L, delay_ms = 2L)
  on.exit(close(m), add = TRUE)
  path <- tempfile()
  other <- tempfile()
  con <- file(path, "wb")
  result <- stream_test_observe(llm_generate(m, "a", seed = 4, async = TRUE, on_token = con))
  original_poll <- relm:::rebirth_async_poll
  polls <- 0L
  local_mocked_bindings(rebirth_async_poll = function(ptr, job_id) {
    polls <<- polls + 1L
    if (polls == 1L) return(list(ok = TRUE, state = "running", progress = NULL,
      batch = NULL, delivery_ready = FALSE, closed = FALSE))
    original_poll(ptr, job_id)
  }, .package = "relm")
  close(con)
  replacement <- file(other, "wb")
  on.exit({ close(replacement); unlink(c(path, other)) }, add = TRUE)
  stream_test_wait(result)
  expect_s3_class(result$error, "relm_error_stream")
  expect_identical(result$error$reason, "closed")
  expect_gt(polls, 1L)
  expect_identical(file.info(other)$size, 0)
  expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
})

test_that("write and flush failure warnings preserve their parent and never retry", {
  original_write <- relm:::stream_write_bytes
  original_flush <- relm:::stream_flush
  for (operation in c("write", "flush")) {
    m <- stream_test_handle(steps = 1L)
    path <- tempfile()
    con <- file(path, "wb")
    calls <- 0L
    parent <- simpleWarning(paste(operation, "sentinel"))
    fail <- function(...) { calls <<- calls + 1L; warning(parent) }
    local_mocked_bindings(stream_write_bytes = if (operation == "write") fail else original_write,
      stream_flush = if (operation == "flush") fail else original_flush, .package = "relm")
    result <- stream_test_observe(llm_generate(m, "a", seed = 1, async = TRUE, on_token = con))
    stream_test_wait(result)
    expect_s3_class(result$error, "relm_error_stream")
    expect_identical(result$error$reason, "write")
    expect_identical(result$error$parent, parent)
    expect_identical(calls, 1L)
    expect_true(isOpen(con))
    close(con)
    close(m)
    unlink(path)
  }
})

# The no_vocab numeric fixture is covered by native raw-token parity tests.
# Public character generation needs a tokenizer, supplied by cached Qwen.
test_that("[MODEL] cached Qwen retains seeded sync async and stream equality", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
  on.exit(close(m), add = TRUE)
  prompt <- c(duplicate = "abc", duplicate = "def")
  expected <- llm_generate(m, prompt, chat = FALSE, max_tokens = 8, seed = 19)
  async <- stream_test_observe(llm_generate(m, prompt, chat = FALSE,
    max_tokens = 8, seed = 19, async = TRUE))
  stream_test_wait(async)
  batches <- list()
  stream <- stream_test_observe(llm_generate(m, prompt, chat = FALSE,
    max_tokens = 8, seed = 19, async = TRUE,
    on_token = function(batch) batches[[length(batches) + 1L]] <<- batch))
  stream_test_wait(stream)
  expect_null(stream$error)
  expect_identical(stream$value, expected)
  expect_identical(async$value, expected)
  events <- do.call(rbind, batches)
  for (i in seq_along(prompt)) {
    expect_identical(stream_test_reconstruct(events, i), expected[[i]])
  }
})

test_that("[MODEL] cached Qwen ordinary structured and CSV streams preserve results", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  schema <- paste0('{"type":"object","properties":{"answer":',
    '{"type":"string","enum":["yes","no"]}},',
    '"required":["answer"],"additionalProperties":false}')
  for (structured in c(FALSE, TRUE)) {
    supplied_schema <- if (structured) schema else NULL
    prompt <- c(answer = if (structured) "Is R a programming language?" else "The capital of Italy is")
    expected <- llm_generate(m, prompt, max_tokens = 32, temperature = 0,
      seed = 7, schema = supplied_schema)
    batches <- list()
    stream <- stream_test_observe(llm_generate(m, prompt, max_tokens = 32,
      temperature = 0, seed = 7, schema = supplied_schema, async = TRUE,
      on_token = function(batch) batches[[length(batches) + 1L]] <<- batch))
    stream_test_wait(stream, timeout = 120)
    expect_null(stream$error)
    expect_identical(stream$value, expected)
    events <- do.call(rbind, batches)
    rownames(events) <- NULL
    expect_identical(stream_test_reconstruct(events, 1L), expected[[1]])
    if (structured) expect_identical(events$validated, events$event == "prompt_end")
    path <- tempfile()
    con <- file(path, "wb")
    csv <- stream_test_observe(llm_generate(m, prompt, max_tokens = 32,
      temperature = 0, seed = 7, schema = supplied_schema, async = TRUE, on_token = con))
    stream_test_wait(csv, timeout = 120)
    observed <- stream_test_read(path)
    close(con)
    unlink(path)
    expect_null(csv$error)
    expect_identical(csv$value, expected)
    expect_identical(observed[names(observed) != "elapsed"], events[names(events) != "elapsed"])
  }
})

test_that("[MODEL] cached vision over-batch prefill retains streaming parity", {
  path <- path.expand(Sys.getenv("RELM_TEST_MODEL_VLM"))
  projector <- path.expand(Sys.getenv("RELM_TEST_MMPROJ_VLM"))
  skip_if_not(nzchar(path) && file.exists(path) && nzchar(projector) && file.exists(projector),
    "RELM_TEST_MODEL_VLM and RELM_TEST_MMPROJ_VLM are required")
  m <- llm(path, projector = projector, context_length = 4096)
  on.exit(close(m), add = TRUE)
  prompt <- paste0(strrep("word ", 600), "What color is shown?")
  expect_gt(length(llm_tokens(m, prompt)), 512)
  images <- vision_fixture("red-square.png")
  expected <- llm_generate(m, prompt, images = images, max_tokens = 4,
    temperature = 0, seed = 11)
  batches <- list()
  stream <- stream_test_observe(llm_generate(m, prompt, images = images,
    max_tokens = 4, temperature = 0, seed = 11, async = TRUE,
    on_token = function(batch) batches[[length(batches) + 1L]] <<- batch))
  stream_test_wait(stream, timeout = 120)
  expect_null(stream$error)
  expect_identical(stream$value, expected)
  expect_identical(stream_test_reconstruct(do.call(rbind, batches), 1L), expected[[1]])
})

test_that("native failure discards queued rows and encoding rejection remains classed", {
  for (mode in c("error", "panic", "stream_encoding")) {
    m <- stream_test_handle(mode, steps = 1L)
    calls <- 0L
    result <- stream_test_observe(llm_generate(m, "a", seed = 1, async = TRUE,
      on_token = function(batch) calls <<- calls + 1L))
    stream_test_wait(result)
    expect_s3_class(result$error, if (mode == "stream_encoding") "relm_error_stream" else "relm_error")
    if (mode == "stream_encoding") expect_identical(result$error$reason, "encoding")
    expect_null(result$value)
    expect_identical(calls, 0L)
    expect_identical(result$settlements, 1L)
    close(m)
  }
})

test_that("a partial CSV write or final flush failure rejects without final progress", {
  original_write <- relm:::stream_write_bytes
  original_flush <- relm:::stream_flush
  for (operation in c("partial_write", "final_flush")) {
    m <- stream_test_handle(steps = 1L)
    path <- tempfile()
    con <- file(path, "wb")
    writes <- 0L
    flushes <- 0L
    completed <- FALSE
    parent <- simpleError(operation)
    local_mocked_bindings(stream_write_bytes = function(bytes, con) {
      writes <<- writes + 1L
      if (operation == "partial_write" && writes == 2L) {
        original_write(bytes[seq_len(10L)], con)
        original_flush(con)
        stop(parent)
      }
      original_write(bytes, con)
    }, stream_flush = function(con) {
      flushes <<- flushes + 1L
      if (operation == "final_flush" && flushes == 3L) stop(parent)
      original_flush(con)
    }, .package = "relm")
    result <- stream_test_observe(llm_generate(m, "a", seed = 1, async = TRUE,
      on_token = con, on_progress = function(state) {
        if (state$phase == "complete") completed <<- TRUE
      }))
    stream_test_wait(result)
    expect_s3_class(result$error, "relm_error_stream")
    expect_identical(result$error$parent, parent)
    expect_false(completed)
    expect_null(result$value)
    expect_gt(file.info(path)$size, length(relm:::stream_csv_bytes()))
    expect_true(isOpen(con))
    expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
    close(con)
    close(m)
    unlink(path)
  }
})

test_that("FFI representation failure follows nonblocking cancellation and preserves its condition", {
  m <- stream_test_handle(steps = 400L, delay_ms = 1L)
  on.exit(close(m), add = TRUE)
  poll <- relm:::rebirth_async_poll
  calls <- 0L
  parent <- relm:::stream_condition("encoding", "Fixture representation failure.",
    prompt_id = 1L, event_id = 1L)
  local_mocked_bindings(rebirth_async_poll = function(ptr, job_id) {
    calls <<- calls + 1L
    if (calls == 1L) stop(parent)
    poll(ptr, job_id)
  }, rebirth_async_shutdown = function() stop("must not join"), .package = "relm")
  tokens <- 0L
  result <- stream_test_observe(llm_generate(m, "a", seed = 1, async = TRUE,
    on_token = function(batch) tokens <<- tokens + nrow(batch)))
  stream_test_wait(result)
  expect_identical(result$error, parent)
  expect_identical(tokens, 0L)
  expect_gt(calls, 1L)
  expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
})

test_that("structured fixture rows stay provisional until each prompt ends", {
  m <- stream_test_handle(steps = 1L)
  on.exit(close(m), add = TRUE)
  batches <- list()
  schema <- '{"type":"object","properties":{},"required":[],"additionalProperties":false}'
  result <- stream_test_observe(llm_generate(m, c("a", "b"), schema = schema, seed = 4,
    async = TRUE, on_token = function(batch) batches[[length(batches) + 1L]] <<- batch))
  stream_test_wait(result)
  expect_null(result$error)
  events <- do.call(rbind, batches)
  expect_identical(events$validated, events$event == "prompt_end")
  expect_identical(events$prompt_id[events$validated], 1:2)
})
