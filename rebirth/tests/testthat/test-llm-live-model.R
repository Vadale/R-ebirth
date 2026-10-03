# F6a public runtime gates. Each test uses RELM_TEST_MODEL_QWEN through the
# existing [MODEL] convention; no download, synthetic tokenizer workaround or
# missing-feature skip. Execute only against a freshly built package.

live_model_events <- function(batches) {
  if (!length(batches)) return(NULL)
  events <- do.call(rbind, batches)
  rownames(events) <- NULL
  events
}

live_model_schema <- function(state, prompt_count, state_id, layers, width, top) {
  expect_identical(names(state), c("step", "logits", "trace"))
  step <- state$step
  expect_identical(class(step), "data.frame")
  expect_identical(names(step), c("state_id", "prompt_id", "token_pos", "token_id",
    "context_pos", "source_pos", "source", "elapsed"))
  expect_identical(unname(vapply(step, typeof, character(1))),
    c(rep("integer", 6), "character", "double"))
  expect_identical(nrow(step), 1L)
  expect_identical(step$state_id, as.integer(state_id))
  expect_identical(step$prompt_id, 1L)
  expect_identical(step$token_pos, as.integer(state_id))
  expect_identical(step$source_pos, as.integer(prompt_count + state_id - 1L))
  expect_identical(step$context_pos, step$source_pos + 1L)
  expect_identical(step$source, if (state_id == 1L) "prompt" else "generated")
  expect_true(is.finite(step$elapsed) && step$elapsed >= 0)
  expect_gte(step$token_id, 1L)
  expect_identical(class(state$logits), "data.frame")
  expect_identical(names(state$logits), c("prompt_id", "rank", "token_id", "token", "logit", "prob"))
  expect_identical(unname(vapply(state$logits, typeof, character(1))),
    c("integer", "integer", "integer", "character", "double", "double"))
  expect_identical(nrow(state$logits), as.integer(top))
  expect_identical(state$logits$rank, seq_len(top))
  expect_true(all(diff(state$logits$logit) <= 0))
  expect_true(all(is.finite(state$logits$logit)))
  expect_true(all(state$logits$prob >= 0 & state$logits$prob <= 1))
  if (top) expect_lt(sum(state$logits$prob), 1)
  trace <- state$trace
  expect_identical(class(trace), c("relm_trace", "data.frame"))
  expect_identical(names(trace), c("prompt_id", "token_pos", "token", "layer",
    "component", "neuron", "value"))
  expect_identical(unname(vapply(trace, typeof, character(1))),
    c("integer", "integer", "character", "integer", "character", "integer", "double"))
  expect_identical(attr(trace, "position_space"), "model_context")
  expect_identical(attr(trace, "prompt_token_count"), as.integer(prompt_count))
  expect_identical(attr(trace, "state_id"), as.integer(state_id))
  expect_false(attr(trace, "spilled"))
  expect_equal(nrow(trace), length(layers) * width)
  expect_setequal(trace$layer, layers)
  expect_true(all(trace$token_pos == step$source_pos))
  expect_true(all(trace$prompt_id == 1L))
  expect_true(all(trace$component == "residual"))
  expect_true(all(is.finite(trace$value)))
  for (layer in layers) {
    expect_identical(dim(as.matrix(trace, layer = layer)), c(1L, as.integer(width)))
  }
}

