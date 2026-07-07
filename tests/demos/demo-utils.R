# tests/demos/demo-utils.R
#
# Model-free numerical helpers for the WP7 demos. These are repo scripts, NOT
# part of the rebirth package. Per D-020 they replace a pROC dependency with a
# few lines of base R: AUC as the rank-based Mann-Whitney U statistic (exact,
# average ranks for ties) plus a stratified percentile-bootstrap CI.
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

  if (isTRUE(verbose)) message("demo-utils self-test: OK (9 checks)")
  invisible(TRUE)
}

# Run on source() so a broken helper fails loudly and immediately. Set
# REBIRTH_DEMO_SKIP_SELFTEST=1 to skip (e.g. when only re-defining the funcs).
if (!nzchar(Sys.getenv("REBIRTH_DEMO_SKIP_SELFTEST"))) {
  demo_utils_selftest()
}
