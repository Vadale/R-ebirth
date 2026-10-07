graphics_audit_transition <- function(previous, prior_steering, step, steering) {
  same_revision <- step$steering_revision == previous$steering_revision
  if (step$state_id != previous$state_id + 1L || step$elapsed < previous$elapsed ||
      step$source_pos != previous$source_pos + 1L ||
      !identical(steering$intervention, prior_steering$intervention) ||
      !identical(steering$layer, prior_steering$layer) ||
      !(step$steering_revision %in% c(previous$steering_revision, previous$steering_revision + 1L)) ||
      (same_revision && (!identical(steering$coef, prior_steering$coef) ||
        step$applied_after_state != previous$applied_after_state ||
        step$effective_source_pos != previous$effective_source_pos)) ||
      (!same_revision && (identical(steering$coef, prior_steering$coef) ||
        step$applied_after_state != previous$state_id || step$effective_source_pos != step$source_pos))) {
    graphics_fail("timeline_sequence", "Append the next unchanged worker audit from the same generation; do not splice or reorder states.")
  }
  invisible(NULL)
}

graphics_rows <- function(x, rows, columns) {
  out <- lapply(columns, function(nm) x[[nm]][rows]); names(out) <- columns
  as.data.frame(out, stringsAsFactors = FALSE)
}

#' Retain a bounded history of applied live steering
#'
#' Appends the next on_state audit, dropping oldest complete states to respect
#' the explicit working budget and retention window. No activations or model
#' handles are retained. The table records sampled states, not committed text.
#'
#' @param state A single observation delivered to `on_state`.
#' @param history NULL to start at state 1, or the previous returned history.
#' @param max_states Number of newest whole states to retain, from 1 through 1024.
#' @param max_bytes Working materialization budget, whole bytes from 64 KiB to 64 MiB.
#' @return A `relm_timeline` data frame containing step columns followed by
#'   intervention, layer and coef, plus explicit retained/dropped ranges.
#' @details
#' Inside a callback assign `history <- llm_timeline(state, history)`, then
#' explicitly return NULL or the intended steering reply. Do not return this
#' history as a callback reply. A change requested at state k applies to the
#' next decode, and setting a coefficient to zero does not clear KV history.
#' The helper validates consistency of editable R records, not their origin.
#' @seealso [llm_compare()], [llm_generate()]
#' @export
llm_timeline <- function(state, history = NULL, max_states = 256L,
                         max_bytes = 8 * 1024^2) {
  budget <- graphics_budget(max_bytes, 64 * 1024^2)
  if (!graphics_number(max_states, 1, 1024, TRUE)) abort_argument("max_states", "Use an integer window from 1 through 1024 states.")
  info <- graphics_state(state, budget, logits = FALSE)
  step <- info$step; steering <- info$steering
  cols <- c(names(step), "intervention", "layer", "coef")
  block <- max(1L, nrow(steering))
  fixed <- 32768 + 8 * info$metadata_bytes
  graphics_admit(fixed + 2048 * block, budget)
  prior_count <- 0L; dropped <- 0L
  identity <- list(prompt = info$prompt, prompt_token_count = info$prompt_count, model = info$model)
  if (is.null(history)) {
    if (step$state_id != 1L) graphics_fail("timeline_start", "Start a new history with state 1; do not invent missing earlier states.")
  } else {
    if (!identical(class(history), c("relm_timeline", "data.frame")) || !identical(names(history), cols) ||
        !identical(attr(history, "schema_version", exact = TRUE), 1L) ||
        !identical(attr(history, "identity", exact = TRUE), identity) || nrow(history) < block ||
        nrow(history) %% block != 0 || nrow(history) / block > 1024 ||
        !graphics_number(attr(history, "dropped_states", exact = TRUE), 0, 1023, TRUE)) {
      graphics_fail("timeline_history", "Supply a complete previous llm_timeline result from this run, or NULL at state 1.")
    }
    expected_types <- unname(c(vapply(step, typeof, character(1)), "integer", "integer", "double"))
    if (!all(vapply(seq_along(cols), function(i) identical(typeof(history[[i]]), expected_types[i]) &&
        is.null(attributes(history[[i]])) && length(history[[i]]) == nrow(history), logical(1)))) {
      graphics_fail("timeline_schema", "The timeline's column schema has been modified.")
    }
    prior_count <- as.integer(nrow(history) / block)
    dropped <- as.integer(attr(history, "dropped_states", exact = TRUE))
    previous <- NULL; prior_steer <- NULL
    for (g in seq_len(prior_count)) {
      first <- (g - 1L) * block + 1L; rows <- seq.int(first, length.out = block)
      current <- graphics_rows(history, first, names(step))
      if (!identical(current$state_id, dropped + g) || current$prompt_id != 1L ||
          current$token_pos != current$state_id || is.na(current$token_id) || current$token_id < 1L ||
          current$source_pos != info$prompt_count + current$state_id - 1L ||
          current$context_pos != current$source_pos + 1L || !is.finite(current$elapsed) || current$elapsed < 0 ||
          !identical(current$source, if (current$state_id == 1L) "prompt" else "generated") ||
          anyNA(current) || current$steering_revision < 0L || current$applied_after_state < 0L ||
          current$applied_after_state >= current$state_id || current$steering_revision > current$applied_after_state ||
          (current$steering_revision == 0L && (current$applied_after_state != 0L || current$effective_source_pos != 1L)) ||
          (current$steering_revision > 0L && current$effective_source_pos != info$prompt_count + current$applied_after_state)) {
        graphics_fail("timeline_history", "The retained timeline contains inconsistent state coordinates.")
      }
      for (nm in names(step)) for (r in rows) if (!identical(history[[nm]][r], current[[nm]]))
        graphics_fail("timeline_history", "All rows belonging to one state must have identical step data.")
      audit <- graphics_rows(history, rows, c("intervention", "layer", "coef"))
      if (nrow(steering) == 0L) {
        if (!all(is.na(audit))) graphics_fail("steering_audit", "A no-steering history must use the missing-value audit row.")
        audit <- steering
      } else graphics_steering(audit)
      if (!is.null(previous)) graphics_audit_transition(previous, prior_steer, current, audit)
      previous <- current; prior_steer <- audit
    }
    graphics_audit_transition(previous, prior_steer, step, steering)
  }
  allowed <- min(as.integer(max_states), floor((budget - fixed) / (2048 * block)))
  keep <- min(prior_count, allowed - 1L)
  estimate <- fixed + 2048 * block * (keep + 1L)
  graphics_admit(estimate, budget)
  add <- step[rep.int(1L, block), , drop = FALSE]
  audit <- if (nrow(steering)) steering else data.frame(intervention = NA_integer_, layer = NA_integer_, coef = NA_real_)
  add <- cbind(add, audit); rownames(add) <- NULL
  if (keep) {
    old <- graphics_rows(history, seq.int(nrow(history) - keep * block + 1L, nrow(history)), cols)
    out <- rbind(old, add)
  } else { old <- NULL; out <- add }
  dropped <- as.integer(dropped + prior_count - keep)
  out <- structure(out, class = c("relm_timeline", "data.frame"), schema_version = 1L,
    identity = identity, original_range = c(1L, step$state_id),
    retained_range = c(dropped + 1L, step$state_id), dropped_states = dropped,
    max_states = as.integer(max_states), max_bytes = budget, estimate_bytes = estimate)
  graphics_stage(estimate, out, old, add, audit, info)
  out
}
