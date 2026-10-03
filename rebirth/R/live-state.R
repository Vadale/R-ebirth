# D-041 live observation. All functions and R objects stay on the main thread.
relm_live_max_tokens <- 1024L
relm_live_poll_interval <- 0.005
relm_live_materialized_cap <- 33554432
relm_live_batch_rows <- 4096L

live_validate_arguments <- function(m, prompt, max_tokens, async, on_state,
                                    layers, components, top, spill, spill_dir,
                                    schema, has_images) {
  if (is.null(on_state)) {
    defaults <- is.numeric(layers) && !is.complex(layers) && length(layers) == 0L &&
      identical(components, "residual") && !is.complex(top) && is_count(top) && top == 20L &&
      identical(spill, TRUE) && is.null(spill_dir)
    if (!defaults) abort_argument("on_state",
      "Capture arguments require a non-NULL `on_state` callback.")
    return(NULL)
  }
  if (!is.function(on_state) || !isTRUE(async)) abort_argument("on_state",
    "`on_state` must be a function and requires `async = TRUE`.")
  if (length(prompt) != 1L) abort_argument("prompt",
    "Live observation requires exactly one text prompt.")
  if (max_tokens > relm_live_max_tokens) abort_argument("max_tokens",
    "Live observation requires `max_tokens <= 1024`.")
  if (!is.null(schema)) abort_argument("schema",
    "Live observation cannot be combined with structured generation.")
  if (has_images) abort_argument("images",
    "Live observation accepts text-only input.")
  if (is.null(layers)) layers <- seq_len(m$layers)
  if (!is.numeric(layers) || is.complex(layers) || anyNA(layers) ||
    any(!is.finite(layers)) || any(layers != round(layers)) ||
    any(layers < 1L | layers > m$layers) || anyDuplicated(layers)) {
    abort_argument("layers", "`layers` must be NULL, integer(), or unique valid 1-based block indices.")
  }
  if (!is.character(components) || !length(components) || anyNA(components) ||
    !all(components %in% c("residual", "attn_out", "mlp_out"))) {
    abort_argument("components", "`components` must select residual, attn_out or mlp_out.")
  }
  components <- unique(components)
  if (is.complex(top) || !is_count(top) || top < 0 ||
    top > min(128, m$.vocab_size)) {
    abort_argument("top", "`top` must be an integer from 0 through min(128, vocabulary size).")
  }
  if (!length(layers) && top == 0) abort_argument("on_state",
    "Live observation requires activations or a nonzero logit summary.")
  if (!is.logical(spill) || length(spill) != 1L || is.na(spill)) {
    abort_argument("spill", "`spill` must be one nonmissing logical value.")
  }
  if (!is.null(spill_dir) && (!is.character(spill_dir) || length(spill_dir) != 1L ||
    is.na(spill_dir) || !nzchar(spill_dir) || Encoding(spill_dir) == "bytes" ||
    !validUTF8(enc2utf8(spill_dir)))) {
    abort_argument("spill_dir", "`spill_dir` must be NULL or one nonempty directory path.")
  }
  list(callback = on_state, layers = as.integer(layers), components = components,
    top = as.integer(top), spill = spill, spill_dir = spill_dir,
    budget_bytes = min(trace_budget(), relm_live_materialized_cap))
}

live_empty_trace <- function(m, prompt) {
  structure(data.frame(prompt_id = integer(), token_pos = integer(),
    token = character(), layer = integer(), component = character(),
    neuron = integer(), value = double(), stringsAsFactors = FALSE),
    class = c("relm_trace", "data.frame"), model = m$path,
    prompts = prompt, spilled = FALSE, spill_files = NULL,
    position_space = "model_context", prompt_token_count = 0L, state_id = 0L)
}

live_empty_logits <- function() {
  data.frame(prompt_id = integer(), rank = integer(), token_id = integer(),
    token = character(), logit = double(), prob = double(), stringsAsFactors = FALSE)
}

live_empty_step <- function() {
  data.frame(state_id = 0L, prompt_id = 1L, token_pos = 0L, token_id = 0L,
    context_pos = 0L, source_pos = 0L, source = "generated", elapsed = 0,
    stringsAsFactors = FALSE)
}

live_reply <- function(reply) {
  if (!is.null(reply)) abort_argument("on_state",
    "The live observation callback must return NULL (use invisible(NULL)).")
  invisible(NULL)
}

