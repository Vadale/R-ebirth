# D-044: validation and a conservative live-materialization ledger shared by
# comparison and timeline. No model operation or global history is performed.
graphics_fail <- function(reason, message) {
  relm_abort("relm_error_trace", message, list(reason = reason))
}

graphics_number <- function(x, lower = 0, upper = Inf, whole = FALSE) {
  is.numeric(x) && !is.object(x) && is.null(attributes(x)) && length(x) == 1L &&
    !is.na(x) && is.finite(x) && x >= lower && x <= upper && (!whole || x == floor(x))
}

graphics_text <- function(x, limit = 1024^2, empty = FALSE) {
  is.character(x) && is.null(attributes(x)) && length(x) == 1L && !is.na(x) &&
    (empty || nzchar(x)) && nchar(x, type = "bytes") <= limit &&
    Encoding(x) != "bytes" && validUTF8(x)
}

graphics_budget <- function(x, upper) {
  if (!graphics_number(x, 65536, upper, TRUE)) {
    abort_argument("max_bytes", sprintf("`max_bytes` must be whole bytes from 65536 through %.0f; use a bounded selection.", upper))
  }
  as.double(x)
}

graphics_admit <- function(estimate, budget) {
  if (!is.finite(estimate) || estimate > budget) {
    relm_abort("relm_error_oom", "The graphics working set exceeds max_bytes. Select fewer coordinates or increase the explicit budget.",
      list(estimate_bytes = estimate, budget_bytes = budget, reason = "graphics_materialization"))
  }
  invisible(estimate)
}

graphics_stage <- function(bound, ...) {
  actual <- sum(vapply(list(...), function(x) as.double(object.size(x)), numeric(1)))
  if (actual > bound) relm_abort("relm_error_internal",
    "Graphics materialization exceeded its admitted ledger; report this invariant failure.",
    list(reason = "graphics_allocation", actual_bytes = actual, estimate_bytes = bound))
  invisible(actual)
}

graphics_frame <- function(x, names, types) {
  if (!identical(class(x), "data.frame") ||
      !setequal(names(attributes(x)), c("names", "row.names", "class")) ||
      !identical(colnames(x), names)) return(FALSE)
  rows <- .row_names_info(x, 2L)
  graphics_number(rows, 0, .Machine$integer.max, TRUE) &&
    all(vapply(seq_along(names), function(i) {
      identical(typeof(x[[i]]), types[i]) && is.null(attributes(x[[i]])) && length(x[[i]]) == rows
    }, logical(1)))
}

graphics_steering <- function(x) {
  if (!graphics_frame(x, c("intervention", "layer", "coef"), c("integer", "integer", "double")) ||
    anyNA(x) || any(!is.finite(x$coef)) || any(x$intervention < 1L) ||
    any(x$layer < 2L) || is.unsorted(x$intervention, strictly = TRUE)) {
    graphics_fail("steering_audit", "The state must contain the unmodified worker steering audit.")
  }
  invisible(x)
}

graphics_state <- function(state, budget, logits = TRUE) {
  if (!is.list(state) || is.object(state) || !identical(names(state), c("step", "logits", "trace"))) {
    graphics_fail("state_schema", "Supply an actual on_state observation with step, logits and trace.")
  }
  step <- state$step; tr <- state$trace; steer <- attr(state, "steering", exact = TRUE)
  columns <- c("state_id", "prompt_id", "token_pos", "token_id", "context_pos", "source_pos",
    "source", "elapsed", "steering_revision", "applied_after_state", "effective_source_pos")
  types <- c(rep("integer", 6L), "character", "double", rep("integer", 3L))
  if (!graphics_frame(step, columns, types) || nrow(step) != 1L || anyNA(step) ||
      !is.finite(step$elapsed) || step$elapsed < 0 || step$state_id < 1L || step$state_id > 1024L ||
      step$prompt_id != 1L || step$token_pos != step$state_id || step$token_id < 1L ||
      step$source_pos < 1L || as.double(step$context_pos) != as.double(step$source_pos) + 1 ||
      !identical(step$source, if (step$state_id == 1L) "prompt" else "generated")) {
    graphics_fail("step_schema", "The state has invalid source or sampled-token coordinates.")
  }
  if (!inherits(tr, "relm_trace") || !is.data.frame(tr) ||
      !identical(attr(tr, "position_space", exact = TRUE), "model_context") ||
      !identical(attr(tr, "state_id", exact = TRUE), step$state_id)) {
    graphics_fail("trace_identity", "Use a live-state trace from this state, not an ordinary prompt trace.")
  }
  p <- attr(tr, "prompt_token_count", exact = TRUE)
  prompt <- attr(tr, "prompts", exact = TRUE)
  # Prompt names are input labels, not part of tokenization identity.
  if (is.character(prompt)) prompt <- unname(prompt)
  model <- attr(tr, "model", exact = TRUE)
  if (!graphics_number(p, 1, .Machine$integer.max, TRUE) ||
      !graphics_text(prompt) || !graphics_text(model, 16384) ||
      as.double(step$source_pos) != p + step$state_id - 1 ||
      step$steering_revision < 0L || step$steering_revision > step$applied_after_state ||
      step$applied_after_state < 0L || step$applied_after_state >= step$state_id ||
      (step$steering_revision == 0L && (step$applied_after_state != 0L || step$effective_source_pos != 1L)) ||
      (step$steering_revision > 0L && (step$applied_after_state == 0L || step$effective_source_pos != p + step$applied_after_state))) {
    graphics_fail("state_identity", "The prompt, state position or applied steering revision is inconsistent.")
  }
  if (!identical(class(steer), "data.frame")) graphics_fail("steering_audit", "The worker steering table is missing.")
  meta <- as.double(object.size(step)) + as.double(object.size(steer)) +
    as.double(object.size(prompt)) + as.double(object.size(model)) + 1024
  graphics_admit(32768 + 8 * meta, budget)
  graphics_steering(steer)
  if (logits) {
    lg <- state$logits
    if (!graphics_frame(lg, c("prompt_id", "rank", "token_id", "token", "logit", "prob"),
        c("integer", "integer", "integer", "character", "double", "double")) || nrow(lg) > 128L) {
      graphics_fail("logits_schema", "Supply the unchanged bounded top-logit table from on_state.")
    }
    meta <- meta + as.double(object.size(lg))
    graphics_admit(32768 + 8 * meta, budget)
    if (anyNA(lg) || any(!is.finite(lg$logit)) || any(!is.finite(lg$prob)) ||
        any(lg$prob < 0 | lg$prob > 1) || any(lg$prompt_id != 1L) ||
        any(lg$token_id < 1L) || anyDuplicated(lg$token_id) ||
        !identical(lg$rank, seq_len(nrow(lg))) ||
        any(!vapply(lg$token, graphics_text, logical(1), limit = 65536, empty = TRUE))) {
      graphics_fail("logits_values", "The top-logit table contains invalid values or token identities.")
    }
  }
  list(step = step, steering = steer, prompt = prompt, prompt_count = as.integer(p),
    model = model, metadata_bytes = meta)
}

