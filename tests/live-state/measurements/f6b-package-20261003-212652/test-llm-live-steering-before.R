# F6b coefficient-only replies. Pure controls run without a model; [MODEL]
# cases use only the existing cached-Qwen convention and a fresh package.
# Numerical KV history is independently gated by the three-layer native oracle.

live_steering_specs <- function() list(
  list(kind = "steer", layer = 2L, direction = c(0.25, -0.5), coef = 0,
    positions = "all"),
  list(kind = "ablate", layer = 2L, neurons = 1L, value = 0.125,
    component = "residual"),
  list(kind = "steer", layer = 2L, direction = c(-0.125, 0.25), coef = 0.5,
    positions = "all"))

live_steering_reply <- function(intervention, coef) {
  list(steer = data.frame(intervention = intervention, coef = coef))
}

live_steering_metadata <- function(m) {
  serialize(m[setdiff(names(m), c("ptr", "state"))], NULL, version = 2)
}

live_steering_audit <- function(state, indices, layers, coefs, revision, after, effective) {
  expect_identical(names(state), c("step", "logits", "trace"))
  columns <- c("steering_revision", "applied_after_state", "effective_source_pos")
  expect_identical(tail(names(state$step), 4L), c("elapsed", columns))
  expect_identical(unname(vapply(state$step[columns], typeof, character(1))),
    rep("integer", 3L))
  expect_identical(state$step$steering_revision, as.integer(revision))
  expect_identical(state$step$applied_after_state, as.integer(after))
  expect_identical(state$step$effective_source_pos, as.integer(effective))
  audit <- attr(state, "steering", exact = TRUE)
  expect_identical(class(audit), "data.frame")
  expect_identical(names(audit), c("intervention", "layer", "coef"))
  expect_identical(unname(vapply(audit, typeof, character(1))),
    c("integer", "integer", "double"))
  expect_identical(audit$intervention, as.integer(indices))
  expect_identical(audit$layer, as.integer(layers))
  expect_identical(audit$coef, as.double(coefs))
  invisible(audit)
}

test_that("live steering replies normalize partial updates without mutating specifications", {
  specs <- live_steering_specs()
  original <- serialize(specs, NULL, version = 2)
  expect_null(relm:::live_reply(NULL, specs))
  expect_null(relm:::live_reply(live_steering_reply(integer(), double()), specs))
  reply <- live_steering_reply(c(3, 1), c(-2L, 0L))
  expect_identical(relm:::live_reply(reply, specs),
    data.frame(intervention = c(3L, 1L), coef = c(-2, 0)))
  expect_identical(typeof(reply$steer$intervention), "double")
  expect_identical(typeof(reply$steer$coef), "integer")
  expect_identical(relm:::live_reply(live_steering_reply(1, 0), specs),
    data.frame(intervention = 1L, coef = 0))
  expect_identical(serialize(specs, NULL, version = 2), original)
})

test_that("live steering replies reject every extra or malformed shape", {
  table <- data.frame(intervention = 1L, coef = 0.25)
  bad <- list(TRUE, 1, list(), table, list(table), list(update = table),
    list(steer = table, extra = NULL), structure(list(table, table), names = c("steer", "steer")),
    list(steer = as.matrix(table)), list(steer = list(intervention = 1L, coef = 0.25)),
    list(steer = table["intervention"]), list(steer = table[c("coef", "intervention")]),
    list(steer = transform(table, layer = 2L)),
    list(steer = structure(table, class = c("custom_table", "data.frame"))))
  for (reply in bad) {
    expect_error(relm:::live_reply(reply, live_steering_specs()), class = "relm_error_argument")
  }
})

test_that("live steering indices address unique existing steering entries only", {
  specs <- live_steering_specs()
  bad <- list(0L, -1L, 2L, 4L, 1.5, NA_integer_, Inf, 2^31,
    c(1L, 1L), c(1L, 2L), TRUE, "1", factor("1"), 1 + 0i)
  for (index in bad) {
    reply <- live_steering_reply(index, rep(0.25, length(index)))
    expect_error(relm:::live_reply(reply, specs), class = "relm_error_argument")
  }
  expect_error(relm:::live_reply(live_steering_reply(1L, 0), list()),
    class = "relm_error_argument")
})

test_that("live steering coefficients reject nonfinite and unrepresentable scalars", {
  specs <- live_steering_specs()
  maximum <- (2 - 2^-23) * 2^127
  for (value in list(0L, -0, 2^-149, -maximum, maximum)) {
    expect_identical(relm:::live_reply(live_steering_reply(1L, value), specs),
      data.frame(intervention = 1L, coef = as.double(value)))
  }
  for (value in list(NA_real_, NaN, Inf, -Inf, 2^128, -2^128,
    .Machine$double.xmax, TRUE, "0.25", factor("0.25"), 0.25 + 0i)) {
    expect_error(relm:::live_reply(live_steering_reply(1L, value), specs),
      class = "relm_error_argument")
  }
})

