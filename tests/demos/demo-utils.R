# tests/demos/demo-utils.R
#
# Model-free helpers for the WP7 / WP7.5b demos. These are repo scripts, NOT part
# of the rebirth package. Per D-020 they replace a pROC dependency with a few
# lines of base R: AUC as the rank-based Mann-Whitney U statistic (exact, average
# ranks for ties) plus a stratified percentile-bootstrap CI. WP7.5b (D-022) adds
# the shared base-graphics visual style and a handful of self-tested numeric
# helpers (bootstrap mean CI, cosine matrix, truncated next-token KL, legend
# breaks) reused by the extended Demo A analyses.
#
# Demo A sources this file; vignette A inlines demo_auc() verbatim -- "AUC needs
# no dependency" is part of the demo's argument. The executable self-test at the
# foot of this file runs on source() and aborts loudly if any identity breaks,
# so the accepted script/vignette duplication is guarded (D-020, point 4).

# ---- AUC: rank-based Mann-Whitney U, exact, ties via average ranks -----------

# Core estimator on two score vectors. AUC = P(pos > neg) + 0.5 * P(pos == neg),
# which equals the normalized Mann-Whitney U. rank()'s default "average" method
# handles ties exactly (a tie contributes 0.5).
.demo_auc_pos_neg <- function(pos, neg) {
  n_pos <- length(pos)
  n_neg <- length(neg)
  r <- rank(c(pos, neg))
  (sum(r[seq_along(pos)]) - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg)
}

# Resolve a binary label vector to a positive-class logical mask. logical labels
# are taken as-is (TRUE = positive); otherwise the two-level factor's second
# level is positive by default (the glmnet/pROC convention), or `positive` names
# it explicitly.
.demo_positive_mask <- function(labels, positive = NULL) {
  if (is.logical(labels)) {
    if (anyNA(labels)) stop("`labels` must not contain NA")
    return(labels)
  }
  f <- as.factor(labels)
  lv <- levels(f)
  if (length(lv) != 2L) {
    stop("AUC needs exactly two classes; found ", length(lv))
  }
  if (is.null(positive)) positive <- lv[2L]
  if (!positive %in% lv) {
    stop(
      "`positive` (", positive, ") is not one of the labels: ",
      paste(lv, collapse = ", ")
    )
  }
  f == positive
}

# demo_auc(scores, labels): AUC of a numeric score against a binary label.
demo_auc <- function(scores, labels, positive = NULL) {
  is_pos <- .demo_positive_mask(labels, positive)
  scores <- as.numeric(scores)
  if (length(scores) != length(is_pos)) {
    stop("`scores` and `labels` must have the same length")
  }
  if (anyNA(scores)) stop("`scores` must not contain NA")
  pos <- scores[is_pos]
  neg <- scores[!is_pos]
  if (length(pos) == 0L || length(neg) == 0L) {
    stop("AUC is undefined unless both classes are present")
  }
  .demo_auc_pos_neg(pos, neg)
}

# Evaluate `expr` under a fixed RNG seed without perturbing the caller's stream,
# so a fixed-seed CI is reproducible yet hermetic.
.demo_with_seed <- function(seed, expr) {
  if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
    saved <- get(".Random.seed", envir = globalenv(), inherits = FALSE)
    on.exit(assign(".Random.seed", saved, envir = globalenv()), add = TRUE)
  } else {
    on.exit(
      suppressWarnings(rm(".Random.seed", envir = globalenv())),
      add = TRUE
    )
  }
  set.seed(seed)
  expr # forced here, i.e. after set.seed()
}

# demo_auc_ci(): the point AUC plus a stratified percentile-bootstrap CI.
# Stratified = resample WITHIN each class (preserving the class sizes), so the
# interval reflects sampling variability at the observed prevalence. Fixed seed
# => identical output across runs (WP7 reproducibility).
demo_auc_ci <- function(scores, labels, positive = NULL,
                        level = 0.95, B = 2000L, seed = 1L) {
  is_pos <- .demo_positive_mask(labels, positive)
  scores <- as.numeric(scores)
  if (length(scores) != length(is_pos)) {
    stop("`scores` and `labels` must have the same length")
  }
  if (anyNA(scores)) stop("`scores` must not contain NA")
  pos <- scores[is_pos]
  neg <- scores[!is_pos]
  if (length(pos) == 0L || length(neg) == 0L) {
    stop("AUC is undefined unless both classes are present")
  }
  est <- .demo_auc_pos_neg(pos, neg)
  boot <- .demo_with_seed(seed, vapply(seq_len(B), function(i) {
    .demo_auc_pos_neg(
      sample(pos, replace = TRUE),
      sample(neg, replace = TRUE)
    )
  }, numeric(1)))
  a <- (1 - level) / 2
  ci <- stats::quantile(boot, c(a, 1 - a), names = FALSE, type = 7)
  c(auc = est, lower = ci[1L], upper = ci[2L])
}

