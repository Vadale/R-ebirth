# Selected live capture reading. One vector is retained per reader; Arrow batches
# are checked before conversion, and no whole-trace matrix is built.
graphics_trace_shape <- function(x, step, layer, component) {
  columns <- c("prompt_id", "token_pos", "token", "layer", "component", "neuron", "value")
  types <- c("integer", "integer", "character", "integer", "character", "integer", "double")
  if (!identical(class(x), c("relm_trace", "data.frame")) || !identical(names(x), columns) ||
      !all(vapply(seq_along(types), function(i) identical(typeof(x[[i]]), types[i]) &&
        is.null(attributes(x[[i]])) && length(x[[i]]) == nrow(x), logical(1)))) {
    graphics_fail("trace_schema", "The live trace has an invalid column or coordinate schema.")
  }
  spilled <- attr(x, "spilled", exact = TRUE)
  if (identical(spilled, TRUE)) {
    n <- attr(x, "spill_n_embd", exact = TRUE); b <- attr(x, "live_batch_bytes", exact = TRUE)
    if (nrow(x) != 0L || !graphics_number(n, 1, .Machine$integer.max, TRUE) ||
        !graphics_number(b, 1, 2^53, TRUE) ||
        !identical(attr(x, "live_batch_rows", exact = TRUE), 4096L) ||
        !identical(attr(x, "live_source_pos", exact = TRUE), step$source_pos) ||
        !layer %in% attr(x, "spill_layers", exact = TRUE) ||
        !component %in% attr(x, "spill_components", exact = TRUE) ||
        !isTRUE(attr(x, "spill_n_positions", exact = TRUE) == 1)) {
      graphics_fail("spill_shape", "The spill metadata does not contain this live layer/component and source position.")
    }
    return(list(width = as.integer(n), arrow = 4 * (b + 256 * 4096 + 32768)))
  }
  if (!identical(spilled, FALSE)) graphics_fail("trace_schema", "The live trace spill status is invalid.")
  count <- 0; width <- 0L
  for (i in seq_len(nrow(x))) {
    if (is.na(x$layer[i]) || is.na(x$component[i])) graphics_fail("trace_coordinate", "Trace coordinates cannot be missing.")
    if (x$layer[i] == layer && x$component[i] == component) {
      n <- x$neuron[i]
      if (is.na(n) || n < 1L) graphics_fail("trace_coordinate", "Neuron coordinates must be positive integers.")
      count <- count + 1; width <- max(width, n)
    }
  }
  if (count == 0 || count != width) graphics_fail("trace_coverage", "The requested live vector is missing or has incomplete coordinates.")
  list(width = width, arrow = 0)
}

graphics_read_vector <- function(x, step, layer, component, width, bound) {
  values <- numeric(width); seen <- logical(width)
  visit <- function(df, shift = 0L) {
    for (i in seq_len(nrow(df))) {
      if (is.na(df$layer[i]) || is.na(df$component[i])) graphics_fail("trace_coordinate", "Trace coordinates cannot be missing.")
      if (df$layer[i] + shift == layer && df$component[i] == component) {
        n <- as.double(df$neuron[i]) + shift
        if (!graphics_number(n, 1, width, TRUE) || is.na(df$prompt_id[i]) ||
            is.na(df$token_pos[i]) || df$prompt_id[i] + shift != 1 ||
            as.double(df$token_pos[i]) + shift != step$source_pos ||
            !is.finite(df$value[i]) || seen[n]) {
          graphics_fail("trace_coordinate", "The selected live vector contains duplicate, invalid or mismatched coordinates.")
        }
        values[n] <<- df$value[i]; seen[n] <<- TRUE
      }
    }
    invisible(NULL)
  }
  if (!isTRUE(attr(x, "spilled", exact = TRUE))) {
    visit(x)
  } else {
    path <- attr(x, "spill_files", exact = TRUE)
    if (!graphics_text(path, 16384) || !file.exists(path) || dir.exists(path)) {
      graphics_fail("spill_missing", "The live spill file is unavailable; collect a fresh observation.")
    }
    verify_spill_integrity(x, path)
    tryCatch({
      stream <- nanoarrow::read_nanoarrow(path, lazy = TRUE)
      repeat {
        batch <- stream$get_next()
        if (is.null(batch)) break
        live_check_arrow_batch(batch, x)
        df <- as.data.frame(batch)
        graphics_stage(bound, values, seen, df)
        visit(df, 1L)
        rm(df, batch)
      }
    }, error = function(e) {
      if (inherits(e, "relm_error")) stop(e)
      relm_abort("relm_error_trace", "The live spill could not be converted safely; collect a fresh observation.",
        list(reason = "spill_read", parent = e))
    })
  }
  if (!all(seen)) graphics_fail("trace_coverage", "The selected live vector has missing neuron coordinates.")
  graphics_stage(bound, values, seen)
  values
}