graphics_named <- function(x, fields) {
  is.list(x) && !is.object(x) && identical(names(x), fields) &&
    identical(names(attributes(x)), "names")
}

graphics_context <- function(context, reference, intervention, budget) {
  fail <- function() abort_argument("context", "Provide matching recorded model/settings and the complete sampled-token history for each state.")
  if (!graphics_named(context, c("reference", "intervention"))) fail()
  settings <- c("seed", "chat", "temperature", "top_p", "max_tokens", "stop",
    "context_length", "backend", "relm_version", "engine_revision")
  bytes <- as.double(object.size(context))
  graphics_admit(32768 + 8 * bytes, budget)
  for (side in names(context)) {
    x <- context[[side]]
    if (!graphics_named(x, c("model_sha256", "settings", "generated_tokens")) ||
        !graphics_text(x$model_sha256, 64) || !grepl("^[0-9a-fA-F]{64}$", x$model_sha256) ||
        !graphics_named(x$settings, settings)) fail()
    s <- x$settings; ids <- x$generated_tokens; state <- if (side == "reference") reference else intervention
    if (!graphics_number(s$seed, 0, 2^64, TRUE) || s$seed >= 2^64 ||
        !is.logical(s$chat) || length(s$chat) != 1L || is.na(s$chat) || !is.null(attributes(s$chat)) ||
        !graphics_number(s$temperature, 0, 3.402823466e38) ||
        !graphics_number(s$top_p, 0, 1) || s$top_p == 0 ||
        !graphics_number(s$max_tokens, state$step$state_id, 1024, TRUE) ||
        !graphics_number(s$context_length, state$step$source_pos, .Machine$integer.max, TRUE) ||
        !graphics_text(s$backend, 32) || !s$backend %in% c("cpu", "metal", "cuda") ||
        !graphics_text(s$relm_version, 128) || !graphics_text(s$engine_revision, 256) ||
        !is.integer(ids) || !is.null(attributes(ids)) || length(ids) != state$step$state_id ||
        anyNA(ids) || any(ids < 1L) || utils::tail(ids, 1L) != state$step$token_id) fail()
    if (!is.null(s$stop) && (!is.character(s$stop) || !is.null(attributes(s$stop)) || length(s$stop) > 32L ||
        any(!vapply(s$stop, graphics_text, logical(1), limit = 16384, empty = TRUE)))) fail()
  }
  a <- context$reference; b <- context$intervention
  if (!identical(tolower(a$model_sha256), tolower(b$model_sha256)) || !identical(a$settings, b$settings) ||
      !identical(reference$prompt, intervention$prompt) ||
      !identical(Encoding(reference$prompt), Encoding(intervention$prompt)) ||
      reference$prompt_count != intervention$prompt_count) fail()
  # The state-k sampled ID is not yet part of the source prefix for state k.
  x <- utils::head(a$generated_tokens, -1L); y <- utils::head(b$generated_tokens, -1L)
  common <- min(length(x), length(y)); divergence <- NA_integer_
  if (common) for (i in seq_len(common)) if (x[i] != y[i]) { divergence <- i; break }
  if (is.na(divergence) && length(x) != length(y)) divergence <- common + 1L
  list(bytes = bytes, matched = is.na(divergence),
    first_divergence = if (is.na(divergence)) NA_integer_ else as.integer(reference$prompt_count + divergence),
    provenance = "caller-recorded model, settings and prompt; complete generated-ID prefix")
}