# ---- WP7.5b numeric helpers (shared by the extended Demo A analyses) ----------
#
# All model-free and self-tested at the foot of this file (D-022: every new
# numeric helper carries a hand-computed self-test).

# Unit-normalize a numeric vector; a zero vector is returned unchanged.
.demo_unit <- function(v) {
  s <- sqrt(sum(v^2))
  if (s == 0) v else v / s
}

# Bootstrap percentile CI of the mean (A3's dose-response aggregation). Resample
# the values with replacement B times; a fixed seed => byte-identical output
# across runs (the WP7 reproducibility rule), evaluated hermetically via
# .demo_with_seed so the caller's RNG stream is untouched.
.demo_boot_mean_ci <- function(x, level = 0.95, B = 2000L, seed = 1L) {
  x <- as.numeric(x)
  if (length(x) == 0L) stop("`x` must be non-empty")
  if (anyNA(x)) stop("`x` must not contain NA")
  n <- length(x)
  est <- mean(x)
  boot <- .demo_with_seed(seed, vapply(seq_len(B), function(i) {
    mean(x[sample.int(n, n, replace = TRUE)])
  }, numeric(1)))
  a <- (1 - level) / 2
  ci <- stats::quantile(boot, c(a, 1 - a), names = FALSE, type = 7)
  c(mean = est, lower = ci[1L], upper = ci[2L])
}

# Row-wise cosine-similarity matrix (A5). Rows of `M` are the vectors; the result
# is the symmetric k x k matrix of pairwise cosines, clamped to [-1, 1] to absorb
# floating-point drift so image()'s symmetric scale is exact. A zero row (no
# direction) is treated as orthogonal to all (its off-diagonal entries are 0).
.demo_cosine_matrix <- function(M) {
  M <- as.matrix(M)
  nrm <- sqrt(rowSums(M^2))
  nrm[nrm == 0] <- 1
  U <- M / nrm
  S <- tcrossprod(U)
  pmin(pmax(S, -1), 1)
}

# Truncated next-token KL over the union of two top-N token sets (A4). `base` and
# `int` are named probability vectors (names = token ids) as returned per prompt
# by llm_logits(). A token listed on only one side is floored at that side's
# smallest listed prob -- a token outside a top-N list has at most the tail prob --
# and each side is renormalized over the union, so both are valid distributions
# and KL(base || int) >= 0. When the two supports are identical and already sum to
# 1 this is the exact KL (pinned by the self-test).
.demo_next_token_kl <- function(base, int) {
  if (length(base) == 0L || length(int) == 0L) {
    stop("`base` and `int` must be non-empty named probability vectors")
  }
  ids <- union(names(base), names(int))
  fill <- function(p) {
    v <- as.numeric(p[ids]) # NA where an id is absent from this side's list
    v[is.na(v)] <- min(p) # floor at this side's top-N tail prob
    v / sum(v) # renormalize over the union
  }
  pb <- fill(base)
  pq <- fill(int)
  sum(pb * log(pb / pq))
}

# n + 1 evenly spaced breaks spanning `zlim`, matching an image()/colour-strip
# pairing where length(breaks) == length(col) + 1 (the colour-strip legend). A
# degenerate zlim (equal ends) is nudged so the breaks stay strictly increasing.
.demo_legend_breaks <- function(zlim, n) {
  zlim <- as.numeric(zlim)
  n <- as.integer(n)
  if (length(zlim) != 2L || anyNA(zlim) || any(!is.finite(zlim)) || n < 1L) {
    stop("`zlim` must be two finite numbers and `n` a positive integer")
  }
  if (zlim[2L] <= zlim[1L]) {
    pad <- if (zlim[2L] == 0) 1e-8 else abs(zlim[2L]) * 1e-8
    zlim <- c(zlim[1L] - pad, zlim[2L] + pad)
  }
  seq(zlim[1L], zlim[2L], length.out = n + 1L)
}