test_that("live steering delivery validates the entire reply before acknowledgement", {
  calls <- list()
  local_mocked_bindings(live_payload_state = function(job, payload) payload,
    rebirth_async_state_ack = function(...) {
      calls[[length(calls) + 1L]] <<- list(...)
      list(ok = TRUE)
    }, async_consumer_failure = function(job, error, ...) {
      job$callback_error <- error
      invisible(NULL)
    }, .package = "relm")
  job <- new.env(parent = emptyenv())
  job$id <- "coefficient-reply-control"
  job$model <- stub_llm(interventions = live_steering_specs())
  job$callback_error <- NULL
  job$live <- list(callback = function(state) live_steering_reply(3, -1L),
    original_steering = relm:::live_steering_table(job$model$interventions))
  payload <- list(step = data.frame(state_id = 2L, prompt_id = 1L))
  before <- live_steering_metadata(job$model)
  relm:::live_deliver(job, payload)
  expect_length(calls, 1L)
  expect_identical(calls[[1L]][[2L]], job$id)
  expect_identical(calls[[1L]][[3L]], 2L)
  expect_identical(calls[[1L]][[4L]], data.frame(intervention = 3L, coef = -1))
  expect_null(job$callback_error)
  job$live$callback <- function(state) live_steering_reply(c(1L, 2L), c(0.75, 0.5))
  relm:::live_deliver(job, payload)
  expect_length(calls, 1L)
  expect_s3_class(job$callback_error, "relm_error_callback")
  expect_identical(job$callback_error$callback, "on_state")
  expect_identical(job$callback_error$reason, "state_reply")
  expect_s3_class(job$callback_error$parent, "relm_error_argument")
  expect_identical(job$callback_error$state_id, 2L)
  expect_identical(live_steering_metadata(job$model), before)
})

test_that("[MODEL] live steering audits partial zero and unchanged updates with ablation", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
  on.exit(close(m), add = TRUE)
  first <- llm_steer(m, 2L, rep(0.02, m$hidden_size), coef = 0)
  on.exit(close(first), add = TRUE)
  ablated <- llm_ablate(first, 2L, 1L, value = 0.125)
  on.exit(close(ablated), add = TRUE)
  d <- llm_steer(ablated, 2L, rep(c(0.01, -0.01), length.out = m$hidden_size), coef = 0.5)
  on.exit(close(d), add = TRUE)
  close(first)
  close(ablated)
  original <- live_steering_metadata(d)
  original_base <- live_steering_metadata(m)
  old <- options(relm.trace_budget = 128 * 1024)
  on.exit(options(old), add = TRUE)
  prompt <- "1, 2, 3, 4, 5, 6, 7, 8, 9, 10,"
  baseline <- llm_generate(d, prompt, chat = FALSE, max_tokens = 6L, temperature = 0, seed = 617)
  states <- list()
  coefficients <- list(c(0, 0.5), c(1, 0.5), c(1, 0), c(0, 0), c(0, 0), c(0, 0))
  revisions <- c(0L, 1L, 2L, 3L, 3L, 3L)
  after <- c(0L, 1L, 2L, 3L, 3L, 3L)
  observed <- stream_test_observe(llm_generate(d, prompt, chat = FALSE,
    max_tokens = 6L, temperature = 0, seed = 617, async = TRUE,
    layers = 2L, top = 3L, spill = FALSE,
    on_state = function(state) {
      k <- length(states) + 1L
      states[[k]] <<- state
      p <- attr(state$trace, "prompt_token_count")
      live_steering_audit(state, c(1L, 3L), c(2L, 2L), coefficients[[k]],
        revisions[[k]], after[[k]], if (k == 1L) 1L else p + after[[k]])
      expect_identical(as.matrix(state$trace, layer = 2L)[1L, 1L], 0.125)
      expect_lte(as.numeric(object.size(state)), 128 * 1024)
      expect_lte(as.numeric(object.size(state)), relm:::.relm_async$job$live$estimate$materialized_bytes)
      expect_identical(live_steering_metadata(d), original)
      switch(k,
        live_steering_reply(1L, 1),
        live_steering_reply(3L, 0),
        live_steering_reply(c(1L, 3L), c(0, 0)),
        live_steering_reply(1L, 0),
        live_steering_reply(integer(), double()),
        NULL)
    }))
  stream_test_wait(observed, timeout = 120)
  expect_null(observed$error)
  expect_length(states, 6L)
  expect_identical(observed$settlements, 1L)
  expect_identical(attr(observed$value, "seed"), attr(baseline, "seed"))
  expect_identical(live_steering_metadata(d), original)
  expect_identical(live_steering_metadata(m), original_base)
  expect_identical(llm_generate(d, prompt, chat = FALSE, max_tokens = 6L,
    temperature = 0, seed = 617), baseline)
  expect_null(relm:::.relm_async$job)
})

