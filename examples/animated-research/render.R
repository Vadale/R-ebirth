# Render recorded relm observations. No package load, model, inference or RNG.
# Run from the repository root: Rscript examples/animated-research/render.R
# Requires an existing ffmpeg executable for GIF/MP4 encoding; base R plots.
args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args)) args[[1L]] else "docs/media/research"
selected <- if (length(args) > 1L) {
  match.arg(args[[2L]], c("all", "activation", "stream"))
} else "all"
input <- "examples/research-first-use/recorded"
stopifnot(dir.exists(input), nzchar(Sys.which("ffmpeg")))
dir.create(out, recursive = TRUE, showWarnings = FALSE)
frames <- tempfile("relm-recorded-frames-", tmpdir = normalizePath(out))
dir.create(frames)
# Keep temporary frames available for visual inspection or recovery.

results <- readRDS(file.path(input, "all-results.rds"))
comparison <- readRDS(file.path(input, "direct-comparison.rds"))
original <- results[["direct-original"]]
zero <- results[["direct-zero"]]
addition <- results[["direct-addition"]]
stopifnot(
  identical(original$ids, zero$ids), identical(original$text, zero$text),
  identical(original$first$trace$value, zero$first$trace$value),
  identical(original$first$logits, zero$first$logits),
  identical(comparison$neuron, 1:896),
  identical(comparison$reference, original$first$trace$value),
  identical(comparison$intervention, addition$first$trace$value),
  identical(comparison$difference,
            comparison$intervention - comparison$reference),
  isTRUE(attr(comparison, "alignment")$matched),
  identical(original$first$trace$token_pos, addition$first$trace$token_pos),
  identical(original$first$trace$token, addition$first$trace$token),
  all(is.finite(as.matrix(comparison[, 4:6])))
)

# For this retained run, every token event is immediately followed by exactly
# one committed-text event. Check the actual order before mapping text to steps.
# Other event batching patterns need a different collector; never guess a join.
stream <- function(x) {
  e <- x$events
  n <- length(x$ids)
  stopifnot(nrow(e) == 2L * n + 1L,
            identical(e$event, c(rep(c("token", "text"), n), "prompt_end")),
            identical(e$token_pos[e$event == "token"], seq_len(n)),
            identical(e$token_id[e$event == "token"], x$ids),
            identical(x$timeline$token_id, x$ids))
  pieces <- e$text[e$event == "text"]
  text <- vapply(seq_len(n), function(i) paste0(pieces[seq_len(i)], collapse = ""), "")
  stopifnot(identical(tail(text, 1L)[[1L]], unname(x$text[[1L]])))
  list(text = c("", text), characters = c(0L, nchar(text, type = "chars")),
       n = n, finish = tail(e$finish_reason, 1L))
}
streams <- lapply(list(original, addition), stream)
divergence <- which(original$ids != addition$ids[seq_along(original$ids)])[[1L]]
stopifnot(divergence == 4L, streams[[1L]]$n == 33L, streams[[2L]]$n == 48L)

palette <- list(bg = "#F6F4ED", ink = "#162B3B", muted = "#536873",
                grid = "#DDDCD4", teal = "#087F83", amber = "#BF601B",
                white = "#FFFFFF", pale = "#E7EEEB")
W <- 1200L
H <- 760L
fps <- 6L
label <- function(x, y, s, size = 1, color = palette$ink, bold = FALSE,
                  adj = c(0, 0.5), family = "sans") {
  text(x, y, s, cex = size, col = color, font = if (bold) 2 else 1,
       adj = adj, family = family, xpd = NA)
}
canvas <- function(path, number, title, subtitle, code) {
  png(path, width = W, height = H, res = 100, bg = palette$bg)
  par(mar = rep(0, 4), family = "sans", xaxs = "i", yaxs = "i")
  plot.new()
  plot.window(c(0, 1), c(0, 1))
  label(.04, .963, paste0("relm  /  RECORDED RESEARCH  /  ", number), .95,
        palette$teal, TRUE)
  label(.04, .909, title, 2.15, bold = TRUE)
  label(.04, .855, subtitle, 1.02, palette$muted)
  rect(.04, .758, .96, .815, col = palette$ink, border = NA)
  label(.057, .786, code, .98, "#F6F4ED", family = "mono")
}
panel <- function(box, xlim, ylim, margins = c(2.7, 3.5, 1, 1)) {
  par(fig = box, mar = margins, new = TRUE, mgp = c(1.8, .5, 0),
      col.axis = palette$muted, col.lab = palette$muted, cex.axis = .82)
  plot(NA, xlim = xlim, ylim = ylim, xlab = "", ylab = "", axes = FALSE,
       xaxs = "i", yaxs = "i")
}
overlay <- function() {
  par(fig = c(0, 1, 0, 1), mar = rep(0, 4), new = TRUE)
  plot(NA, xlim = c(0, 1), ylim = c(0, 1), axes = FALSE, xlab = "", ylab = "",
       xaxs = "i", yaxs = "i")
}
footer <- function(line) {
  overlay()
  label(.04, .064, line, .89, palette$muted)
  label(.04, .029, "Qwen2.5-0.5B Q8_0  |  relm 0.4.0  |  CPU  |  recorded 12 Oct 2026", .82,
        palette$muted)
}