# A symmetric zlim about zero covering `z` (for the diverging A5 matrix), or the
# plain data range with a small pad (for the sequential A2 heatmap).
.demo_zlim <- function(z, symmetric = FALSE) {
  z <- z[is.finite(z)]
  if (length(z) == 0L) {
    return(c(-1, 1))
  }
  if (isTRUE(symmetric)) {
    a <- max(abs(z))
    if (a == 0) a <- 1
    c(-a, a)
  } else {
    r <- range(z)
    if (r[1L] == r[2L]) {
      r <- r + c(-1, 1) * (if (r[1L] == 0) 1e-8 else abs(r[1L]) * 1e-8)
    }
    r
  }
}

# ---- WP7.5b shared visual style (one coherent look across all demo figures) ---
#
# The house palette (hcl.colors: qualitative "Dark 3", sequential "YlOrBr",
# diverging "Blue-Red 3"), point discipline (pch = 21 fills with white strokes),
# a consistent par() block, the halo-text label helper, a colour-strip legend
# (a base-R stand-in for fields::image.plot, D-020: no dependency for one legend),
# and the model | n | seed subtitle line.

.DEMO_PCH <- 21L
.DEMO_MGP <- c(2.7, 0.7, 0)
.DEMO_PT_STROKE <- "white"

# Apply the house par() block (the caller saves/restores par itself).
.demo_par <- function(mar = c(4.6, 4.6, 3.4, 1.2), ...) {
  graphics::par(mar = mar, mgp = .DEMO_MGP, las = 1L, ...)
}

.demo_pal_qual <- function(k) grDevices::hcl.colors(max(as.integer(k), 1L), "Dark 3")
# Sequential YlOrBr. rev = TRUE (dark -> light for low -> high) is the D-022
# default; A2 passes rev = FALSE so a strong positive-sentiment cell reads dark.
.demo_pal_seq <- function(n, rev = TRUE) grDevices::hcl.colors(as.integer(n), "YlOrBr", rev = rev)
.demo_pal_div <- function(n) grDevices::hcl.colors(as.integer(n), "Blue-Red 3")

# Points in the house style: a filled pch = 21 marker with a white stroke.
.demo_points <- function(x, y, bg, cex = 1.3, ...) {
  graphics::points(x, y, pch = .DEMO_PCH, bg = bg, col = .DEMO_PT_STROKE, cex = cex, ...)
}

# The "model | n | seed | ..." subtitle string (pure; drawn by .demo_subtitle()).
.demo_subtitle_text <- function(model, n, seed = NULL, extra = NULL) {
  parts <- c(sprintf("model: %s", basename(model)), sprintf("n = %d", as.integer(n)))
  if (!is.null(seed)) parts <- c(parts, sprintf("seed = %d", as.integer(seed)))
  if (!is.null(extra)) parts <- c(parts, extra)
  paste(parts, collapse = "  |  ")
}

.demo_subtitle <- function(model, n, seed = NULL, extra = NULL, line = 0.3, cex = 0.8) {
  graphics::mtext(
    .demo_subtitle_text(model, n, seed, extra),
    side = 3, line = line, cex = cex, col = "grey35"
  )
}

# Text with a white halo, so labels stay readable over coloured points/cells.
# (Kept here as the shared copy; demo-B still carries its own until part-2 folds
# it onto this file.)
.demo_halo_text <- function(x, y, labels, col = "black", cex = 1, font = 2,
                            adj = c(0.5, 0.5), ...) {
  off <- 0.006 * diff(graphics::par("usr")[1:2])
  for (dx in c(-1, 1)) {
    for (dy in c(-1, 1)) {
      graphics::text(x + dx * off, y + dy * off, labels,
        col = "white", cex = cex, font = font, adj = adj, ...
      )
    }
  }
  graphics::text(x, y, labels, col = col, cex = cex, font = font, adj = adj, ...)
}

