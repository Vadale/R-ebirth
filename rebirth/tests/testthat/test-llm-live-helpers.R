# F6a pure-R payload and callback boundaries: every R CMD check CI leg.
# No model or worker is created; mocked acknowledgement records causal order.

live_test_payload <- function() {
  list(step = data.frame(state_id = 1L, prompt_id = 1L, token_pos = 1L,
    token_id = 4L, context_pos = 4L, source_pos = 3L, source = "prompt",
    elapsed = 0.25, steering_revision = 0L, applied_after_state = 0L,
    effective_source_pos = 1L, stringsAsFactors = FALSE), prompt_token_count = 3L,
    steering = data.frame(intervention = integer(), layer = integer(), coef = double()),
    logits = data.frame(prompt_id = 1L, rank = 1L, token_id = 4L, token = "x",
      logit = 1.25, prob = 0.2, stringsAsFactors = FALSE),
    trace = list(spilled = FALSE, prompt_id = integer(), token_pos = integer(),
      token_levels = character(), token_codes = integer(), row_nneuron = integer(),
      layer = integer(), component_levels = character(), component_codes = integer(),
      neuron = integer(), value = double()))
}

live_test_job <- function(callback = function(state) invisible(NULL)) {
  job <- new.env(parent = emptyenv())
  job$id <- "live-job-fixture"
  job$model <- stub_llm()
  job$live <- list(prompt = c(input = "abc"), callback = callback,
    layers = integer(), components = "residual", top = 1L,
    original_steering = data.frame(intervention = integer(), layer = integer(), coef = double()))
  job$live_state_id <- 0L
  job$live_elapsed <- 0
  job$live_prompt_count <- NULL
  job$callback_error <- NULL
  job
}

test_that("empty live payload tables preserve their declared base-R schemas", {
  logits <- relm:::live_empty_logits()
  expect_identical(class(logits), "data.frame")
  expect_identical(names(logits), c("prompt_id", "rank", "token_id", "token", "logit", "prob"))
  expect_identical(unname(vapply(logits, typeof, character(1))),
    c("integer", "integer", "integer", "character", "double", "double"))
  expect_identical(nrow(logits), 0L)
  trace <- relm:::live_empty_trace(stub_llm(), c(input = "abc"))
  expect_identical(class(trace), c("relm_trace", "data.frame"))
  expect_identical(names(trace), c("prompt_id", "token_pos", "token", "layer",
    "component", "neuron", "value"))
  expect_identical(unname(vapply(trace, typeof, character(1))),
    c("integer", "integer", "character", "integer", "character", "integer", "double"))
  expect_identical(nrow(trace), 0L)
  expect_false(attr(trace, "spilled"))
  expect_identical(attr(trace, "position_space"), "model_context")
  expect_identical(attr(trace, "prompts"), c(input = "abc"))
  step <- relm:::live_empty_step()
  expect_identical(class(step), "data.frame")
  expect_identical(names(step), c("state_id", "prompt_id", "token_pos", "token_id",
    "context_pos", "source_pos", "source", "elapsed",
    "steering_revision", "applied_after_state", "effective_source_pos"))
  expect_identical(unname(vapply(step, typeof, character(1))),
    c(rep("integer", 6), "character", "double", rep("integer", 3)))
})

