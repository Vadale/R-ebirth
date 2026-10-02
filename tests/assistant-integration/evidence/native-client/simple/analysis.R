# Reproducible comparison of two independent observational groups
# Primary estimand: arithmetic mean outcome in group B minus group A (points).

options(stringsAsFactors = FALSE)

input_file <- input_paths[[1L]]
d <- utils::read.csv(input_file, check.names = FALSE)

required <- c("id", "group", "outcome")
if (!all(required %in% names(d))) {
  stop("Input must contain columns: id, group, outcome")
}
d <- d[required]
if (anyNA(d)) stop("Missing values are present in required analysis columns")
if (anyDuplicated(d$id)) stop("Participant IDs must be unique")
if (!is.numeric(d$outcome) || any(!is.finite(d$outcome))) {
  stop("outcome must be finite and numeric")
}
if (!setequal(unique(d$group), c("A", "B"))) {
  stop("group must contain exactly A and B")
}
d$group <- factor(d$group, levels = c("A", "B"))

group_n <- table(d$group)
if (any(group_n < 2L)) stop("Each group must contain at least two participants")

a <- d$outcome[d$group == "A"]
b <- d$outcome[d$group == "B"]
welch <- stats::t.test(b, a, alternative = "two.sided", conf.level = 0.95,
                       var.equal = FALSE)
estimate <- unname(mean(b) - mean(a))
ci <- unname(welch$conf.int)

# Descriptive statistics and the inferential result in a compact table.
group_rows <- data.frame(
  result = c("Group A", "Group B"),
  n = as.integer(group_n[c("A", "B")]),
  mean_points = c(mean(a), mean(b)),
  sd_points = c(stats::sd(a), stats::sd(b)),
  difference_B_minus_A = NA_real_,
  ci_95_low = NA_real_,
  ci_95_high = NA_real_,
  p_value = NA_real_,
  method = "Descriptive",
  check.names = FALSE
)
difference_row <- data.frame(
  result = "B minus A",
  n = length(a) + length(b),
  mean_points = NA_real_,
  sd_points = NA_real_,
  difference_B_minus_A = estimate,
  ci_95_low = ci[1L],
  ci_95_high = ci[2L],
  p_value = welch$p.value,
  method = "Welch two-sample t interval",
  check.names = FALSE
)
results_table <- rbind(group_rows, difference_row)
utils::write.csv(results_table, file.path(output_dir, "results-table.csv"),
                 row.names = FALSE, na = "")

# Diagnostics: these characterize support and potential fragility; a p-value is
# not used as a gatekeeper for the prespecified Welch analysis.
variance_ratio <- max(stats::var(a), stats::var(b)) / min(stats::var(a), stats::var(b))
shapiro_a <- if (length(a) >= 3L) stats::shapiro.test(a) else NULL
shapiro_b <- if (length(b) >= 3L) stats::shapiro.test(b) else NULL

# Leave-one-participant-out estimates show sensitivity to an individual value.
loo <- vapply(seq_len(nrow(d)), function(i) {
  di <- d[-i, , drop = FALSE]
  mean(di$outcome[di$group == "B"]) - mean(di$outcome[di$group == "A"])
}, numeric(1))

diagnostics <- data.frame(
  check = c("independence", "unique_participants", "missingness",
            "group_support", "variance_imbalance", "distribution_shape",
            "single_observation_sensitivity"),
  status = c("assumed", "pass", "pass", "pass",
             if (is.finite(variance_ratio) && variance_ratio <= 4) "pass" else "warn",
             "not_assessed", "not_assessed"),
  detail = c(
    "One row per independent participant, according to the supplied design; independence cannot be tested from these data.",
    sprintf("All %d participant IDs are unique.", nrow(d)),
    "No missing values in id, group, or outcome; all rows were analyzed.",
    sprintf("A: n=%d; B: n=%d.", length(a), length(b)),
    sprintf("Larger-to-smaller sample variance ratio = %.2f; Welch inference allows unequal variances.", variance_ratio),
    sprintf("Inspect diagnostic-plot.png. Shapiro-Wilk p-values: A=%.3f, B=%.3f; with n=12 per group these have limited power and are not an assumption gate.", shapiro_a$p.value, shapiro_b$p.value),
    sprintf("Leave-one-out B-minus-A estimates range from %.2f to %.2f points (full estimate %.2f).", min(loo), max(loo), estimate)
  ),
  stringsAsFactors = FALSE
)

# Main labelled plot: all observations plus the directly estimated contrast.
grDevices::png(file.path(output_dir, "labelled-plot.png"), width = 1500,
               height = 760, res = 150)