test_that("[MODEL] live no-op preserves seeded results and state-before-token order", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
  on.exit(close(m), add = TRUE)
  prompt <- c(input = "The capital of Italy is")
  tokenized <- relm:::relm_check(relm:::rebirth_tokenize(m$ptr,
    unname(prompt), add_special = TRUE, parse_special = TRUE))
  prompt_count <- length(tokenized$ids)
  reference_logits <- llm_logits(m, prompt, top = 5L)
  expected <- llm_generate(m, prompt, chat = FALSE, max_tokens = 6L,
    temperature = 0.7, seed = 71)
  ordinary <- stream_test_observe(llm_generate(m, prompt, chat = FALSE,
    max_tokens = 6L, temperature = 0.7, seed = 71, async = TRUE))
  stream_test_wait(ordinary, timeout = 120)
  expect_null(ordinary$error)
  expect_identical(ordinary$value, expected)
  states <- batches <- list()
  delivered_tokens <- integer()
  selected_layers <- c(1L, m$layers)
  set.seed(6243)
  before <- .Random.seed
  observed <- stream_test_observe(llm_generate(m, prompt, chat = FALSE,
    max_tokens = 6L, temperature = 0.7, seed = 71, async = TRUE,
    layers = selected_layers, top = 5L, spill = FALSE,
    on_state = function(state) {
      k <- length(states) + 1L
      expect_identical(delivered_tokens, seq_len(k - 1L))
      states[[k]] <<- state
      expect_error(llm_logits(m, "busy"), class = "relm_error_busy")
      expect_error(llm_generate(m, "busy", async = TRUE), class = "relm_error_busy")
      # Both direct poll reentry and nested event-loop pumping must be inert.
      relm:::async_poll(relm:::.relm_async$job)
      later::run_now(0, loop = later::global_loop())
      expect_length(states, k)
      expect_identical(delivered_tokens, seq_len(k - 1L))
      invisible(NULL)
    }, on_token = function(batch) {
      batches[[length(batches) + 1L]] <<- batch
      positions <- batch$token_pos[batch$event == "token"]
      expect_true(all(positions <= length(states)))
      delivered_tokens <<- c(delivered_tokens, positions)
      # The older token consumer's ignored return contract is unchanged.
      list(ignored = TRUE)
    }))
  stream_test_wait(observed, timeout = 120)
  expect_null(observed$error)
  expect_identical(observed$value, expected)
  expect_identical(observed$settlements, 1L)
  expect_identical(.Random.seed, before)
  expect_gt(length(states), 1L)
  events <- live_model_events(batches)
  tokens <- events[events$event == "token", ]
  expect_identical(tokens$token_pos, seq_along(states))
  expect_identical(tokens$token_id, vapply(states, function(s) s$step$token_id, integer(1)))
  expect_identical(stream_test_reconstruct(events, 1L), unname(expected[[1]]))
  for (k in seq_along(states)) {
    live_model_schema(states[[k]], prompt_count, k, selected_layers, m$hidden_size, 5L)
  }
  # Same model/backend and raw prompt: the first state exposes the same raw
  # pre-sampling table as llm_logits, despite temperature = 0.7 generation.
  expect_identical(states[[1L]]$logits, reference_logits)
  expect_identical(unique(states[[1L]]$trace$token), tail(tokenized$pieces, 1L))
  expect_true(all(diff(vapply(states, function(s) s$step$elapsed, double(1))) >= 0))
  expect_null(relm:::.relm_async$job)
})

test_that("[MODEL] logits-only defaults keep a typed empty trace", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
  on.exit(close(m), add = TRUE)
  states <- list()
  result <- stream_test_observe(llm_generate(m, "The capital of Italy is",
    chat = FALSE, max_tokens = 2L, temperature = 0, seed = 9, async = TRUE,
    on_state = function(state) {
      states[[length(states) + 1L]] <<- state
      invisible(NULL)
    }))
  stream_test_wait(result, timeout = 120)
  expect_null(result$error)
  expect_gt(length(states), 0L)
  prompt_count <- attr(states[[1L]]$trace, "prompt_token_count")
  for (k in seq_along(states)) {
    live_model_schema(states[[k]], prompt_count, k, integer(), m$hidden_size, 20L)
  }
})

test_that("[MODEL] cancellation at state one samples no next token and delivers no token one", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
  on.exit(close(m), add = TRUE)
  states <- batches <- list()
  result <- stream_test_observe(llm_generate(m, "The capital of Italy is",
    chat = FALSE, max_tokens = 8L, temperature = 0, seed = 13, async = TRUE,
    on_state = function(state) {
      states[[length(states) + 1L]] <<- state
      expect_true(llm_cancel(m))
      expect_false(llm_cancel(m))
      invisible(NULL)
    }, on_token = function(batch) {
      batches[[length(batches) + 1L]] <<- batch
    }))
  stream_test_wait(result, timeout = 120)
  expect_s3_class(result$error, "relm_error_cancelled")
  expect_equal(result$error$generated_tokens, 1)
  expect_identical(result$error$prompt_id, 1L)
  expect_length(states, 1L)
  expect_length(batches, 0L)
  expect_null(result$value)
  expect_identical(result$settlements, 1L)
  expect_null(relm:::.relm_async$job)
  expect_false(llm_cancel(m))
  expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
})

