## -----------------------------------------------------------------------------
#| label: setup
#| include: false
# The heavy steps need a local GGUF model and glmnet; a checker (CRAN,
# r-universe) has neither. We gate those chunks on availability and fall back to
# an illustrative curve, so this vignette always renders with a figure. Point
# RELM_DEMO_MODEL (or RELM_TEST_MODEL_QWEN) at a GGUF file to render the
# figure from real activations.
model_path <- Sys.getenv("RELM_DEMO_MODEL", Sys.getenv("RELM_TEST_MODEL_QWEN", ""))
have_model <- nzchar(model_path) && file.exists(model_path)
have_glmnet <- requireNamespace("glmnet", quietly = TRUE)
run_real <- have_model && have_glmnet


## -----------------------------------------------------------------------------
#| eval: false
# tr <- llm_trace(m, prompts, layers = 6:18, positions = "last")
# fit <- llm_probe(labels ~ activations(layer = 6:18), tr,
#                  groups = source_ids, test_groups = reserved_ids, seed = 42)
# summary(fit)
# plot(fit)


## -----------------------------------------------------------------------------
#| eval: false
# ggplot2::ggplot(fit$metrics, ggplot2::aes(layer, test_score)) +
#   ggplot2::geom_line() + ggplot2::geom_point() +
#   ggplot2::geom_errorbar(ggplot2::aes(ymin = lower, ymax = upper), na.rm = TRUE) +
#   ggplot2::labs(y = "Held-out AUC", subtitle = "Conditional pointwise intervals; development-selected layer fixed")


## -----------------------------------------------------------------------------
#| label: auc
demo_auc <- function(scores, labels) {
  pos <- as.numeric(scores)[labels]
  neg <- as.numeric(scores)[!labels]
  n_pos <- length(pos)
  n_neg <- length(neg)
  r <- rank(c(pos, neg)) # average ranks => correct tie handling
  (sum(r[seq_along(pos)]) - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg)
}

# Stratified percentile-bootstrap CI (resample within class, fixed seed).
demo_auc_ci <- function(scores, labels, B = 2000L, seed = 1L) {
  scores <- as.numeric(scores)
  pos <- scores[labels]
  neg <- scores[!labels]
  est <- demo_auc(scores, labels)
  set.seed(seed)
  boot <- vapply(seq_len(B), function(i) {
    demo_auc(c(sample(pos, replace = TRUE), sample(neg, replace = TRUE)),
             c(rep(TRUE, length(pos)), rep(FALSE, length(neg))))
  }, numeric(1))
  ci <- stats::quantile(boot, c(0.025, 0.975), names = FALSE)
  c(auc = est, lower = ci[1L], upper = ci[2L])
}

# Sanity checks: perfect separation -> 1, label flip -> 1 - AUC, a tie case.
stopifnot(
  all.equal(demo_auc(c(3, 4, 5, 0, 1, 2), c(TRUE, TRUE, TRUE, FALSE, FALSE, FALSE)), 1),
  all.equal(demo_auc(c(1, 2, 1, 3), c(TRUE, TRUE, FALSE, FALSE)), 0.375)
)


## -----------------------------------------------------------------------------
#| label: prompts
pos <- c(
  "I absolutely loved this film; it was a masterpiece.",
  "The service was outstanding and the staff were welcoming.",
  "What a wonderful day -- everything went perfectly."
)
neg <- c(
  "I hated this film; it was a boring waste of time.",
  "The service was appalling and the staff were rude.",
  "What a miserable day -- everything went wrong."
)
train <- c(pos, neg)
y <- c(rep(TRUE, length(pos)), rep(FALSE, length(neg)))


## -----------------------------------------------------------------------------
#| label: probe-real
if (run_real) {
  library(relm)
  m <- llm(model_path)
  tr <- llm_trace(m, train, positions = "last", components = "residual")

  layer_matrix <- function(tr, L) {
    x <- as.matrix(tr, layer = L, component = "residual")
    x[order(as.integer(sub("[.].*$", "", rownames(x)))), , drop = FALSE]
  }
  yf <- factor(ifelse(y, "pos", "neg"), levels = c("neg", "pos"))
  set.seed(1)
  foldid <- sample(rep(seq_len(5), length.out = length(y)))

  band <- sort(unique(tr$layer))
  auc <- lower <- upper <- numeric(length(band))
  for (i in seq_along(band)) {
    cvfit <- glmnet::cv.glmnet(layer_matrix(tr, band[i]), yf, family = "binomial",
                               alpha = 0, foldid = foldid, type.measure = "auc",
                               keep = TRUE)
    oof <- cvfit$fit.preval[, match(cvfit$lambda.min, cvfit$lambda)]
    ci <- demo_auc_ci(oof, y)
    auc[i] <- ci[["auc"]]; lower[i] <- ci[["lower"]]; upper[i] <- ci[["upper"]]
  }
  res <- list(layers = band, auc = auc, lower = lower, upper = upper)
  close(m)
}