live_payload_state <- function(job, payload) {
  step <- payload$step
  columns <- names(live_empty_step())
  good <- is.data.frame(step) && identical(names(step), columns) && nrow(step) == 1L &&
    all(vapply(step[seq_len(6L)], is.integer, logical(1))) &&
    is.character(step$source) && is.double(step$elapsed) && !anyNA(step) &&
    is.finite(step$elapsed) && step$elapsed >= job$live_elapsed &&
    step$state_id == job$live_state_id + 1L && step$prompt_id == 1L &&
    step$token_pos == step$state_id && step$token_id >= 1L &&
    step$context_pos == step$source_pos + 1L &&
    identical(step$source, if (step$state_id == 1L) "prompt" else "generated")
  p <- payload$prompt_token_count
  good <- good && is.integer(p) && length(p) == 1L && !is.na(p) && p >= 1L &&
    step$source_pos == p + step$state_id - 1L &&
    (is.null(job$live_prompt_count) || identical(p, job$live_prompt_count))
  if (!isTRUE(good)) relm_abort("relm_error_internal",
    "The live state violates its sequence or source-position contract.",
    list(reason = "live_protocol", job_id = job$id))
  trace <- if (isTRUE(payload$trace$spilled)) {
    new_spilled_trace(payload$trace, job$model, job$live$prompt,
      payload$trace$spec_key)
  } else new_inmemory_trace(payload$trace, job$model, job$live$prompt)
  attr(trace, "position_space") <- "model_context"
  attr(trace, "prompt_token_count") <- p
  attr(trace, "state_id") <- step$state_id
  if (isTRUE(attr(trace, "spilled"))) {
    attr(trace, "live_source_pos") <- step$source_pos
    attr(trace, "live_batch_rows") <- relm_live_batch_rows
    attr(trace, "live_batch_bytes") <- payload$trace$batch_bytes
  }
  result <- list(step = step, logits = payload$logits, trace = trace)
  if (!is.null(job$live$estimate)) {
    bound <- if (isTRUE(attr(trace, "spilled"))) job$live$estimate$logits_bytes else
      job$live$estimate$materialized_bytes
    actual <- as.numeric(object.size(result))
    if (actual > bound || actual > job$live$budget_bytes) {
      relm_abort("relm_error_internal", "Live state materialization exceeded its admitted bound.",
        list(reason = "live_allocation_invariant", estimate_bytes = bound, actual_bytes = actual))
    }
  }
  job$live_state_id <- step$state_id
  job$live_elapsed <- step$elapsed
  job$live_prompt_count <- p
  result
}

live_deliver <- function(job, payload) {
  if (is.null(payload) || is.null(job$live) || !is.null(job$callback_error) ||
    job$model$state$closed) return(invisible(NULL))
  state <- live_payload_state(job, payload)
  fail <- function(error, reason = NULL) {
    async_consumer_failure(job, async_condition("relm_error_callback",
      "The live state callback failed; no generation result was returned.",
      list(callback = "on_state", reason = reason, parent = error,
        job_id = job$id, state_id = state$step$state_id, prompt_id = 1L)))
  }
  reply <- tryCatch(job$live$callback(state), error = function(e) {
    fail(e); NULL
  }, interrupt = function(e) { fail(e); NULL })
  if (!is.null(job$callback_error) || job$model$state$closed) return(invisible(NULL))
  valid <- tryCatch({ live_reply(reply); TRUE }, error = function(e) {
    fail(e, "state_reply"); FALSE
  })
  if (valid) relm_check(rebirth_async_state_ack(job$model$ptr, job$id, state$step$state_id))
  invisible(NULL)
}

# Measure fixed headers and actual retained metadata before the seed draw. The
# numeric/string payload growth is counted separately by the twin native bound.
live_fixed_bytes <- function(config, m, prompt) {
  integer_profile <- vapply(c(0L, 1L, 3L, 5L, 9L, 17L),
    function(n) as.numeric(object.size(integer(n))), numeric(1))
  if (.Machine$sizeof.pointer != 8L ||
    !identical(integer_profile, c(48, 56, 64, 80, 96, 176)) ||
    as.numeric(object.size(double())) != 48 ||
    as.numeric(object.size(double(17L))) != 184 ||
    as.numeric(object.size(vector("list", 17L))) != 184 ||
    as.numeric(object.size(strrep("x", 8L))) -
      as.numeric(object.size(vector("list", 1L))) != 64) {
    abort_argument("on_state", "This R allocation profile is not supported by the live memory bound.")
  }
  memory <- live_empty_trace(m, prompt)
  # Maximum-width coordinate strings conservatively cover unknown tokenized P.
  suffix <- paste0("|position_space=model_context|prompt_token_count=2147483647",
    "|state_id=1024|source_pos=2147483647|live_batch_rows=4096",
    "|live_batch_bytes=9007199254740991")
  path <- file.path(config$spill_dir, paste0("trace-", config$trace_id, "-1024.arrow"))
  spilled <- memory
  attr(spilled, "spilled") <- TRUE
  attr(spilled, "spill_files") <- path
  attr(spilled, "spill_layers") <- config$layers
  attr(spilled, "spill_positions") <- 2147483647L
  attr(spilled, "spill_components") <- config$components
  attr(spilled, "spill_n_rows") <- 0
  attr(spilled, "spill_n_positions") <- 1
  attr(spilled, "spill_n_embd") <- as.integer(m$hidden_size)
  attr(spilled, "spill_trace_id") <- paste0(config$trace_id, "-1024")
  attr(spilled, "spill_spec") <- paste0(config$spec_key, suffix)
  attr(spilled, "live_source_pos") <- 2147483647L
  attr(spilled, "live_batch_rows") <- relm_live_batch_rows
  attr(spilled, "live_batch_bytes") <- 0
  empty <- function(trace) list(step = live_empty_step(), logits = live_empty_logits(), trace = trace)
  # Include the empty interning payload and submission descriptors, even though
  # not every skeleton coexists. Variable row codes are in the separate formula.
  interned <- list(ok = TRUE, spilled = FALSE, positions_recycled = FALSE,
    prompt_id = integer(), token_pos = integer(), layer = integer(),
    neuron = integer(), value = double(), component_levels = character(),
    component_codes = integer(), token_levels = character(), token_codes = integer(),
    row_nneuron = integer())
  max(as.numeric(object.size(empty(memory))), as.numeric(object.size(empty(spilled)))) +
    as.numeric(object.size(interned)) + as.numeric(object.size(config))
}