test_that("[MODEL] live steering restores adapters after cancel callback and reply failures", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
  on.exit(close(m), add = TRUE)
  first <- llm_steer(m, 2L, rep(1, m$hidden_size), coef = 0)
  on.exit(close(first), add = TRUE)
  d <- llm_steer(first, 2L, rep(1, m$hidden_size), coef = 0)
  on.exit(close(d), add = TRUE)
  close(first)
  before <- live_steering_metadata(d)
  prompt <- "1, 2, 3, 4, 5, 6, 7, 8, 9, 10,"
  baseline <- llm_generate(d, prompt, chat = FALSE, max_tokens = 4L, temperature = 0.7, seed = 619)
  parent <- simpleError("F6b callback failure after applied update")
  for (mode in c("cancel", "callback", "invalid_reply", "sum_overflow")) {
    states <- tokens <- 0L
    observed <- stream_test_observe(llm_generate(d, prompt, chat = FALSE,
      max_tokens = 8L, temperature = 0, seed = 619, async = TRUE,
      top = 3L, spill = FALSE,
      on_state = function(state) {
        states <<- states + 1L
        p <- attr(state$trace, "prompt_token_count")
        live_steering_audit(state, 1:2, c(2L, 2L), if (states == 1L) c(0, 0) else c(0.05, 0),
          states - 1L, states - 1L, if (states == 1L) 1L else p + 1L)
        if (states == 1L) return(live_steering_reply(1L, 0.05))
        if (mode == "cancel") {
          expect_true(llm_cancel(d))
          return(live_steering_reply(1L, 0.25))
        }
        if (mode == "callback") stop(parent)
        if (mode == "invalid_reply") return(live_steering_reply(c(1L, 999L), c(0.25, 0.5)))
        # Each scalar/product fits f32; their same-layer sum does not. Only the
        # worker can validate this against the copied current adapter state.
        live_steering_reply(1:2, rep((2 - 2^-23) * 2^127, 2L))
      }, on_token = function(batch) {
        tokens <<- tokens + sum(batch$event == "token")
        invisible(NULL)
      }))
    stream_test_wait(observed, timeout = 120)
    expect_identical(states, 2L, info = mode)
    expect_identical(tokens, 1L, info = mode)
    expect_identical(observed$settlements, 1L)
    expect_null(observed$value)
    if (mode == "cancel") {
      expect_s3_class(observed$error, "relm_error_cancelled")
      expect_identical(observed$error$reason, "requested")
      expect_equal(observed$error$generated_tokens, 2)
    } else {
      expect_s3_class(observed$error, "relm_error_callback")
      expect_identical(observed$error$callback, "on_state")
      if (mode == "callback") expect_identical(observed$error$parent, parent) else {
        expect_identical(observed$error$reason, "state_reply")
        expect_s3_class(observed$error$parent, "condition")
      }
    }
    expect_identical(live_steering_metadata(d), before)
    expect_null(relm:::.relm_async$job)
    expect_identical(llm_generate(d, prompt, chat = FALSE, max_tokens = 4L,
      temperature = 0.7, seed = 619), baseline)
  }
})

test_that("[MODEL] close after an applied live update discards the outstanding reply", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
  on.exit(close(m), add = TRUE)
  d <- llm_steer(m, 2L, rep(0.02, m$hidden_size), coef = 0)
  on.exit(close(d), add = TRUE)
  before <- live_steering_metadata(d)
  prompt <- "1, 2, 3, 4, 5, 6, 7, 8, 9, 10,"
  baseline <- llm_generate(m, prompt, chat = FALSE, max_tokens = 3L, temperature = 0, seed = 621)
  states <- tokens <- 0L
  observed <- stream_test_observe(llm_generate(d, prompt, chat = FALSE,
    max_tokens = 8L, temperature = 0, seed = 621, async = TRUE,
    top = 3L, spill = FALSE,
    on_state = function(state) {
      states <<- states + 1L
      p <- attr(state$trace, "prompt_token_count")
      live_steering_audit(state, 1L, 2L, if (states == 1L) 0 else 1,
        states - 1L, states - 1L, if (states == 1L) 1L else p + 1L)
      if (states == 1L) return(live_steering_reply(1L, 1))
      close(d)
      live_steering_reply(1L, 0)
    }, on_token = function(batch) {
      tokens <<- tokens + sum(batch$event == "token")
      invisible(NULL)
    }))
  stream_test_wait(observed, timeout = 120)
  expect_s3_class(observed$error, "relm_error_cancelled")
  expect_identical(observed$error$reason, "requested")
  expect_equal(observed$error$generated_tokens, 2)
  expect_identical(states, 2L)
  expect_identical(tokens, 1L)
  expect_identical(observed$settlements, 1L)
  expect_true(d$state$closed)
  expect_identical(live_steering_metadata(d), before)
  expect_null(relm:::.relm_async$job)
  for (field in c("active_jobs", "worker_threads", "deferred_handles", "snapshot_slots", "terminal_slots")) {
    expect_identical(relm:::rebirth_async_test_stats()[[field]], 0L)
  }
  expect_identical(llm_generate(m, prompt, chat = FALSE, max_tokens = 3L,
    temperature = 0, seed = 621), baseline)
  expect_null(close(d))
})