# A vertical colour-strip legend drawn into the CURRENT (narrow) panel: the caller
# reserves a slim column via layout(). `breaks`/`col` are exactly the pair the
# matching image() used (length(breaks) == length(col) + 1). ~15 base-R lines in
# place of a fields/plotrix dependency (D-020).
.demo_color_strip_legend <- function(breaks, col, title = NULL, n_lab = 5L) {
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  graphics::par(mar = c(4.6, 0.4, 3.4, 3.2), mgp = .DEMO_MGP, las = 1L)
  graphics::plot.new()
  graphics::plot.window(xlim = c(0, 1), ylim = range(breaks), xaxs = "i", yaxs = "i")
  for (i in seq_along(col)) {
    graphics::rect(0, breaks[i], 1, breaks[i + 1L], col = col[i], border = NA)
  }
  graphics::rect(0, breaks[1L], 1, breaks[length(breaks)], col = NA, border = "grey40")
  at <- pretty(range(breaks), n = n_lab)
  at <- at[at >= min(breaks) & at <= max(breaks)]
  graphics::axis(4, at = at)
  if (!is.null(title)) {
    graphics::mtext(title, side = 3, line = 0.5, cex = 0.8, col = "grey25")
  }
  invisible(NULL)
}

# ---- Executable self-test ----------------------------------------------------

