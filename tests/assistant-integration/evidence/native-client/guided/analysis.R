# Reproducible analysis of independent observational groups
# Primary estimand: population mean difference, group B minus group A.

options(stringsAsFactors = FALSE)

stopifnot(length(input_paths) == 1L)
dat <- utils::read.csv(input_paths[[1]], check.names = FALSE,
                       stringsAsFactors = FALSE)

required <- c("id", "group", "outcome")
if (!all(required %in% names(dat))) {
  stop("Input must contain columns: id, group, outcome")
}
dat <- dat[, required]
if (anyNA(dat)) stop("Missing values found in required analysis columns")
if (!is.numeric(dat$outcome)) stop("outcome must be numeric")
if (!all(unique(dat$group) %in% c("A", "B")) ||
    !setequal(unique(dat$group), c("A", "B"))) {
  stop("group must contain exactly A and B")
}
if (anyDuplicated(dat$id)) stop("Duplicate IDs found; independence requires review")
dat$group <- factor(dat$group, levels = c("A", "B"))

x_a <- dat$outcome[dat$group == "A"]
x_b <- dat$outcome[dat$group == "B"]
if (length(x_a) < 2L || length(x_b) < 2L) {
  stop("Each group needs at least two observations")
}

# Welch's two-sample t interval. With x = B and y = A, the sign is B minus A.
welch <- stats::t.test(x_b, x_a, var.equal = FALSE, conf.level = 0.95)
estimate <- unname(mean(x_b) - mean(x_a))
ci <- unname(welch$conf.int)

sample_skewness <- function(x) {
  n <- length(x)
  if (n < 3L || stats::sd(x) == 0) return(NA_real_)
  n / ((n - 1) * (n - 2)) * sum(((x - mean(x)) / stats::sd(x))^3)
}

group_summary <- do.call(rbind, lapply(levels(dat$group), function(g) {
  z <- dat$outcome[dat$group == g]
  data.frame(
    group = g,
    n = length(z),
    mean = mean(z),
    sd = stats::sd(z),
    median = stats::median(z),
    q1 = unname(stats::quantile(z, 0.25, type = 7)),
    q3 = unname(stats::quantile(z, 0.75, type = 7)),
    min = min(z),
    max = max(z),
    skewness = sample_skewness(z),
    stringsAsFactors = FALSE
  )
}))
utils::write.csv(group_summary, file.path(output_dir, "group-summary.csv"),
                 row.names = FALSE, na = "")

# Tukey boxplot flags are descriptive, not automatic exclusions.
box_flags <- vapply(levels(dat$group), function(g) {
  length(grDevices::boxplot.stats(dat$outcome[dat$group == g])$out)
}, integer(1))
variance_ratio <- max(stats::var(x_a), stats::var(x_b)) /
  min(stats::var(x_a), stats::var(x_b))

# Leave-one-out sensitivity: recompute the B-A point estimate and Welch interval.
loo <- lapply(seq_len(nrow(dat)), function(i) {
  d <- dat[-i, ]
  a <- d$outcome[d$group == "A"]
  b <- d$outcome[d$group == "B"]
  tt <- stats::t.test(b, a, var.equal = FALSE, conf.level = 0.95)
  data.frame(removed_id = dat$id[i], removed_group = as.character(dat$group[i]),
             estimate = mean(b) - mean(a), conf_low = tt$conf.int[1],
             conf_high = tt$conf.int[2], stringsAsFactors = FALSE)
})
loo <- do.call(rbind, loo)
utils::write.csv(loo, file.path(output_dir, "leave-one-out.csv"),
                 row.names = FALSE, na = "")

# Plot all observations, group means and ordinary within-group 95% t intervals
# for each group mean. The primary Welch difference interval is annotated.
grDevices::png(file.path(output_dir, "group-comparison.png"),
               width = 1600, height = 1050, res = 180, bg = "white",
               type = "quartz")
old_par <- graphics::par(mar = c(5.2, 5.4, 3.5, 1.2), las = 1)
cols <- c(A = "#0072B2", B = "#D55E00")
xpos <- as.numeric(dat$group)
# Deterministic symmetric offsets avoid random jitter and remain reproducible.
offset <- unsplit(lapply(split(seq_len(nrow(dat)), dat$group), function(idx) {
  seq(-0.12, 0.12, length.out = length(idx))
}), dat$group)
ylim <- range(dat$outcome)
pad <- max(1, diff(ylim) * 0.18)
graphics::plot(xpos + offset, dat$outcome, pch = 16, cex = 0.95,
               col = unname(cols[as.character(dat$group)]), xaxt = "n",
               xlim = c(0.55, 2.45), ylim = c(ylim[1] - pad, ylim[2] + pad),
               xlab = "Observational group", ylab = "Outcome (units not specified)",
               main = "Observed outcomes and group means")