test_that("live payload source coordinates are checked before sequence advances", {
  job <- live_test_job()
  first <- relm:::live_payload_state(job, live_test_payload())
  expect_identical(names(first), c("step", "logits", "trace"))
  expect_identical(job$live_state_id, 1L)
  expect_identical(job$live_prompt_count, 3L)
  expect_identical(attr(first$trace, "prompt_token_count"), 3L)
  expect_identical(attr(first$trace, "state_id"), 1L)
  second <- live_test_payload()
  second$step$state_id <- second$step$token_pos <- 2L
  second$step$source_pos <- 4L
  second$step$context_pos <- 5L
  second$step$source <- "generated"
  second$step$elapsed <- 0.5
  expect_no_error(relm:::live_payload_state(job, second))
  expect_identical(job$live_state_id, 2L)
  changed_prompt <- second
  changed_prompt$step$state_id <- changed_prompt$step$token_pos <- 3L
  changed_prompt$prompt_token_count <- 4L
  changed_prompt$step$source_pos <- 6L
  changed_prompt$step$context_pos <- 7L
  expect_error(relm:::live_payload_state(job, changed_prompt), class = "relm_error_internal")
  # Replay/double delivery cannot be accepted after sequence advancement.
  expect_error(relm:::live_payload_state(job, second), class = "relm_error_internal")
  changes <- list(
    function(x) { x$step$source_pos <- 2L; x },
    function(x) { x$step$context_pos <- 5L; x },
    function(x) { x$step$state_id <- 2L; x },
    function(x) { x$step$token_pos <- 2L; x },
    function(x) { x$step$prompt_id <- 2L; x },
    function(x) { x$step$token_id <- 0L; x },
    function(x) { x$step$token_id <- 4; x },
    function(x) { x$step$source <- "generated"; x },
    function(x) { x$step$elapsed <- Inf; x },
    function(x) { x$step$elapsed <- -1; x },
    function(x) { x$prompt_token_count <- 4L; x },
    function(x) { x$prompt_token_count <- 3; x },
    function(x) { x$prompt_token_count <- NA_integer_; x },
    function(x) { x$step <- x$step[rev(names(x$step))]; x })
  for (change in changes) {
    fresh <- live_test_job()
    error <- tryCatch(relm:::live_payload_state(fresh, change(live_test_payload())),
      error = identity)
    expect_s3_class(error, "relm_error_internal")
    expect_identical(error$reason, "live_protocol")
    expect_identical(fresh$live_state_id, 0L)
  }
  late <- live_test_job()
  late$live_elapsed <- 0.5
  expect_error(relm:::live_payload_state(late, live_test_payload()),
    class = "relm_error_internal")
})

test_that("live callbacks acknowledge only after successful NULL completion", {
  order <- character()
  local_mocked_bindings(rebirth_async_state_ack = function(ptr, job_id, state_id, updates) {
    expect_identical(job_id, "live-job-fixture")
    expect_identical(state_id, 1L)
    order <<- c(order, "ack")
    list(ok = TRUE)
  }, .package = "relm")
  job <- live_test_job(function(state) {
    expect_identical(order, character())
    expect_identical(state$step$source_pos, 3L)
    order <<- c(order, "callback")
    invisible(NULL)
  })
  relm:::live_deliver(job, live_test_payload())
  expect_identical(order, c("callback", "ack"))
  expect_null(job$callback_error)
})

test_that("live worker steering audits reject inconsistent revisions before advancing", {
  prepare <- function() {
    job <- live_test_job()
    job$model$interventions <- list(list(kind = "steer", layer = 2L, coef = 0,
      direction = c(0.25, -0.25)))
    payload <- live_test_payload()
    payload$steering <- data.frame(intervention = 1L, layer = 2L, coef = 0)
    job$live$original_steering <- payload$steering
    first <- relm:::live_payload_state(job, payload)
    expect_identical(attr(first, "steering"), payload$steering)
    list(job = job, payload = payload)
  }
  initial <- prepare()
  changed <- initial$payload
  changed$step$state_id <- changed$step$token_pos <- 2L
  changed$step$source_pos <- 4L
  changed$step$context_pos <- 5L
  changed$step$source <- "generated"
  changed$step$elapsed <- 0.5
  changed$step$steering_revision <- 1L
  changed$step$applied_after_state <- 1L
  changed$step$effective_source_pos <- 4L
  changed$steering$coef <- 0.5
  changes <- list(
    function(x) { x$step$steering_revision <- 0L; x },
    function(x) { x$step$steering_revision <- 2L; x },
    function(x) { x$step$applied_after_state <- 0L; x },
    function(x) { x$step$effective_source_pos <- 3L; x },
    function(x) { x$steering$coef <- 0; x },
    function(x) { x$steering$coef <- Inf; x },
    function(x) { x$steering$intervention <- 2L; x },
    function(x) { x$steering$layer <- 3L; x })
  for (change in changes) {
    fresh <- prepare()
    expect_error(relm:::live_payload_state(fresh$job, change(changed)),
      class = "relm_error_internal")
    expect_identical(fresh$job$live_state_id, 1L)
    expect_identical(fresh$job$live_audit$revision, 0L)
  }
  expect_no_error(relm:::live_payload_state(initial$job, changed))
  unchanged <- changed
  unchanged$step$state_id <- unchanged$step$token_pos <- 3L
  unchanged$step$source_pos <- 5L
  unchanged$step$context_pos <- 6L
  unchanged$step$elapsed <- 0.75
  expect_no_error(relm:::live_payload_state(initial$job, unchanged))
  expect_identical(initial$job$live_audit$after, 1L)
  expect_identical(initial$job$live_audit$position, 4L)
})