graphics::par(mfrow = c(1, 2), mar = c(4.5, 4.8, 3.2, 1.2), las = 1)
cols <- c(A = "#0072B2", B = "#D55E00")
graphics::plot(c(0.7, 2.3), range(d$outcome) + c(-1, 1), type = "n",
               xaxt = "n", xlab = "Observational group", ylab = "Outcome (points)",
               main = "Observed participant outcomes")
graphics::axis(1, at = 1:2,
               labels = sprintf("%s (n=%d)", c("A", "B"), as.integer(group_n)))
graphics::grid(nx = NA, ny = NULL, col = "grey90")
for (j in 1:2) {
  vals <- d$outcome[d$group == levels(d$group)[j]]
  graphics::stripchart(vals, at = j, method = "jitter", jitter = 0.10,
                       vertical = TRUE, add = TRUE, pch = 16,
                       col = grDevices::adjustcolor(cols[j], alpha.f = 0.65))
  se <- stats::sd(vals) / sqrt(length(vals))
  crit <- stats::qt(0.975, df = length(vals) - 1)
  graphics::segments(j, mean(vals) - crit * se, j, mean(vals) + crit * se,
                     lwd = 2.5, col = cols[j])
  graphics::points(j, mean(vals), pch = 18, cex = 1.5, col = cols[j])
}
graphics::legend("topleft", legend = c("Participant", "Mean and group 95% t CI"),
                 pch = c(16, 18), col = c("grey50", "black"), bty = "n", cex = 0.82)

xlim <- range(c(0, ci))
xpad <- max(diff(xlim) * 0.18, 0.5)
graphics::plot(NA, xlim = xlim + c(-xpad, xpad), ylim = c(0.7, 1.3), yaxt = "n",
               xlab = "Mean difference, B minus A (points)", ylab = "",
               main = "Estimated mean difference")
graphics::abline(v = 0, lty = 2, col = "grey45")
graphics::segments(ci[1L], 1, ci[2L], 1, lwd = 4, col = "#009E73")
graphics::points(estimate, 1, pch = 18, cex = 1.8, col = "#009E73")
graphics::text(mean(ci), 1.20,
               labels = sprintf("%.2f points (95%% Welch CI %.2f to %.2f)",
                                estimate, ci[1L], ci[2L]), cex = 0.88)
graphics::mtext("Positive values favor a higher mean in B", side = 3, line = 0.15,
                cex = 0.78, col = "grey35")
grDevices::dev.off()

# Distribution diagnostic plot, kept separate so it is not confused with the
# primary result.
grDevices::png(file.path(output_dir, "diagnostic-plot.png"), width = 1200,
               height = 600, res = 150)
graphics::par(mfrow = c(1, 2), mar = c(4.2, 4.2, 3, 1))
for (j in 1:2) {
  vals <- d$outcome[d$group == levels(d$group)[j]]
  stats::qqnorm(vals, main = sprintf("Normal Q-Q: group %s (n=%d)",
                                     levels(d$group)[j], length(vals)),
                xlab = "Theoretical normal quantiles", ylab = "Observed outcome (points)",
                pch = 16, col = cols[j])
  stats::qqline(vals, lwd = 2, col = "grey35")
}
grDevices::dev.off()

summary_text <- sprintf(
  paste0("Group B's mean was %.2f points %s group A's mean (95%% Welch CI %.2f to %.2f; ",
         "A mean %.2f, B mean %.2f; n=%d). The interval describes uncertainty for the ",
         "population mean difference under independent sampling; the observational design does not identify a causal effect."),
  abs(estimate), if (estimate >= 0) "higher than" else "lower than",
  ci[1L], ci[2L], mean(a), mean(b), length(a) + length(b)
)

estimates <- data.frame(
  result_id = "primary_B_minus_A",
  outcome = "outcome",
  term = "mean(B) - mean(A)",
  estimate = estimate,
  conf_low = ci[1L],
  conf_high = ci[2L],
  conf_level = 0.95,
  scale = "mean difference",
  units = "points",
  n = length(a) + length(b),
  n_A = length(a),
  n_B = length(b),
  p_value = unname(welch$p.value),
  degrees_freedom = unname(welch$parameter),
  method = "Welch two-sample t confidence interval",
  status = "ok",
  stringsAsFactors = FALSE
)

limitations <- c(
  "This is an unadjusted observational comparison: confounding, selection, and group-composition differences can explain the association, so it should not be interpreted causally.",
  "The confidence interval relies on independent participants and a Welch t approximation; independence was supplied by the study description and cannot be verified from the file.",
  "There are only 12 participants per group, so distributional diagnostics and tail behavior are assessed imprecisely and the interval may be sensitive to unusual values.",
  "Generalization depends on how these synthetic participants represent the target population; no sampling frame or practical importance threshold was provided."
)

list(
  summary = summary_text,
  estimates = estimates,
  diagnostics = diagnostics,
  limitations = limitations
)
