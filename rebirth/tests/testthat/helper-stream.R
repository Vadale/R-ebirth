# WP10 controlled-worker helpers. All fixture tests run on every R CI matrix leg;
# tests marked [MODEL] require the existing cached model environment variables.
stream_test_handle <- function(mode = "success", steps = 6L, delay_ms = 0L) {
  m <- relm:::new_llm(relm:::relm_check(relm:::rebirth_async_test_handle()),
    "<stream-controlled-fixture>")
  relm:::relm_check(relm:::rebirth_async_test_config(m$ptr, mode, steps, delay_ms))
  m
}

stream_test_observe <- function(promise) {
  result <- new.env(parent = emptyenv())
  result$done <- FALSE
  result$value <- result$error <- NULL
  result$settlements <- 0L
  promises::then(promise, onFulfilled = function(value) {
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
  result
}

stream_test_wait <- function(result, timeout = 10) {
  deadline <- unname(proc.time()[["elapsed"]]) + timeout
  while (!result$done && unname(proc.time()[["elapsed"]]) < deadline) {
    later::run_now(0.05, loop = later::global_loop())
  }
  expect_true(result$done, info = "Stream promise exceeded the test deadline.")
  invisible(result)
}

stream_test_read <- function(path) read.csv(path, fileEncoding = "UTF-8",
  check.names = FALSE, na.strings = character(),
  colClasses = c("integer", "character", "integer", "integer", "integer",
    "character", "numeric", "character", "logical"))

stream_test_batch <- function() data.frame(
  event_id = 1:3, event = c("token", "text", "prompt_end"),
  prompt_id = rep(1L, 3), token_pos = c(1L, NA_integer_, NA_integer_),
  token_id = c(3L, NA_integer_, NA_integer_), text = c("", "hello", ""),
  elapsed = c(0, 0.12345678901234567, 1), finish_reason = c("", "", "length"),
  validated = rep(NA, 3), stringsAsFactors = FALSE)

stream_test_job <- function(structured = FALSE) {
  job <- new.env(parent = emptyenv())
  job$stream_event_id <- 0L
  job$stream_elapsed <- 0
  job$stream_prompt_id <- 1L
  job$stream_token_pos <- 0L
  job$prompts_total <- 1L
  job$structured <- structured
  job
}

stream_test_reconstruct <- function(events, prompt_id) {
  paste0(events$text[events$event == "text" & events$prompt_id == prompt_id], collapse = "")
}