activation_frame <- function(path, stage, shown) {
  active <- stage == 3L
  captions <- c("Capture an internal state", "Check that zero changes nothing",
                "Measure a controlled intervention")
  code <- c("llm_generate(..., layers = 12L, components = \"residual\", on_state = ...)",
            "llm_apply_direction(m, direction, model_record, coef = 0, operator = \"add\")",
            "llm_apply_direction(m, direction, model_record, coef = 1, operator = \"add\")")
  canvas(path, "01", captions[[stage]],
         "One shared prompt and prefix. Layer 12, residual stream. All 896 coordinates.",
         code[[stage]])
  label(.064, .706, "ACTIVATIONS", .91, bold = TRUE)
  label(.352, .706, "Original", .87, palette$ink)
  if (stage > 1L) label(.443, .706, if (active) "Addition = 1" else "Zero control",
                        .87, palette$teal)
  panel(c(.035, .64, .423, .68), c(1, 896), c(-8, 8))
  abline(h = c(-8, 0, 8), col = palette$grid)
  axis(2, at = c(-8, 0, 8), las = 1, tick = FALSE)
  axis(1, at = c(1, 224, 448, 672, 896), tick = FALSE)
  lines(comparison$neuron[seq_len(shown)], comparison$reference[seq_len(shown)],
        col = palette$ink, lwd = 1.1)
  if (stage > 1L) {
    value <- if (active) comparison$intervention else comparison$reference
    lines(comparison$neuron[seq_len(shown)], value[seq_len(shown)],
          col = adjustcolor(palette$teal, .75), lwd = 1.1)
  }
  overlay()
  label(.064, .404, "DIFFERENCE FROM ORIGINAL", .91, bold = TRUE)
  label(.352, .404, if (active) "Measured change" else "Zero reference", .87,
        if (active) palette$amber else palette$muted)
  panel(c(.035, .64, .13, .379), c(1, 896), c(-.15, .15))
  abline(h = c(-.15, 0, .15), col = palette$grid)
  axis(2, at = c(-.15, 0, .15), las = 1, tick = FALSE)
  axis(1, at = c(1, 224, 448, 672, 896), tick = FALSE)
  title(xlab = "Neuron index", cex.lab = .88)
  delta <- if (active) comparison$difference else rep(0, 896)
  lines(seq_len(shown), delta[seq_len(shown)],
        col = if (active) palette$amber else palette$teal, lwd = 1.35)

  overlay()
  label(.695, .706, "NEXT-TOKEN DISTRIBUTION", .91, bold = TRUE)
  label(.695, .675, "Saved first-state probabilities", .86, palette$muted)
  p <- original$first$logits
  q <- if (active) addition$first$logits else p
  q <- q[match(p$token_id, q$token_id), ]
  stopifnot(!anyNA(q$prob), all(is.finite(q$prob)))
  for (i in 1:5) {
    y <- .616 - (i - 1) * .082
    label(.695, y + .018, paste0('"', p$token[[i]], '"'), .88, family = "mono")
    rect(.695, y - .011, .695 + .24 * p$prob[[i]] / .1, y,
         col = palette$ink, border = NA)
    if (stage > 1L) rect(.695, y - .026, .695 + .24 * q$prob[[i]] / .1, y - .015,
                         col = palette$teal, border = NA)
  }
  label(.695, .195, "0%", .79, palette$muted)
  label(.935, .195, "10%", .79, palette$muted, adj = c(1, .5))
  label(.695, .147, "Top 5 only; not answer correctness.", .80, palette$muted)
  label(.695, .113, sprintf("%03d / 896 coordinates revealed", shown), .79,
        palette$muted)
  footer("Saved measurements, revealed without interpolation. Both conditions sampled the same first token: \" New\".")
  dev.off()
}