test_that("[MODEL] live callback failure returns ownership with its original condition", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
  on.exit(close(m), add = TRUE)
  parent <- simpleError("live model callback sentinel")
  callbacks <- tokens <- 0L
  result <- stream_test_observe(llm_generate(m, "The capital of Italy is",
    chat = FALSE, max_tokens = 8L, temperature = 0, seed = 13, async = TRUE,
    on_state = function(state) { callbacks <<- callbacks + 1L; stop(parent) },
    on_token = function(batch) { tokens <<- tokens + sum(batch$event == "token") }))
  stream_test_wait(result, timeout = 120)
  expect_s3_class(result$error, "relm_error_callback")
  expect_identical(result$error$callback, "on_state")
  expect_identical(result$error$parent, parent)
  expect_identical(callbacks, 1L)
  expect_identical(tokens, 0L)
  expect_identical(result$settlements, 1L)
  expect_no_error(relm:::relm_check(relm:::rebirth_async_ready(m$ptr)))
})

test_that("[MODEL] completed live spill slices survive cancellation and model close", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
  directory <- tempfile("relm-live-spill-")
  dir.create(directory)
  old <- options(relm.trace_budget = 32 * 1024^2)
  on.exit({ options(old); close(m); unlink(directory, recursive = TRUE) }, add = TRUE)
  prompt <- "The capital of Italy is"
  in_memory <- list()
  reference <- stream_test_observe(llm_generate(m, prompt, chat = FALSE,
    max_tokens = 2L, temperature = 0, seed = 23, async = TRUE,
    layers = NULL, top = 0L, spill = FALSE,
    on_state = function(state) {
      in_memory[[length(in_memory) + 1L]] <<- state
      expect_lte(as.numeric(object.size(state)), 32 * 1024^2)
      expect_identical(nrow(state$logits), 0L)
      invisible(NULL)
    }))
  stream_test_wait(reference, timeout = 120)
  expect_null(reference$error)
  expect_gt(length(in_memory), 0L)
  options(relm.trace_budget = 64 * 1024)
  retained <- NULL
  spilled <- stream_test_observe(llm_generate(m, prompt, chat = FALSE,
    max_tokens = 2L, temperature = 0, seed = 23, async = TRUE,
    layers = NULL, top = 0L, spill = TRUE, spill_dir = directory,
    on_state = function(state) {
      retained <<- state
      expect_true(attr(state$trace, "spilled"))
      expect_identical(nrow(state$trace), 0L)
      expect_identical(nrow(as.data.frame(state$trace)), 0L)
      expect_lte(as.numeric(object.size(state)), 64 * 1024)
      expect_true(all(file.exists(attr(state$trace, "spill_files"))))
      expect_true(llm_cancel(m))
      invisible(NULL)
    }))
  stream_test_wait(spilled, timeout = 120)
  expect_s3_class(spilled$error, "relm_error_cancelled")
  expect_equal(spilled$error$generated_tokens, 1)
  expect_false(is.null(retained))
  close(m)
  for (layer in seq_len(m$layers)) {
    expect_identical(as.matrix(retained$trace, layer = layer),
      as.matrix(in_memory[[1L]]$trace, layer = layer))
  }
  expect_identical(attr(retained$trace, "position_space"), "model_context")
  expect_identical(attr(retained$trace, "state_id"), 1L)
  for (attribute in c("state_id", "prompt_token_count", "position_space", "spill_trace_id")) {
    stale <- retained$trace
    attr(stale, attribute) <- if (attribute %in% c("state_id", "prompt_token_count")) {
      attr(stale, attribute) + 1L
    } else "stale-live-metadata"
    expect_error(as.matrix(stale, layer = 1L), class = "relm_error_trace")
  }
  # A delivered custom-directory artifact remains caller-owned after failure.
  expect_true(all(file.exists(attr(retained$trace, "spill_files"))))
})