demo_utils_selftest <- function(verbose = TRUE) {
  ok <- function(cond, msg) {
    if (!isTRUE(cond)) stop("demo-utils self-test FAILED: ", msg, call. = FALSE)
  }

  # 1. Perfect separation -> 1; perfect anti-separation -> 0.
  y3 <- c(TRUE, TRUE, TRUE, FALSE, FALSE, FALSE)
  ok(
    isTRUE(all.equal(demo_auc(c(3, 4, 5, 0, 1, 2), y3), 1)),
    "perfect separation should give AUC = 1"
  )
  ok(
    isTRUE(all.equal(demo_auc(c(0, 1, 2, 3, 4, 5), y3), 0)),
    "perfect anti-separation should give AUC = 0"
  )

  # 2. Label-flip symmetry: AUC(flipped positive) == 1 - AUC.
  s <- c(0.2, 0.9, 0.1, 0.6, 0.75, 0.4)
  y <- c(TRUE, TRUE, FALSE, FALSE, TRUE, FALSE)
  a <- demo_auc(s, y)
  ok(
    isTRUE(all.equal(demo_auc(s, !y), 1 - a)),
    "flipping the positive class should give 1 - AUC"
  )

  # 3. Monotone-transform invariance (AUC depends only on ranks).
  ok(
    isTRUE(all.equal(a, demo_auc(exp(3 * s) + 5, y))),
    "a strictly increasing transform must not change AUC"
  )
  ok(
    isTRUE(all.equal(a, demo_auc(-1 / (s + 2), y))),
    "a second strictly increasing transform must not change AUC"
  )

  # 4. Hand-computed tie case. pos = {1, 2}, neg = {1, 3}; the four pos-neg
  #    pairs score (1,1)=0.5, (1,3)=0, (2,1)=1, (2,3)=0 -> 1.5 / 4 = 0.375.
  ok(
    isTRUE(all.equal(
      demo_auc(c(1, 2, 1, 3), c(TRUE, TRUE, FALSE, FALSE)), 0.375
    )),
    "hand-computed tie case should give AUC = 0.375"
  )

  # 5. Bootstrap CI: reproducible for a fixed seed, brackets the estimate,
  #    stays within [0, 1].
  ci1 <- demo_auc_ci(s, y, B = 500L, seed = 42L)
  ci2 <- demo_auc_ci(s, y, B = 500L, seed = 42L)
  ok(isTRUE(all.equal(ci1, ci2)), "the CI must be reproducible for a fixed seed")
  ok(
    ci1[["lower"]] <= ci1[["auc"]] && ci1[["auc"]] <= ci1[["upper"]],
    "the CI must bracket the point estimate"
  )
  ok(
    ci1[["lower"]] >= 0 && ci1[["upper"]] <= 1,
    "the CI must lie within [0, 1]"
  )

  # ---- WP7.5b helpers (D-022) ----

  # 6. Bootstrap mean CI (A3 dose-response): reproducible, brackets the mean,
  #    and degenerate on a constant vector (every resample is the same value).
  m1 <- .demo_boot_mean_ci(c(1, 2, 3, 4, 5), B = 500L, seed = 7L)
  m2 <- .demo_boot_mean_ci(c(1, 2, 3, 4, 5), B = 500L, seed = 7L)
  ok(isTRUE(all.equal(m1, m2)), "the mean CI must be reproducible for a fixed seed")
  ok(
    m1[["lower"]] <= m1[["mean"]] && m1[["mean"]] <= m1[["upper"]],
    "the mean CI must bracket the mean"
  )
  mc <- .demo_boot_mean_ci(rep(5, 8L), B = 200L, seed = 1L)
  ok(
    isTRUE(all.equal(unname(mc), c(5, 5, 5))),
    "a constant vector's mean CI collapses to the value"
  )

  # 7. Cosine matrix (A5): equal -> 1, orthogonal -> 0, opposite -> -1.
  cm <- .demo_cosine_matrix(rbind(c(1, 0), c(0, 1), c(-1, 0)))
  ok(
    isTRUE(all.equal(cm, matrix(c(1, 0, -1, 0, 1, 0, -1, 0, 1), 3L, 3L))),
    "the cosine matrix must give 1 / 0 / -1 for equal / orthogonal / opposite rows"
  )

  # 8. Truncated next-token KL (A4): exact on a shared full support, 0 against
  #    itself, finite+positive when the supports differ (floor + union path).
  b <- c("1" = 0.7, "2" = 0.2, "3" = 0.1)
  q <- c("1" = 0.5, "2" = 0.3, "3" = 0.2)
  ok(
    isTRUE(all.equal(
      .demo_next_token_kl(b, q),
      0.7 * log(0.7 / 0.5) + 0.2 * log(0.2 / 0.3) + 0.1 * log(0.1 / 0.2)
    )),
    "top-N KL on a shared full-support pair equals the exact KL"
  )
  ok(
    isTRUE(all.equal(.demo_next_token_kl(b, b), 0)),
    "KL of a distribution against itself is 0"
  )
  kl_diff <- .demo_next_token_kl(c("1" = 0.6, "2" = 0.4), c("1" = 0.5, "3" = 0.5))
  ok(
    is.finite(kl_diff) && kl_diff > 0,
    "top-N KL with differing supports is finite and positive"
  )

  # 9. Legend breaks (colour-strip): n + 1 evenly spaced values over zlim.
  ok(
    isTRUE(all.equal(.demo_legend_breaks(c(0, 1), 4L), c(0, 0.25, 0.5, 0.75, 1))),
    "legend breaks must be n + 1 evenly spaced values over zlim"
  )

  # 10. Unit-normalization: (3, 4) -> (0.6, 0.8); a zero vector is unchanged.
  ok(
    isTRUE(all.equal(.demo_unit(c(3, 4)), c(0.6, 0.8))),
    "unit() must normalize to length 1"
  )
  ok(
    isTRUE(all.equal(.demo_unit(c(0, 0)), c(0, 0))),
    "unit() must leave a zero vector unchanged"
  )

  # 11. Subtitle line: basename + n, with seed appended only when supplied.
  ok(
    identical(
      .demo_subtitle_text("/a/b/model.gguf", 40, 7),
      "model: model.gguf  |  n = 40  |  seed = 7"
    ),
    "the subtitle text must read 'model | n | seed'"
  )
  ok(
    identical(.demo_subtitle_text("x.gguf", 5), "model: x.gguf  |  n = 5"),
    "the subtitle omits the seed when none is given"
  )

  # 12. Symmetric zlim about zero (A5's diverging scale).
  ok(
    isTRUE(all.equal(.demo_zlim(c(-2, 1, 0.5), symmetric = TRUE), c(-2, 2))),
    "symmetric zlim spans +/- max|z|"
  )

  if (isTRUE(verbose)) message("demo-utils self-test: OK (22 checks)")
  invisible(TRUE)
}

# Run on source() so a broken helper fails loudly and immediately. Set
# REBIRTH_DEMO_SKIP_SELFTEST=1 to skip (e.g. when only re-defining the funcs).
if (!nzchar(Sys.getenv("REBIRTH_DEMO_SKIP_SELFTEST"))) {
  demo_utils_selftest()
}