live_config_strings <- function(config) {
  unname(unlist(config[c("spill_dir", "trace_id", "model", "spec_key")], use.names = FALSE))
}

live_prepare <- function(live, m, prompt, max_tokens) {
  if (is.null(live)) return(NULL)
  # This creates no output file. Managed-directory preparation establishes the
  # existing lifetime lease; custom directories remain caller-owned.
  dir <- if (live$spill) {
    if (is.null(live$spill_dir)) spill_session_dir() else
      normalizePath(path.expand(live$spill_dir), mustWork = FALSE)
  } else ""
  if (live$spill && !startsWith(dir, "/")) dir <- file.path(getwd(), dir)
  id <- gsub(".", "-", next_trace_id(), fixed = TRUE)
  config <- list(layers = live$layers, components = live$components,
    top = as.double(live$top), budget_bytes = as.double(live$budget_bytes),
    r_fixed_bytes = 0, spill = live$spill, spill_dir = dir, trace_id = id,
    model = m$path, spec_key = paste0("live-v1|",
      trace_spec_key(m, prompt, live$layers, "last", live$components)))
  for (name in c("spill_dir", "trace_id", "model", "spec_key")) {
    text <- config[[name]]
    if (Encoding(text) == "bytes" || !validUTF8(enc2utf8(text))) {
      abort_argument("on_state", "Live metadata must contain valid UTF-8 text.")
    }
    config[[name]] <- enc2utf8(text)
  }
  # Bound metadata on its own before the native preflight copies it. The
  # caller then checks its aggregate with all ordinary normalized arguments.
  async_validate_inputs(character(), character(), NULL, NULL,
    max_tokens, 0, 0, live_config_strings(config))
  config$r_fixed_bytes <- live_fixed_bytes(config, m, prompt)
  estimate <- relm_check(rebirth_live_preflight(m$ptr, config, as.integer(max_tokens)))
  twin <- live_memory_bound(m$hidden_size, live$layers, live$components,
    live$top, estimate$max_piece_bytes, config$r_fixed_bytes)
  if (!identical(as.double(estimate$materialized_bytes), as.double(twin$materialized_bytes)) ||
    !identical(as.double(estimate$logits_bytes), as.double(twin$logits_bytes))) {
    relm_abort("relm_error_internal", "R and native live allocation estimates differ.",
      list(reason = "live_allocation_invariant"))
  }
  live$peak_bound <- live_transport_peak_bound(estimate, config, m, max_tokens, prompt)
  live$native_config <- config
  live$estimate <- estimate
  live$prompt <- prompt
  live
}

# Twin of the supported R64 native preflight formula. Each input is a count of
# bytes/values, never a measured RSS value. F includes the actual empty schemas,
# fixed attributes and strings measured by live_fixed_bytes().
live_r_vector_bytes <- function(bytes) {
  if (!is.numeric(bytes) || is.complex(bytes) || anyNA(bytes) || any(!is.finite(bytes)) ||
    any(bytes < 0 | bytes != floor(bytes) | bytes >= 2^53 - 8)) {
    abort_argument("on_state", "Live allocation arithmetic exceeded the exact byte range.")
  }
  vapply(bytes, function(n) {
    pools <- c(0, 8, 16, 32, 48, 64, 128)
    fit <- pools[pools >= n]
    48 + if (length(fit)) fit[[1L]] else 8 * ceiling(n / 8)
  }, numeric(1), USE.NAMES = FALSE)
}