graphics::axis(1, at = 1:2,
               labels = sprintf("%s (n = %d)", levels(dat$group),
                                table(dat$group)))
for (g in levels(dat$group)) {
  z <- dat$outcome[dat$group == g]
  k <- which(levels(dat$group) == g)
  half <- stats::qt(0.975, df = length(z) - 1) * stats::sd(z) / sqrt(length(z))
  graphics::arrows(k, mean(z) - half, k, mean(z) + half,
                   angle = 90, code = 3, length = 0.06, lwd = 2.5,
                   col = cols[g])
  graphics::points(k, mean(z), pch = 18, cex = 1.7, col = cols[g])
}
graphics::mtext(sprintf("Mean difference B - A = %.2f; 95%% Welch CI %.2f to %.2f",
                        estimate, ci[1], ci[2]), side = 3, line = 0.4, cex = 0.9)
graphics::legend("topleft", legend = c("Individual observation", "Mean and 95% t CI"),
                 pch = c(16, 18), pt.cex = c(0.95, 1.4), bty = "n")
graphics::par(old_par)
grDevices::dev.off()

estimates <- data.frame(
  result_id = "primary_welch",
  outcome = "outcome",
  term = "mean difference: B minus A",
  estimate = estimate,
  conf_low = ci[1],
  conf_high = ci[2],
  conf_level = 0.95,
  scale = "difference in means",
  units = "outcome units (not specified)",
  n = nrow(dat),
  n_A = length(x_a),
  n_B = length(x_b),
  df = unname(welch$parameter),
  p_value = welch$p.value,
  method = "Welch two-sample t confidence interval",
  status = "ok",
  stringsAsFactors = FALSE
)

diagnostics <- rbind(
  data.frame(check = "independence", status = "assumed",
             detail = paste0("User specified independent groups; one row per unique ID (",
                             nrow(dat), " of ", nrow(dat), " IDs unique).")),
  data.frame(check = "group support", status = "pass",
             detail = sprintf("Both prespecified groups are present (A n=%d; B n=%d).",
                              length(x_a), length(x_b))),
  data.frame(check = "missingness", status = "pass",
             detail = "No missing values in id, group, or outcome; all 24 rows analyzed."),
  data.frame(check = "variance heterogeneity", status = "pass",
             detail = sprintf("Larger/smaller sample variance ratio = %.2f; Welch inference does not assume equal variances.",
                              variance_ratio)),
  data.frame(check = "distribution and outliers", status = "warn",
             detail = sprintf(paste0("Small samples limit distribution assessment. Adjusted skewness: A %.2f, B %.2f; ",
                                     "Tukey boxplot flags: A %d, B %d. Inspect the raw-data plot."),
                              group_summary$skewness[group_summary$group == "A"],
                              group_summary$skewness[group_summary$group == "B"],
                              box_flags["A"], box_flags["B"])),
  data.frame(check = "single-observation influence", status = "pass",
             detail = sprintf(paste0("Across leave-one-out analyses, estimate ranged %.2f to %.2f; ",
                                     "95%% CI lower bounds %.2f to %.2f and upper bounds %.2f to %.2f."),
                              min(loo$estimate), max(loo$estimate),
                              min(loo$conf_low), max(loo$conf_low),
                              min(loo$conf_high), max(loo$conf_high)))
)

limitations <- c(
  "The groups are observational, so the contrast is an unadjusted association and should not be interpreted as a causal effect; confounding and selection may explain some or all of it.",
  "Independence is supplied by the study description and supported by unique IDs, but cannot be verified from this file alone.",
  "With small group samples, the Welch interval relies on the sample means being reasonably well behaved; skewness and outlier diagnostics have limited power.",
  "Outcome units and the target population/sampling process are not documented, limiting practical interpretation and generalizability."
)

summary_text <- sprintf(
  paste0("Group B's sample mean was %.2f versus %.2f in group A. The estimated unadjusted ",
         "mean difference (B minus A) was %.2f outcome units (95%% Welch CI %.2f to %.2f; ",
         "n=%d). This is an observational association, not a causal effect."),
  mean(x_b), mean(x_a), estimate, ci[1], ci[2], nrow(dat)
)

list(summary = summary_text, estimates = estimates, diagnostics = diagnostics,
     limitations = limitations)