## -----------------------------------------------------------------------------
#| label: probe-illustrative
if (isFALSE(run_real)) {
  # Illustrative curve (no model available at render time): sentiment becomes
  # linearly readable in the middle layers. Run the chunk above on your own model
  # to reproduce this figure from real activations.
  L <- 1:24
  set.seed(1)
  auc <- pmin(pmax(0.5 + 0.47 / (1 + exp(-(L - 7) / 1.6)) + rnorm(24, 0, 0.01), 0.5), 0.99)
  w <- (0.5 + 0.5 * (1 - auc)) * 0.09
  res <- list(layers = L, auc = auc, lower = pmax(auc - w, 0), upper = pmin(auc + w, 1))
}


## -----------------------------------------------------------------------------
#| label: money-plot
#| fig-width: 8
#| fig-height: 5
#| fig-alt: "Probe AUC by layer, rising from chance to near one in the middle layers."
L <- res$layers
op <- par(mar = c(4.4, 4.4, 3, 1), mgp = c(2.6, 0.7, 0), las = 1)
plot(L, res$auc, type = "n", ylim = c(0.45, 1),
     xlab = "Transformer layer", ylab = "Probe AUC (out-of-fold)",
     main = sprintf("Where sentiment becomes linearly readable (%s)",
                    if (run_real) "real" else "illustrative"))
abline(h = 0.5, lty = 2, col = "grey45")
arrows(L, res$lower, L, res$upper, angle = 90, code = 3, length = 0.03, col = "grey30")
lines(L, res$auc, col = "#3B6EA5", lwd = 1.5)
points(L, res$auc, pch = 21, bg = "#3B6EA5", col = "white", cex = 1.2)
b <- L[which.max(res$auc)]
abline(v = b, lty = 3, col = adjustcolor("#D1495B", 0.4))
points(b, max(res$auc), pch = 21, bg = "#D1495B", col = "white", cex = 1.6)
text(max(L), 0.455, sprintf("best: layer %d (AUC %.2f)", b, max(res$auc)),
     adj = c(1, 0), font = 2, col = "#D1495B")
par(op)


## -----------------------------------------------------------------------------
#| label: steer
#| eval: false
# pc <- prcomp(layer_matrix(tr, b), center = TRUE, scale. = FALSE)
# direction <- pc$rotation[, 1]
# if (demo_auc(pc$x[, 1], y) < 0.5) direction <- -direction
# 
# m_pos <- llm_steer(m, layer = b, direction = direction, coef = 6)
# llm_generate(m,     "In one sentence, describe your morning.", seed = 1)
# llm_generate(m_pos, "In one sentence, describe your morning.", seed = 1)
# close(m_pos)


## -----------------------------------------------------------------------------
#| label: decodability-vs-causality
#| fig-width: 8
#| fig-height: 5
#| fig-alt: "Mean next-token KL vs neurons ablated, log scale: load-bearing units far above a matched-random control, while concept-readout units track random."
# Illustrative of the measured RELATIVE pattern (the absolute KL scale varies with
# model and layer -- e.g. impact KL ~ O(1) on Qwen2.5-0.5B, ~ O(0.03) on Gemma 4 E4B
# -- but the orders-of-magnitude separation does not). Reproduce it from your own
# model with tests/demos/demo-A-anatomy-lab.R: run_demo_A(extended = TRUE) writes the
# real three-series figure (demoA-A4-decodability.png).
ks <- c(1, 2, 4, 8, 16, 32, 64)
load_bearing    <- c(0.05, 0.10, 1.20, 2.00, 3.00, 3.50, 4.00) # top-k by residual RMS
concept_readout <- c(1e-4, 2e-4, 5e-4, 1.6e-3, 3e-3, 5e-3, 1.5e-2) # top-k by |probe coef|
matched_random  <- c(4e-4, 7e-4, 2e-3, 6e-3, 1.2e-2, 3e-2, 5e-2) # size-matched control

xx <- log2(ks)
cols <- c(load = "#D1495B", random = "grey45", concept = "#3B6EA5")
op <- par(mar = c(4.4, 4.6, 3, 1), mgp = c(2.7, 0.7, 0), las = 1)
plot(xx, load_bearing, type = "n", log = "y", xaxt = "n",
     ylim = c(1e-4, 6), xlab = "neurons ablated (k)",
     ylab = "Mean next-token KL (log)",
     main = "Reading is not causing: readable units are not the causal locus")
axis(1, at = xx, labels = ks)
abline(h = 10^(-4:0), col = "grey93")
for (s in list(list(matched_random, "random"), list(concept_readout, "concept"),
               list(load_bearing, "load"))) {
  lines(xx, s[[1]], col = cols[[s[[2]]]], lwd = 1.6)
  points(xx, s[[1]], pch = 21, bg = cols[[s[[2]]]], col = "white", cex = 1.3)
}
legend("topleft", bty = "n", cex = 0.9, pch = 21, lwd = 1.6, pt.bg = cols, col = cols,
       legend = c("load-bearing units (top-k residual RMS)",
                  "matched random-k (control)",
                  "concept-readout units (top-k |probe coef|)"))
par(op)

