#!/usr/bin/env Rscript
# Independent base-R recomputation; glmnet is used only for solver comparison.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(all(args %in% "--numerical"), !anyDuplicated(args))
script <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE))
root <- dirname(normalizePath(script, mustWork = TRUE))
read <- function(name) read.csv(file.path(root, paste0(name, ".csv")), stringsAsFactors = FALSE)
near <- function(x, y, tolerance = 2e-10) {
  stopifnot(length(x) == length(y), identical(unname(is.na(x)), unname(is.na(y))))
  keep <- !is.na(x)
  stopifnot(all(is.finite(x[keep])), all(abs(x[keep] - y[keep]) <= tolerance * pmax(1, abs(y[keep]))))
}
metrics <- function(y, score) {
  positive <- sum(y == 1); negative <- sum(y == 0)
  auc <- if (positive && negative) {
    (sum(rank(score, ties.method = "average")[y == 1]) - positive * (positive + 1) / 2) / (positive * negative)
  } else NA_real_
  pairs <- outer(score[y == 1], score[y == 0], "-")
  c(n = length(y), positive = positive, negative = negative, wins = sum(pairs > 0),
    ties = sum(pairs == 0), losses = sum(pairs < 0), auc = auc, accuracy = mean((score >= .5) == y))
}
metric_data <- read("metric-data"); metric_expected <- read("metric-expected")
for (i in seq_len(nrow(metric_expected))) {
  rows <- subset(metric_data, case == metric_expected$case[i])
  near(metrics(rows$y, rows$score), unlist(metric_expected[i, -1], use.names = FALSE))
}
# Repeated clusters are expanded, including every occurrence and every member.
boot_data <- read("bootstrap-data"); indices <- read("bootstrap-indices")
boot_expected <- read("bootstrap-expected"); boot_metrics <- boot_expected
for (i in seq_len(nrow(boot_expected))) {
  index <- indices[indices$case == boot_expected$case[i] & indices$draw == boot_expected$draw[i], ]
  stopifnot(identical(index$position, seq_len(nrow(index))))
  rows <- do.call(rbind, lapply(index$group, function(g) boot_data[boot_data$group == g, ]))
  actual <- metrics(rows$y, rows$score)
  near(actual, unlist(boot_expected[i, -(1:2)], use.names = FALSE))
  boot_metrics[i, names(actual)] <- actual
}
ci <- read("bootstrap-ci")
for (i in seq_len(nrow(ci))) {
  values <- boot_metrics[boot_metrics$case == ci$case[i], ci$metric[i]]
  undefined <- sum(is.na(values))
  bounds <- if (undefined) c(NA_real_, NA_real_) else unname(quantile(values, c(.025, .975), type = 7))
  reason <- if (undefined) "undefined_draw" else if (bounds[1] == bounds[2]) "degenerate_bootstrap" else "available"
  if (reason == "degenerate_bootstrap") bounds[] <- NA_real_
  near(bounds, c(ci$lower[i], ci$upper[i]))
  stopifnot(reason == ci$reason[i], undefined == ci$undefined_draws[i])
}
display <- read("interval-display")
for (i in seq_len(nrow(display))) {
  r <- display[i, ]
  reason <- if (r$groups == 0) "not_evaluated" else if (r$groups < 20) "insufficient_groups" else
    if (min(r$positive_groups, r$negative_groups) < 5) "insufficient_class_groups" else
      if (r$undefined_draws > 0) "undefined_draw" else
        if (r$lower == r$upper) "degenerate_bootstrap" else "available"
  stopifnot(reason == r$reason)
}
scaling <- read("scaling-data"); expected <- read("scaling-expected")
train <- as.matrix(scaling[scaling$partition == "train", c("x1", "x2")])
center <- colMeans(train)
scale <- sqrt(colMeans(sweep(train, 2, center, "-")^2))
near(unname(center), expected$center); near(unname(scale), expected$scale)
stopifnot(identical(as.integer(scale > 0), expected$keep))
transformed <- sweep(sweep(as.matrix(scaling[, c("x1", "x2")]), 2, center, "-"), 2, ifelse(scale > 0, scale, 1), "/")[, scale > 0, drop = FALSE]
near(as.vector(transformed), read("scaling-transformed")$x1)
stopifnot(ncol(transformed) == 1, max(abs(center - colMeans(scaling[, c("x1", "x2")]))) > 100)
# Independent split audit in R also executes both negative fixtures.
audit <- function(rows) {
  stopifnot(!anyDuplicated(rows$row_id), all(nzchar(rows$row_id)), all(nzchar(rows$group)),
            setequal(rows$partition, c("train", "test")))
  for (g in unique(rows$group)) {
    members <- rows[rows$group == g, ]
    stopifnot(length(unique(members$partition)) == 1, length(unique(members$fold)) == 1)
  }
  stopifnot(all(is.na(rows$fold[rows$partition == "test"])),
            all(rows$fold[rows$partition == "train"] >= 1),
            length(unique(rows$fold[rows$partition == "train"])) >= 3)
}
audit(read("split-valid"))
for (name in c("split-holdout-leak", "split-cv-leak")) {
  refused <- tryCatch({ audit(read(name)); FALSE }, error = function(e) TRUE)
  stopifnot(refused)
}
folds <- read("fold-diagnostics"); fold_expected <- read("fold-expected")
for (i in seq_len(nrow(fold_expected))) {
  rows <- folds[folds$lambda == fold_expected$lambda[i], ]
  near(mean(rows$auc), fold_expected$mean_fold_auc[i])
  stopifnot(abs(mean(rows$auc) - weighted.mean(rows$auc, rows$n)) > .01)
}
cat("PASS: base-R metrics, bootstrap, train-only RMS scaling, fold diagnostics and split audits\n")
available <- requireNamespace("glmnet", quietly = TRUE)
if ("--numerical" %in% args && !available) stop("--numerical requires the approved glmnet Suggests package; numerical verification was not run")
if (!available) {
  cat("SKIP: glmnet unavailable; use --numerical to require the numerical comparison\n")
} else {
  ridge_data <- read("ridge-data"); oracle <- read("ridge-expected")
  for (case_name in unique(ridge_data$case)) {
    rows <- ridge_data[ridge_data$case == case_name, ]; expected <- oracle[oracle$case == case_name, ]
    x <- as.matrix(rows[, c("x1", "x2")]); y <- rows$y
    stopifnot(all(colMeans(x) == 0), all(colMeans(x^2) == 1))
    fit_args <- list(x = x, y = y, family = "binomial", alpha = 0,
                     lambda = 10^seq(4, -4, length.out = 41), standardize = FALSE, intercept = TRUE)
    settings <- list(thresh = 1e-14, maxit = 1000000L)
    if ("control" %in% names(formals(glmnet::glmnet))) fit_args$control <- settings else fit_args <- c(fit_args, settings)
    fit <- do.call(glmnet::glmnet, fit_args)
    stopifnot(ncol(fit$beta) == 41)
    near(fit$lambda, expected$lambda)
    coefficients <- rbind(fit$a0, as.matrix(fit$beta))
    near(as.vector(coefficients), as.vector(t(as.matrix(expected[, c("intercept", "beta1", "beta2")]))), 2e-5)
    for (j in seq_len(ncol(coefficients))) {
      a <- coefficients[1, j]; b <- coefficients[-1, j]; lambda <- fit$lambda[j]
      eta <- as.vector(a + x %*% b); p <- plogis(eta)
      # Stable independent softplus expression; intercept is absent from penalty.
      objective <- mean(pmax(eta, 0) + log1p(exp(-abs(eta))) - y * eta) + lambda * sum(b^2) / 2
      gradient <- c(mean(p - y), colMeans(x * (p - y)) + lambda * b)
      near(objective, expected$objective[j], 2e-9)
      near(c(plogis(a - b[1]), plogis(a + b[1])), c(expected$p_minus[j], expected$p_plus[j]), 2e-6)
      stopifnot(max(abs(gradient)) < 2e-7)
    }
  }
  cat("PASS: glmnet", as.character(utils::packageVersion("glmnet")), "matches 82 independent ridge roots and KKT gradients\n")
}