#' Compare actual observed states under recorded experimental settings
#'
#' Builds an ordinary data frame from two delivered `on_state` observations.
#' No inference is performed. Differences are withheld when the complete sampled
#' input histories diverge. Caller-recorded context is validated, not authenticated.
#'
#' @param reference,intervention Single observations from `llm_generate(on_state=)`.
#' @param context A list with `reference` and `intervention` entries, each holding
#'   `model_sha256`, `settings`, and integer `generated_tokens` through its state.
#'   Settings contain, in order, `seed`, `chat`, `temperature`, `top_p`, `max_tokens`,
#'   `stop`, `context_length`, `backend`, `relm_version`, `engine_revision`.
#' @param layer One 1-based captured transformer layer.
#' @param component One of `residual`, `attn_out`, `mlp_out`.
#' @param neurons NULL for all captured coordinates, or unique 1-based indices.
#' @param max_bytes Working materialization budget, whole bytes from 64 KiB to 256 MiB.
#' @return A `relm_comparison` data frame with layer, component, neuron, reference,
#'   intervention and difference. Attributes retain bounded provenance, alignment,
#'   applied steering and a truncated logit comparison, never the original traces.
#' @details
#' The input for state k excludes its just-sampled token. Equal model/settings/
#' prompt records establish prompt identity; every earlier sampled token must
#' also match. A divergent history keeps the observations but returns NA differences.
#' Missing top-k entries are NA, not zero probabilities. A sampled token may never
#' appear in committed output after cancellation or stop removal. Returning a
#' coefficient to zero does not erase prior effects in KV history.
#' @seealso [llm_timeline()], [llm_generate()]
#' @export
llm_compare <- function(reference, intervention, context, layer,
                        component = "residual", neurons = NULL,
                        max_bytes = 64 * 1024^2) {
  budget <- graphics_budget(max_bytes, 256 * 1024^2)
  if (!graphics_number(layer, 1, .Machine$integer.max, TRUE)) abort_argument("layer", "Select one positive integer layer.")
  if (!graphics_text(component, 32) || !component %in% c("residual", "attn_out", "mlp_out"))
    abort_argument("component", "Select residual, attn_out or mlp_out.")
  a <- graphics_state(reference, budget); b <- graphics_state(intervention, budget)
  alignment <- graphics_context(context, a, b, budget)
  sa <- graphics_trace_shape(reference$trace, a$step, layer, component)
  sb <- graphics_trace_shape(intervention$trace, b$step, layer, component)
  if (sa$width != sb$width) graphics_fail("trace_coverage", "The two selected live vectors have different neuron coordinates.")
  metadata <- a$metadata_bytes + b$metadata_bytes + alignment$bytes
  count <- nrow(reference$logits) + nrow(intervention$logits)
  estimate <- 32768 + 8 * metadata + 2048 * (sa$width + count) + max(sa$arrow, sb$arrow)
  graphics_admit(estimate, budget)
  if (is.null(neurons)) neurons <- seq_len(sa$width) else {
    if (!is.numeric(neurons) || is.object(neurons) || length(neurons) == 0L ||
        length(neurons) > sa$width || anyNA(neurons) || any(!is.finite(neurons)) ||
        any(neurons != floor(neurons) | neurons < 1 | neurons > sa$width) || anyDuplicated(neurons))
      abort_argument("neurons", "Select unique valid neuron indices present in both observations.")
    neurons <- sort(as.integer(neurons))
  }
  av <- graphics_read_vector(reference$trace, a$step, layer, component, sa$width, estimate)
  bv <- graphics_read_vector(intervention$trace, b$step, layer, component, sb$width, estimate)
  x <- data.frame(layer = rep.int(as.integer(layer), length(neurons)),
    component = rep.int(component, length(neurons)), neuron = neurons,
    reference = av[neurons], intervention = bv[neurons],
    difference = if (alignment$matched) bv[neurons] - av[neurons] else rep.int(NA_real_, length(neurons)))
  lga <- reference$logits; lgb <- intervention$logits
  ids <- sort(unique(c(lga$token_id, lgb$token_id)))
  ia <- match(ids, lga$token_id); ib <- match(ids, lgb$token_id)
  lg <- data.frame(token_id = ids, reference_logit = lga$logit[ia], intervention_logit = lgb$logit[ib],
    reference_prob = lga$prob[ia], intervention_prob = lgb$prob[ib])
  lg$difference_logit <- if (alignment$matched) lg$intervention_logit - lg$reference_logit else rep.int(NA_real_, length(ids))
  lg$difference_prob <- if (alignment$matched) lg$intervention_prob - lg$reference_prob else rep.int(NA_real_, length(ids))
  alignment$bytes <- NULL
  x <- structure(x, class = c("relm_comparison", "data.frame"), schema_version = 1L,
    context = context, alignment = alignment,
    source = data.frame(side = c("reference", "intervention"), state_id = c(a$step$state_id, b$step$state_id),
      source_pos = c(a$step$source_pos, b$step$source_pos)),
    steering = list(reference = a$steering, intervention = b$steering),
    outputs = list(sampled = c(reference = a$step$token_id, intervention = b$step$token_id), logits = lg),
    estimate_bytes = estimate, max_bytes = budget)
  graphics_stage(estimate, av, bv, x, lg, ids, ia, ib, neurons, a, b)
  x
}
