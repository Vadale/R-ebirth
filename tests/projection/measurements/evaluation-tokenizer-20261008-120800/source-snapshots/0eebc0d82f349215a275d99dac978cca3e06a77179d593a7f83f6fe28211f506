# Base graphics only. All panels are rendered from the same returned tables.
graphics_options <- function(dots, title) {
  if (length(dots) && (is.null(names(dots)) || any(!nzchar(names(dots))) || anyDuplicated(names(dots)) ||
      any(!names(dots) %in% c("main", "cex", "col"))))
    abort_argument("...", "Plot options are named main, cex and col; unknown options are not ignored.")
  main <- if (is.null(dots$main)) title else dots$main
  cex <- if (is.null(dots$cex)) 1 else dots$cex
  col <- if (is.null(dots$col)) c("#2369A0", "#B35900", "#7047A3") else dots$col
  if (!graphics_text(main, 512, empty = TRUE)) abort_argument("main", "Use one bounded title string.")
  if (!graphics_number(cex, 0.25, 4)) abort_argument("cex", "Use a text scale from 0.25 through 4.")
  if (!is.character(col) || !length(col) %in% c(1L, 3L) || anyNA(col) ||
      inherits(tryCatch(grDevices::col2rgb(col), error = identity), "error"))
    abort_argument("col", "Use one or three valid R color strings; shape and labels also identify series.")
  if (grDevices::dev.cur() == 1L && !interactive() && Sys.getenv("RSTUDIO") != "1")
    abort_argument("device", "Open a caller-owned graphics device such as pdf() or png() before plotting in a script.")
  list(main = main, cex = cex, col = rep(col, length.out = 3L))
}

graphics_model_table <- function(x, layers) {
  if (!inherits(x, "llm")) abort_argument("x", "Supply an open llm model handle.")
  ensure_open(x)
  if (!graphics_number(x$layers, 1, .Machine$integer.max, TRUE) || !graphics_text(x$architecture, 128))
    abort_argument("x", "The model metadata is invalid; load a supported model again.")
  if (is.null(layers)) {
    if (x$layers > 32L) abort_argument("layers", "Select at most 32 layers explicitly for a legible block map.")
    layers <- seq_len(x$layers)
  }
  if (!is.numeric(layers) || is.object(layers) || length(layers) < 1L || length(layers) > 32L ||
      anyNA(layers) || any(!is.finite(layers)) || any(layers != floor(layers) | layers < 1 | layers > x$layers) || anyDuplicated(layers))
    abort_argument("layers", "Select up to 32 distinct, valid 1-based transformer layers.")
  layers <- sort(as.integer(layers))
  detailed <- x$architecture %in% c("llama", "qwen2")
  sites <- if (detailed) c("attn_out", "mlp_out", "residual") else "block"
  out <- data.frame(layer = rep(layers, each = length(sites)), site = rep(sites, length(layers)),
    detail = "", configured_steers = 0L, configured_ablations = 0L,
    configured_projections = 0L)
  for (i in seq_len(nrow(out))) {
    site <- out$site[i]
    out$detail[i] <- switch(site, attn_out = if (x$architecture == "llama")
      "Post-projection attention; observation site" else "Post-projection attention; capture unavailable for qwen2",
      mlp_out = "MLP output; observation site", residual = "Post-intervention residual; steer before ablate",
      block = "Generic block; internal topology not asserted")
    for (iv in x$interventions) {
      if (identical(iv$layer, out$layer[i])) {
        if (site %in% c("residual", "block")) {
          if (identical(iv$kind, "steer")) out$configured_steers[i] <- out$configured_steers[i] + 1L
          if (identical(iv$kind, "ablate")) out$configured_ablations[i] <- out$configured_ablations[i] + 1L
        }
        if (identical(iv$kind, "project") && (identical(iv$component, site) || site == "block"))
          out$configured_projections[i] <- out$configured_projections[i] + 1L
      }
    }
  }
  structure(out, architecture = x$architecture, layout_detail = if (detailed) "sequential schematic" else "generic blocks",
    total_layers = x$layers, vision_input = isTRUE(x$vision))
}

