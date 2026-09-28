#!/usr/bin/env Rscript
# Mandatory installed-product oracle gate, after R CMD check in every R CI leg.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) && !(length(args) == 2L && args[1] == "--relm-library")) stop("usage: run.R [--relm-library PATH]")
library_path <- if (length(args)) args[2] else Sys.getenv("RELM_LIBRARY", "")
if (nzchar(library_path)) .libPaths(c(normalizePath(library_path, mustWork = TRUE), .libPaths()))
script <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE))
root <- normalizePath(file.path(dirname(script), "..", ".."), mustWork = TRUE)
oracle <- file.path(root, "tests", "llm-golden", "probe-contract")
read <- function(name) {
  path <- file.path(oracle, paste0(name, ".csv"))
  if (!file.exists(path)) stop("mandatory independent oracle is missing: ", path)
  read.csv(path, stringsAsFactors = FALSE)
}
if (!requireNamespace("relm", quietly = TRUE)) stop("installed relm is required")
if (!requireNamespace("glmnet", quietly = TRUE)) stop("glmnet is required; the primary numerical gate cannot skip")
helper <- function(name) get(name, envir = asNamespace("relm"), inherits = FALSE)
near <- function(x, y, tolerance = 2e-10) {
  stopifnot(length(x) == length(y), identical(unname(is.na(x)), unname(is.na(y))))
  valid <- !is.na(x)
  stopifnot(all(is.finite(x[valid])), all(abs(x[valid] - y[valid]) <= tolerance * pmax(1, abs(y[valid]))))
}
ridge <- read("ridge-data"); expected <- read("ridge-expected")
for (case in unique(ridge$case)) {
  rows <- ridge[ridge$case == case, ]; ref <- expected[expected$case == case, ]
  x <- as.matrix(rows[, c("x1", "x2")]); colnames(x) <- c("1", "2")
  fit <- helper("probe_ridge_fit")(x, rows$y, lambda = 10^seq(4, -4, length.out = 41))
  near(fit$lambda, ref$lambda)
  near(fit$intercept, ref$intercept, 2e-5)
  near(fit$coefficients[1, ], ref$beta1, 2e-5); near(fit$coefficients[2, ], ref$beta2, 2e-5)
  for (j in seq_along(fit$lambda)) {
    eta <- as.vector(fit$intercept[j] + x %*% fit$coefficients[, j])
    objective <- mean(pmax(eta, 0) + log1p(exp(-abs(eta))) - rows$y * eta) + fit$lambda[j] * sum(fit$coefficients[, j]^2) / 2
    near(objective, ref$objective[j], 2e-9)
    near(c(plogis(fit$intercept[j] - fit$coefficients[1, j]), plogis(fit$intercept[j] + fit$coefficients[1, j])),
         c(ref$p_minus[j], ref$p_plus[j]), 2e-6)
    gradient <- c(mean(plogis(eta) - rows$y), colMeans(x * (plogis(eta) - rows$y)) + fit$lambda[j] * fit$coefficients[, j])
    stopifnot(max(abs(gradient)) < 2e-7)
  }
}
metric <- read("metric-data"); expected <- read("metric-expected")
for (i in seq_len(nrow(expected))) {
  rows <- metric[metric$case == expected$case[i], ]
  for (name in c("auc", "accuracy")) near(helper("probe_metric")(rows$y, rows$score, name), expected[[name]][i])
}
scaling <- read("scaling-data"); expected <- read("scaling-expected")
x <- as.matrix(scaling[, c("x1", "x2")])
pre <- helper("probe_preprocess")(x[scaling$partition == "train", ])
near(pre$center, expected$center); near(pre$scale, expected$scale)
stopifnot(identical(as.integer(seq_len(ncol(x)) %in% pre$keep), expected$keep))
near(as.vector(helper("probe_transform")(x, pre)), read("scaling-transformed")$x1)
boot <- read("bootstrap-data"); indices <- read("bootstrap-indices")
expected <- read("bootstrap-expected"); bounds <- read("bootstrap-ci")
for (case in unique(indices$case)) {
  # Degenerate AAA draws still have A/B/C as the eligible group universe (G=3).
  rows <- boot[boot$group %in% if (case == "undefined") c("D", "E") else c("A", "B", "C"), ]
  index <- indices[indices$case == case, ]
  draws <- unname(split(index$group, index$draw))
  ref <- expected[expected$case == case, ]
  for (name in c("auc", "accuracy")) {
    ci <- helper("probe_intervals")(rows$y, rows$score, rows$group, name, draws = draws, display = FALSE)
    near(ci$values, ref[[name]])
    interval <- bounds[bounds$case == case & bounds$metric == name, ]
    near(c(ci$lower, ci$upper), c(interval$lower, interval$upper))
    stopifnot(ci$status == interval$reason, ci$undefined_draws == interval$undefined_draws)
  }
}
cat("PASS: installed relm matches all 82 frozen ridge roots, metric ties, RMS scaling and fixed cluster resamples\n")