test_that("live delivery uses its admitted audit and bounds reply rows by steer count", {
  metadata <- c(rep(list(list(kind = "ablate")), 1000L),
    list(list(kind = "steer", layer = 2L, coef = 0)))
  cached <- data.frame(intervention = 1001L, layer = 2L, coef = 0)
  expect_identical(relm:::live_steering_table(metadata), cached)
  expect_identical(nrow(relm:::live_steering_table(metadata[-1001L])), 0L)
  reply <- list(steer = data.frame(intervention = 1001L, coef = 0.5))
  expect_identical(relm:::live_reply(reply,
    interventions = stop("original metadata must remain unforced"), steering = cached),
    reply$steer)
  oversized <- list(steer = data.frame(intervention = c(1001L, 1002L), coef = c(0.5, 0)))
  expect_error(relm:::live_reply(oversized,
    interventions = stop("original metadata must remain unforced"), steering = cached),
    class = "relm_error_argument")
  job <- live_test_job()
  # An ablation-only model must not cause an all-intervention scan per state.
  job$model$interventions <- rep(list(list(kind = "ablate")), 1000L)
  local_mocked_bindings(live_steering_table = function(...) stop("unexpected rescan"),
    .package = "relm")
  expect_no_error(relm:::live_payload_state(job, live_test_payload()))
})

test_that("live callback and reply failures preserve class and original parent", {
  acknowledgements <- 0L
  local_mocked_bindings(rebirth_async_state_ack = function(...) {
    acknowledgements <<- acknowledgements + 1L
    list(ok = TRUE)
  }, async_consumer_failure = function(job, error, ...) {
    job$callback_error <- error
    invisible(NULL)
  }, .package = "relm")
  parent <- simpleError("live callback sentinel")
  failed <- live_test_job(function(state) stop(parent))
  relm:::live_deliver(failed, live_test_payload())
  expect_s3_class(failed$callback_error, "relm_error_callback")
  expect_identical(failed$callback_error$callback, "on_state")
  expect_identical(failed$callback_error$parent, parent)
  expect_identical(failed$callback_error$state_id, 1L)
  expect_identical(failed$callback_error$prompt_id, 1L)
  invalid <- live_test_job(function(state) list(steer = 0))
  relm:::live_deliver(invalid, live_test_payload())
  expect_s3_class(invalid$callback_error, "relm_error_callback")
  expect_identical(invalid$callback_error$reason, "state_reply")
  expect_identical(invalid$callback_error$callback, "on_state")
  expect_s3_class(invalid$callback_error$parent, "relm_error_argument")
  expect_identical(acknowledgements, 0L)
  relm:::live_deliver(failed, live_test_payload())
  expect_identical(acknowledgements, 0L)
})

test_that("live fixed allocation bound covers empty states and carried prompt text", {
  m <- stub_llm()
  config <- list(layers = 1L, components = "residual", top = 0,
    budget_bytes = 65536, r_fixed_bytes = 0, spill = TRUE,
    spill_dir = tempdir(), trace_id = "fixed-byte-fixture", model = m$path,
    spec_key = "live-fixture-spec")
  prompt <- c(input = "x")
  small <- relm:::live_fixed_bytes(config, m, prompt)
  state <- list(step = relm:::live_empty_step(), logits = relm:::live_empty_logits(),
    trace = relm:::live_empty_trace(m, prompt))
  expect_true(is.finite(small) && small > 0)
  expect_lte(as.numeric(object.size(state)), small)
  # A zero-row trace still has vector, string, attribute and list overhead.
  # This rejects a values-only 44*N estimate at N=0.
  expect_gt(small, 44 * nrow(state$trace))
  long_prompt <- c(input = paste0("different-prefix-", strrep("z", 8192)))
  larger <- relm:::live_fixed_bytes(config, m, long_prompt)
  carried <- list(step = relm:::live_empty_step(), logits = relm:::live_empty_logits(),
    trace = relm:::live_empty_trace(m, long_prompt))
  expect_lte(as.numeric(object.size(carried)), larger)
  expect_gte(larger - small,
    nchar(long_prompt, type = "bytes") - nchar(prompt, type = "bytes"))
})