#' Draw a model block map and configured intervention sites
#'
#' The schematic describes architecture metadata, not measured activity, causal
#' influence or coefficients currently applied by an active worker. Unknown
#' architectures use generic blocks; unsupported captures are labelled.
#' @param x An open llm handle.
#' @param layers NULL for up to 32 blocks, or explicit unique 1-based indices.
#' @param ... Named main, cex or col (one or three colors).
#' @return Invisibly, the plain data frame of displayed sites and intervention
#'   counts. `configured_projections` counts static component projections,
#'   including zero coefficients; it does not count additive live revisions.
#' @seealso [llm_timeline()], [llm_compare()]
#' @examples
#' # Optional local model; never downloads a model during examples.
#' path <- Sys.getenv("RELM_EXAMPLE_MODEL", "")
#' if (nzchar(path) && file.exists(path)) {
#'   model <- llm(path, backend = "cpu")
#'   figure <- tempfile(fileext = ".pdf")
#'   grDevices::pdf(figure, width = 10, height = 7)
#'   tryCatch(plot(model, layers = 1:2),
#'            finally = { grDevices::dev.off(); close(model) })
#'   unlink(figure)
#' }
#' @export
plot.llm <- function(x, layers = NULL, ...) {
  tab <- graphics_model_table(x, layers)
  opts <- graphics_options(list(...), "Model blocks and configured interventions")
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old), add = TRUE)
  graphics::par(mar = c(3.6, 0.6, 3, 0.6), cex = opts$cex)
  graphics::plot.new(); graphics::plot.window(c(0, 1), c(0, 1))
  selected <- unique(tab$layer); n <- length(selected)
  columns <- max(1L, ceiling(n / 8L)); rows <- ceiling(n / columns)
  detailed <- attr(tab, "layout_detail") != "generic blocks"
  for (i in seq_along(selected)) {
    c <- (i - 1L) %/% rows; r <- (i - 1L) %% rows
    left <- c / columns + 0.015; right <- (c + 1L) / columns - 0.02
    y <- 1 - (r + 0.5) / rows; h <- min(0.09, 0.65 / rows)
    part <- tab[tab$layer == selected[i], , drop = FALSE]
    graphics::rect(left, y - h / 2, right, y + h / 2, border = "#B9C4CF", col = "#F6F8FA")
    graphics::text(left + 0.01, y + h * 0.31, paste("Layer", selected[i]), adj = 0, cex = 0.68, font = 2)
    if (detailed) {
      xs <- left + (right - left) * c(0.28, 0.58, 0.86)
      graphics::arrows(xs[1:2] + 0.055 / columns, y - h * 0.10,
        xs[2:3] - 0.04 / columns, y - h * 0.10, length = 0.045, col = "#8995A3")
      labels <- c("Attn", "MLP", "R")
      projected <- part$configured_projections > 0L
      labels[projected] <- sprintf("%s[P%d]", labels[projected], part$configured_projections[projected])
      graphics::text(xs, y - h * 0.10, labels, cex = 0.65, col = opts$col,
        font = ifelse(projected, 2, c(1, 1, 2)))
    } else graphics::text((left + right) / 2, y - h * 0.12, "Generic block", cex = 0.65)
    s <- sum(part$configured_steers); a <- sum(part$configured_ablations)
    p <- sum(part$configured_projections)
    label <- if (p) sprintf("P:%d  S:%d  A:%d", p, s, a) else if (s + a) sprintf("S:%d  A:%d", s, a) else if (selected[i] == 1L) "Steer unavailable" else "No intervention"
    graphics::text(right - 0.005, y + h * 0.31, label, adj = 1, cex = 0.48)
    previous <- if (i == 1L) 0L else selected[i - 1L]
    if (selected[i] > previous + 1L)
      graphics::text(left, y + h * 0.72, sprintf("... blocks %d-%d omitted", previous + 1L, selected[i] - 1L), adj = 0, cex = 0.48)
    if (i == n && selected[i] < attr(tab, "total_layers"))
      graphics::text(left, y - h * 0.72, sprintf("... blocks %d-%d omitted", selected[i] + 1L, attr(tab, "total_layers")), adj = 0, cex = 0.48)
  }
  graphics::title(main = opts$main, cex.main = 1.05)
  graphics::mtext(sprintf("%s | %s%s", attr(tab, "architecture"), attr(tab, "layout_detail"),
    if (isTRUE(attr(tab, "vision_input"))) " | external vision input" else ""), side = 3, line = 0.15, cex = 0.68)
  notice <- if (attr(tab, "architecture") == "qwen2") "Qwen2 attention output capture unavailable. " else ""
  graphics::mtext(paste0(notice, "Metadata, not activity or causal edges."), side = 1, line = 0.8, cex = 0.65)
  graphics::mtext("Attn: attention output   MLP: feed-forward output   R: residual", side = 1, line = 1.7, cex = 0.61)
  graphics::mtext("P: static component projection | S: residual steer, then A: ablate", side = 1, line = 2.5, cex = 0.61)
  invisible(tab)
}