live_memory_bound <- function(hidden_size, layers, components, top,
                              max_piece_bytes, r_fixed_bytes, steers = 0L) {
  values <- c(hidden_size, length(layers), length(components), top,
    max_piece_bytes, r_fixed_bytes, steers)
  if (!is.numeric(values) || is.complex(values) || anyNA(values) || any(!is.finite(values)) || any(values < 0 | values != floor(values))) {
    abort_argument("on_state", "Live allocation dimensions must be exact nonnegative integers.")
  }
  vectors <- length(layers) * length(components)
  n <- hidden_size * vectors
  g <- function(n) live_r_vector_bytes(n) - 48
  chars <- function(n) live_r_vector_bytes(n + 1)
  logits <- 3 * g(4 * top) + 3 * g(8 * top) + top * chars(max_piece_bytes) + 8 * (top > 0)
  trace <- if (n == 0) 0 else max(44 * n, 4 * g(4 * n) + 3 * g(8 * n)) +
    chars(max_piece_bytes) + sum(chars(nchar(components, type = "bytes"))) + 8
  audit <- 2 * g(4 * steers) + g(8 * steers) + 8 * (steers > 0)
  result <- c(materialized_bytes = r_fixed_bytes + logits + trace + audit,
    logits_bytes = r_fixed_bytes + logits + audit)
  if (any(!is.finite(result)) || any(result >= 2^53)) {
    abort_argument("on_state", "Live allocation arithmetic overflowed.")
  }
  as.list(result)
}

# Native layout/capacity fields are a compiled profile, not guessed Rust layouts
# in R. Recompute R conversion terms and the complete sum independently. The
# inherited ordinary async bound is reported separately; overlap is conservative.
live_transport_peak_bound <- function(estimate, config, m, max_tokens, prompt) {
  fields <- c("materialized_bytes", "logits_bytes", "transient_bytes",
    "native_fixed_bytes", "ffi_intern_bytes", "native_logits_bytes",
    "capture_writer_bytes", "wp10_peak_bytes", "r_payload_bytes",
    "r_assembly_bytes", "max_piece_bytes")
  good <- all(vapply(fields, function(name) {
    value <- estimate[[name]]
    is.numeric(value) && !is.complex(value) && length(value) == 1L &&
      !is.na(value) && is.finite(value) && value >= 0 && value == floor(value) && value < 2^53
  }, logical(1))) && is.logical(estimate$spilled) && length(estimate$spilled) == 1L && !is.na(estimate$spilled)
  fail <- function() relm_abort("relm_error_internal", "Live transient allocation ledgers differ.",
    list(reason = "live_allocation_invariant"))
  if (!good) fail()
  n <- if (estimate$spilled) 0 else m$hidden_size * length(config$layers) * length(config$components)
  vectors <- if (estimate$spilled) 0 else length(config$layers) * length(config$components)
  g <- function(n) live_r_vector_bytes(n) - 48
  chars <- function(n) live_r_vector_bytes(n + 1)
  r_payload <- estimate$logits_bytes
  if (!estimate$spilled) r_payload <- r_payload + 4 * g(4 * n) + g(8 * n) +
    3 * g(4 * vectors) + g(8 * length(config$components)) + g(8) +
    chars(estimate$max_piece_bytes) + sum(chars(nchar(config$components, type = "bytes")))
  assembly <- if (estimate$spilled) 0 else 2 * live_r_vector_bytes(4 * n) + 2 * live_r_vector_bytes(8 * n)
  wp10 <- stream_transport_peak_bound()$total_bytes
  r_mode <- if (estimate$spilled) estimate$logits_bytes else estimate$materialized_bytes
  components <- c(r_state_copies = 2 * r_mode, r_payload = r_payload,
    r_assembly = assembly, ffi_native = 24 * n + 12 * vectors + 44 * config$top + estimate$ffi_intern_bytes,
    native_logits = estimate$native_logits_bytes, capture_writer = estimate$capture_writer_bytes,
    native_fixed = estimate$native_fixed_bytes, wp10 = wp10)
  total <- sum(components)
  if (!is.finite(total) || total >= 2^53 ||
    total != estimate$transient_bytes || r_payload != estimate$r_payload_bytes ||
    assembly != estimate$r_assembly_bytes || wp10 != estimate$wp10_peak_bytes) fail()
  inherited <- async_transport_peak_bound(m$context_length, n = 1L,
    max_tokens = max_tokens, names_bytes = sum(nchar(names(prompt), type = "bytes", keepNA = FALSE)))
  list(live_bytes = total, live_components = components,
    inherited_async_bytes = inherited$total_bytes,
    total_bytes = total + inherited$total_bytes)
}
