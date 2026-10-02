data_path <- input_paths[[1L]]
d <- utils::read.csv(data_path, stringsAsFactors = FALSE, check.names = FALSE)

required <- c("id", "group", "outcome")
if (!all(required %in% names(d))) {
  stop("Input must contain columns: id, group, outcome")
}
if (anyDuplicated(d$id)) {
  stop("Participant IDs are duplicated; independence by row cannot be assumed.")
}
if (anyNA(d[, required])) {
  stop("Missing values are present in required columns.")
}
if (!is.numeric(d$outcome) || any(!is.finite(d$outcome))) {
  stop("Outcome must be finite and numeric.")
}
if (!setequal(unique(d$group), c("A", "B"))) {
  stop("Exactly groups A and B are required.")
}

d$group <- factor(d$group, levels = c("A", "B"))
n_by_group <- table(d$group)
mean_a <- mean(d$outcome[d$group == "A"])
mean_b <- mean(d$outcome[d$group == "B"])
difference <- mean_b - mean_a
can_estimate_sampling_variance <- all(n_by_group >= 2L)

if (can_estimate_sampling_variance) {
  fit <- stats::t.test(outcome ~ group, data = d, alternative = "less",
                       var.equal = FALSE, conf.level = 0.95)
  # R parameterizes the formula contrast as mean(A) - mean(B).
  p_value <- unname(fit$p.value)
  inferential_status <- "ok"
  inferential_method <- "One-sided Welch two-sample t test"
} else {
  p_value <- NA_real_
  inferential_status <- "withheld"
  inferential_method <- paste(
    "Population inference unavailable:",
    "within-group variances and a standard error cannot be estimated"
  )
}

estimates <- data.frame(
  result_id = c("group_A_mean", "group_B_mean", "B_minus_A", "B_higher_test"),
  outcome = "outcome",
  term = c("Observed mean, group A", "Observed mean, group B",
           "Observed mean difference, B minus A",
           "Evidence that population mean B exceeds A"),
  estimate = c(mean_a, mean_b, difference, difference),
  conf_low = NA_real_,
  conf_high = NA_real_,
  conf_level = c(NA_real_, NA_real_, NA_real_, 0.95),
  scale = c("mean", "mean", "difference", "difference"),
  units = "outcome units",
  n = c(unname(n_by_group["A"]), unname(n_by_group["B"]),
        nrow(d), nrow(d)),
  n_A = unname(n_by_group["A"]),
  n_B = unname(n_by_group["B"]),
  p_value = c(NA_real_, NA_real_, NA_real_, p_value),
  method = c("Arithmetic mean", "Arithmetic mean", "Difference of arithmetic means",
             inferential_method),
  status = c("ok", "ok", "ok", inferential_status),
  stringsAsFactors = FALSE
)

diagnostics <- data.frame(
  check = c("independence", "missingness", "unique_participants",
            "group_sample_sizes", "sampling_variance", "distributional_shape"),
  status = c("assumed", "pass", "pass", "fail", "fail", "not_assessed"),
  detail = c(
    "Independent people, as supplied by the user; one row per participant was assumed.",
    "No missing values in id, group, or outcome.",
    "Participant IDs are unique.",
    sprintf("Only %d observation in A and %d observation in B.",
            n_by_group["A"], n_by_group["B"]),
    "With one observation per group, neither within-group variance nor the standard error of the mean difference can be estimated.",
    "Normality, skewness, outliers, and variance heterogeneity cannot be evaluated with one observation per group."
  ),
  stringsAsFactors = FALSE
)

limitations <- c(
  "The sample contains one person per group, so it cannot support a confidence interval or a conventional test of population means.",
  "The observed 3-unit difference may reflect ordinary person-to-person variation; its sampling uncertainty is unknown.",
  "Independence alone is insufficient for population generalization; representative or randomized sampling and enough observations per group are also needed.",
  "No causal conclusion is available because group assignment and sampling design are not established as randomized."
)

list(
  summary = c(
    sprintf("Group B's observed mean is %.1f versus %.1f in group A, an observed difference of %.1f outcome units.",
            mean_b, mean_a, difference),
    "This does not provide reliable evidence that the population mean is higher in B: there is only one person in each group, so sampling variability cannot be estimated and inferential results are withheld."
  ),
  estimates = estimates,
  diagnostics = diagnostics,
  limitations = limitations
)