#' @rdname llm_compare
#' @param x A relm_comparison returned by llm_compare().
#' @param ... Named main, cex or col (one or three colors).
#' @return The plot method returns the comparison invisibly.
#' @export
plot.relm_comparison <- function(x, ...) {
  if (!inherits(x, "relm_comparison") || !identical(names(x), c("layer", "component", "neuron", "reference", "intervention", "difference")) ||
      nrow(x) < 1L || !identical(attr(x, "schema_version"), 1L)) abort_argument("x", "Supply a nonempty llm_compare result.")
  opts <- graphics_options(list(...), "Observed state comparison")
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old), add = TRUE)
  graphics::par(mfrow = c(1, 3), mar = c(4.2, 4.1, 2.5, 1), oma = c(6, 0, 3, 0), cex = opts$cex)
  common <- range(c(x$reference, x$intervention), finite = TRUE)
  if (diff(common) == 0) common <- common + c(-1, 1) * max(1, abs(common[1]) * 0.05)
  matched <- isTRUE(attr(x, "alignment")$matched)
  for (i in 1:3) {
    values <- x[[c("reference", "intervention", "difference")[i]]]
    if (i == 3L && !matched) {
      graphics::plot.new(); graphics::text(0.5, 0.58, "Different input histories", font = 2, cex = 0.8)
      graphics::text(0.5, 0.42, "Differences withheld\nDescriptive comparison only", cex = 0.8)
    } else {
      lim <- if (i < 3L) common else { a <- max(abs(values)); if (a == 0) a <- 1; c(-a, a) }
      graphics::plot(x$neuron, values, type = if (length(values) <= 32L) "b" else "l", pch = c(16, 17, 15)[i],
        lty = i, col = opts$col[i], xlab = "Neuron (1-based)", ylab = if (i == 3L) "Intervention - reference" else "Activation", ylim = lim,
        main = c("Reference", "Intervention", "Difference")[i], cex.main = 0.9)
      graphics::abline(h = 0, col = "#CDD3DA", lty = 3)
    }
  }
  src <- attr(x, "source"); sampled <- attr(x, "outputs")$sampled
  graphics::mtext(opts$main, outer = TRUE, side = 3, line = 1.3, font = 2, cex = opts$cex)
  graphics::mtext(sprintf("Layer %d | %s | source positions %d / %d", x$layer[1], x$component[1], src$source_pos[1], src$source_pos[2]),
    outer = TRUE, side = 3, line = 0.1, cex = 0.72 * opts$cex)
  graphics::mtext(sprintf("Sampled token IDs: reference %d / intervention %d (not necessarily committed output)", sampled[1], sampled[2]),
    outer = TRUE, side = 1, line = 0.6, cex = 0.65 * opts$cex)
  lg <- attr(x, "outputs")$logits
  both <- which(!is.na(lg$reference_prob) & !is.na(lg$intervention_prob))
  text <- if (length(both)) paste(vapply(utils::head(both, 3L), function(i)
    sprintf("ID %d: p %.3f / %.3f", lg$token_id[i], lg$reference_prob[i], lg$intervention_prob[i]), character(1)), collapse = "   ") else "No common top-k entries"
  graphics::mtext(text, outer = TRUE, side = 1, line = 1.8, cex = 0.60 * opts$cex)
  graphics::mtext("Truncated top-k; absent entries are unknown", outer = TRUE, side = 1, line = 2.8, cex = 0.60 * opts$cex)
  graphics::mtext(if (matched) "Aligned under caller-recorded context; not authenticated provenance or a general causal claim"
    else "Different input histories; descriptive comparison only", outer = TRUE, side = 1, line = 4.1, cex = 0.61 * opts$cex)
  invisible(x)
}