test_that("[MODEL] live chat coordinates include the exact template over a prefill boundary", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 2048)
  on.exit(close(m), add = TRUE)
  expect_identical(m$architecture, "qwen2")
  prompt <- c(input = paste0(strrep("word ", 520L), "Write the integers from one to ten."))
  # Source-backed manual renderer, not a guessed Hugging Face template:
  # generate.rs::resolve_prompt_text_for_output passes a single user message and
  # add_assistant=TRUE; vendored llama-chat.cpp's CHATML branch emits exactly this
  # text, with no inserted system turn. The embedded Qwen template is recognized
  # as CHATML, so add_special=FALSE and parse_special=TRUE apply.
  rendered <- paste0("<|im_start|>user\n", unname(prompt),
    "<|im_end|>\n<|im_start|>assistant\n")
  templated <- relm:::relm_check(relm:::rebirth_tokenize(m$ptr, rendered,
    add_special = FALSE, parse_special = TRUE))
  raw <- relm:::relm_check(relm:::rebirth_tokenize(m$ptr, unname(prompt),
    add_special = TRUE, parse_special = FALSE))
  p <- length(templated$ids)
  expect_gt(p, 512L)
  expect_lt(p + 2L, m$context_length)
  expect_gt(p, length(raw$ids))
  states <- list()
  selected <- c(1L, m$layers)
  result <- stream_test_observe(llm_generate(m, prompt, chat = TRUE,
    max_tokens = 2L, temperature = 0, seed = 29, async = TRUE,
    layers = selected, top = 5L, spill = FALSE,
    on_state = function(state) {
      states[[length(states) + 1L]] <<- state
      invisible(NULL)
    }))
  stream_test_wait(result, timeout = 120)
  expect_null(result$error)
  expect_length(states, 2L)
  for (k in seq_along(states)) {
    live_model_schema(states[[k]], p, k, selected, m$hidden_size, 5L)
    expect_identical(attr(states[[k]]$trace, "prompts"), prompt)
  }
  expect_identical(unique(states[[1L]]$trace$token), tail(templated$pieces, 1L))
  expect_false(identical(states[[1L]]$step$source_pos, as.integer(length(raw$ids))))
})

test_that("[MODEL] close inside on_state abandons delivery and drains owned native work", {
  m <- llm(qwen_model_path(), backend = "cpu", context_length = 1024)
  on.exit(close(m), add = TRUE)
  states <- batches <- list()
  phases <- character()
  delivered_job <- NULL
  result <- stream_test_observe(llm_generate(m, "The capital of Italy is",
    chat = FALSE, max_tokens = 8L, temperature = 0, seed = 41, async = TRUE,
    on_state = function(state) {
      states[[length(states) + 1L]] <<- state
      delivered_job <<- relm:::.relm_async$job
      expect_identical(state$step$state_id, 1L)
      expect_length(batches, 0L)
      expect_identical(relm:::rebirth_async_test_stats()$active_jobs, 1L)
      close(m)
      expect_true(m$state$closed)
      expect_true(relm:::rebirth_handle_is_closed(m$ptr))
      # Reentry while this callback still owns delivery cannot dispatch another
      # state or the sampled token after close abandoned the outstanding state.
      later::run_now(0, loop = later::global_loop())
      expect_length(states, 1L)
      expect_length(batches, 0L)
      invisible(NULL)
    }, on_token = function(batch) {
      batches[[length(batches) + 1L]] <<- batch
    }, on_progress = function(progress) {
      phases <<- c(phases, progress$phase)
    }))
  stream_test_wait(result, timeout = 120)
  # During an outstanding acknowledgement, discard wakes the running worker
  # with Cancelled. finish_active's stream_closed reason applies to an already
  # successful native outcome; both delivery-close paths have this exact class.
  expect_s3_class(result$error, "relm_error_cancelled")
  expect_identical(result$error$reason, "requested")
  expect_equal(result$error$generated_tokens, 1)
  expect_identical(result$error$prompt_id, 1L)
  expect_null(result$value)
  expect_identical(result$settlements, 1L)
  expect_length(states, 1L)
  expect_length(batches, 0L)
  expect_false("complete" %in% phases)
  expect_true(m$state$closed)
  expect_null(relm:::.relm_async$job)
  expect_false(is.null(delivered_job))
  for (field in c("model", "live", "stream", "timer", "resolve", "reject")) {
    expect_null(delivered_job[[field]])
  }
  stats <- relm:::rebirth_async_test_stats()
  for (field in c("active_jobs", "worker_threads", "deferred_handles",
    "snapshot_slots", "terminal_slots", "queued_jobs")) {
    expect_identical(stats[[field]], 0L)
  }
  # Idempotent close is a metadata/lifetime operation, not inference on m.
  expect_null(close(m))
  later::run_now(0, loop = later::global_loop())
  expect_identical(result$settlements, 1L)
  expect_length(states, 1L)
  expect_length(batches, 0L)
})