wrap_preserving_lines <- function(text, width = 45L) {
  unlist(lapply(strsplit(text, "\n", fixed = TRUE)[[1L]], function(s) {
    if (!nzchar(s)) "" else strwrap(s, width = width)
  }), use.names = FALSE)
}
stream_frame <- function(path, step) {
  canvas(path, "02", "Watch the answer unfold",
         "Token events become an inspectable record. Two separately recorded runs; fixed addition = 1.",
         "llm_generate(..., async = TRUE, on_token = ..., on_state = ...)")
  label(.066, .706, "COMMITTED TEXT", .90, bold = TRUE)
  label(.574, .706, "Original", .88, palette$ink)
  label(.690, .706, "Addition = 1", .88, palette$amber)
  label(.830, .706, "Zero = original", .86, palette$teal)
  panel(c(.04, .955, .421, .68), c(0, 48), c(0, 220))
  abline(h = c(0, 100, 200), col = palette$grid)
  axis(2, at = c(0, 100, 200), las = 1, tick = FALSE)
  axis(1, at = c(0, 12, 24, 36, 48), tick = FALSE)
  title(xlab = "Sampled-token position within each run", ylab = "Characters", cex.lab = .84)
  for (i in 1:2) {
    s <- streams[[i]]
    k <- min(step, s$n)
    color <- if (i == 1L) palette$ink else palette$amber
    lines(0:k, s$characters[seq_len(k + 1L)], type = "s", col = color, lwd = 2.2)
    points(k, s$characters[[k + 1L]], pch = 19, col = color, cex = 1.15)
  }
  if (step >= divergence) {
    abline(v = divergence, col = palette$teal, lty = 3)
    text(divergence + 1, 206, "Token histories diverge here", adj = 0, cex = .86,
         col = palette$teal)
  }
  overlay()
  for (i in 1:2) {
    left <- if (i == 1L) .04 else .512
    right <- left + .448
    s <- streams[[i]]
    k <- min(step, s$n)
    rect(left, .113, right, .410, col = palette$white, border = palette$grid)
    label(left + .016, .382, if (i == 1L) "ORIGINAL" else "RESIDUAL ADDITION = 1",
          .94, if (i == 1L) palette$ink else palette$amber, TRUE)
    status <- if (step >= s$n) paste0("  |  finish: ", s$finish) else ""
    label(left + .016, .350, paste0(k, " tokens / ", s$characters[[k + 1L]],
                                   " characters", status), .83, palette$muted)
    text <- if (k == 0L) "[waiting for first saved token]" else s$text[[k + 1L]]
    lines <- wrap_preserving_lines(text)
    stopifnot(length(lines) <= 7L)
    label(left + .016, .316, paste(lines, collapse = "\n"), .88,
          adj = c(0, 1), family = "mono")
  }
  footer("Both answers invent missing facts. Playback uses equal time per token, not measured generation speed.")
  dev.off()
}

# The visual schedule changes presentation only: no fabricated intermediate data.
schedule <- rbind(data.frame(stage = 1L, shown = c(seq(56L, 896L, 56L), rep(896L, 10L))),
                  data.frame(stage = 2L, shown = rep(896L, 14L)),
                  data.frame(stage = 3L, shown = c(seq(56L, 896L, 56L), rep(896L, 24L))))
encode <- function(name, render, count, poster) {
  folder <- file.path(frames, name)
  dir.create(folder)
  for (i in seq_len(count)) render(file.path(folder, sprintf("%04d.png", i)), i)
  run <- function(args) {
    status <- system2(Sys.which("ffmpeg"), c("-hide_banner", "-loglevel", "warning", "-y", args))
    if (status != 0L) stop("ffmpeg failed; retained frames: ", folder)
  }
  sequence <- shQuote(file.path(folder, "%04d.png"))
  run(c("-framerate", fps, "-i", sequence, "-vf",
        shQuote("split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=none"),
        "-loop", "0", shQuote(file.path(out, paste0(name, ".gif")))))
  run(c("-framerate", fps, "-i", sequence, "-c:v", "libx264", "-crf", "20",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an",
        shQuote(file.path(out, paste0(name, ".mp4")))))
  file.copy(file.path(folder, sprintf("%04d.png", poster)),
            file.path(out, paste0(name, ".png")), overwrite = TRUE)
  cat(name, ":", count, "frames;", count / fps, "seconds\n")
}
if (selected %in% c("all", "activation")) {
  encode("activation-intervention", function(path, i) {
    activation_frame(path, schedule$stage[[i]], schedule$shown[[i]])
  }, nrow(schedule), nrow(schedule))
}
steps <- c(rep(0L, 8L), 1:48, rep(48L, 22L))
if (selected %in% c("all", "stream")) {
  encode("token-stream", function(path, i) stream_frame(path, steps[[i]]), length(steps), length(steps))
}
write.csv(data.frame(frame = seq_len(nrow(schedule)), schedule),
          file.path(out, "activation-frames.csv"), row.names = FALSE)
write.csv(data.frame(frame = seq_along(steps), sampled_position = steps),
          file.path(out, "stream-frames.csv"), row.names = FALSE)
write.csv(data.frame(neuron = comparison$neuron, original = comparison$reference,
                     zero = zero$first$trace$value, addition = comparison$intervention,
                     difference = comparison$difference),
          file.path(out, "activation-values.csv"), row.names = FALSE)
write.csv(do.call(rbind, lapply(seq_along(streams), function(i) {
  s <- streams[[i]]
  data.frame(condition = c("original", "addition")[[i]], step = 0:s$n,
             characters = s$characters, text = s$text)
})), file.path(out, "stream-values.csv"), row.names = FALSE)
writeLines(c("PASS: read-only replay of recorded observations; zero model/inference/RNG calls.",
             "896 compared coordinates, zero-control trace/logits/text/token identity checked.",
             "All committed text preserved; original33 and addition48 sampled-token steps."),
           file.path(out, "render-status.txt"))
cat("PASS: rendered", selected, "from existing records. Frames:", frames, "\n")