#' @rdname llm_timeline
#' @param x A relm_timeline returned by llm_timeline(), optionally row-filtered
#'   to at most 16 intervention IDs for rendering.
#' @param ... Named main, cex or col (one or three colors).
#' @return The plot method returns the history invisibly.
#' @export
plot.relm_timeline <- function(x, ...) {
  if (!inherits(x, "relm_timeline") || !nrow(x) || !identical(attr(x, "schema_version"), 1L))
    abort_argument("x", "Supply a nonempty llm_timeline result.")
  ids <- sort(unique(x$intervention[!is.na(x$intervention)]))
  if (length(ids) > 16L) abort_argument("x", "Explicitly subset the table to at most 16 interventions before plotting.")
  opts <- graphics_options(list(...), "Applied steering over sampled states")
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old), add = TRUE)
  graphics::par(mfrow = c(2, 1), mar = c(3.2, 4.2, 1.8, 1), oma = c(4, 0, 2.7, 0), cex = opts$cex)
  steps <- x[!duplicated(x$state_id), , drop = FALSE]
  graphics::plot(steps$state_id, steps$token_id, type = "b", pch = 16, col = opts$col[1],
    xlab = "Sampled state", ylab = "Token ID", main = "Sampled tokens (not final text)", cex.main = 0.85)
  if (length(ids)) {
    lim <- range(x$coef, finite = TRUE); if (diff(lim) == 0) lim <- lim + c(-1, 1)
    graphics::plot(range(x$state_id), lim, type = "n", xlab = "State whose source decode used the coefficient", ylab = "Applied coefficient")
    for (i in seq_along(ids)) {
      part <- x[x$intervention == ids[i] & !is.na(x$intervention), , drop = FALSE]
      col <- opts$col[(i - 1L) %% 3L + 1L]; lty <- (i - 1L) %% 6L + 1L
      graphics::lines(part$state_id, part$coef, type = "s", col = col, lty = lty, lwd = 1.5)
      graphics::points(part$state_id, part$coef, pch = (i - 1L) %% 6L + 15L, col = col, cex = 0.45)
    }
    graphics::legend("topright", legend = paste("Intervention", ids), col = rep(opts$col, length.out = length(ids)),
      lty = (seq_along(ids) - 1L) %% 6L + 1L, ncol = max(1L, ceiling(length(ids) / 4)), cex = 0.55, bty = "n")
    changes <- steps[!duplicated(steps$steering_revision) & steps$steering_revision > 0L, , drop = FALSE]
    positions <- graphics_change_states(steps)
    if (length(positions)) graphics::abline(v = positions, col = "#7B8794", lty = 3)
    if (nrow(changes)) {
      last <- changes[nrow(changes), ]
      graphics::mtext(sprintf("Latest recorded change: after state %d; effective source %d", last$applied_after_state, last$effective_source_pos), side = 3, line = 0.25, cex = 0.67)
    }
  } else { graphics::plot.new(); graphics::text(0.5, 0.5, "No steering entries in this run") }
  graphics::mtext(opts$main, outer = TRUE, side = 3, line = 1, font = 2, cex = opts$cex)
  graphics::mtext(sprintf("Retained states %d-%d | %d earlier states dropped", min(x$state_id), max(x$state_id), attr(x, "dropped_states")),
    outer = TRUE, side = 1, line = 0.8, cex = 0.69 * opts$cex)
  graphics::mtext("Worker-applied audit, not reply intent | Zero coefficient does not reset KV history", outer = TRUE, side = 1, line = 2, cex = 0.65 * opts$cex)
  invisible(x)
}

graphics_change_states <- function(steps) {
  # A retained positive revision may have started before the visible window.
  # Its last-change audit survives truncation; never move that change forward.
  changes <- unique(steps$applied_after_state[steps$steering_revision > 0L] + 1L)
  changes[changes >= min(steps$state_id) & changes <= max(steps$state_id)]
}
