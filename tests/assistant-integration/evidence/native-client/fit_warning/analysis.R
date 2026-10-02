# Reproduce the incident configuration exactly once and retain its diagnostics.
# This script is intended to be run by the r-statistical-analysis runner.

stopifnot(length(input_paths) == 1L)
dat <- utils::read.csv(input_paths[[1L]], check.names = FALSE)

required_names <- c("x", "outcome")
if (!identical(names(dat), required_names)) {
  stop("Expected observations.csv to contain exactly the columns x and outcome.")
}
if (!is.numeric(dat$x) || !is.numeric(dat$outcome)) {
  stop("x and outcome must be numeric.")
}
if (anyNA(dat) || !all(dat$outcome %in% c(0, 1))) {
  stop("The analysis requires complete data and a binary 0/1 outcome.")
}

fit_warnings <- character()
incident_fit <- withCallingHandlers(
  stats::glm(
    outcome ~ x,
    data = dat,
    family = stats::binomial(),
    control = stats::glm.control(maxit = 1)
  ),
  warning = function(w) {
    # Do not muffle here: the outer runner must also retain the actual warning.
    fit_warnings <<- c(fit_warnings, conditionMessage(w))
  }
)

# These are ordinary model-based Wald calculations from the one nonconverged
# fit. They are preserved for diagnosis, but withheld from inferential use.
coefficient_matrix <- summary(incident_fit)$coefficients
z_critical <- stats::qnorm(0.975)
wald_low <- coefficient_matrix[, "Estimate"] -
  z_critical * coefficient_matrix[, "Std. Error"]
wald_high <- coefficient_matrix[, "Estimate"] +
  z_critical * coefficient_matrix[, "Std. Error"]

outcome_zero_x <- dat$x[dat$outcome == 0]
outcome_one_x <- dat$x[dat$outcome == 1]
complete_ordering <- max(outcome_zero_x) < min(outcome_one_x) ||
  max(outcome_one_x) < min(outcome_zero_x)

status_record <- data.frame(
  model = "glm(outcome ~ x, family = binomial(), control = glm.control(maxit = 1))",
  converged = incident_fit$converged,
  iterations = incident_fit$iter,
  boundary = incident_fit$boundary,
  warning_count = length(fit_warnings),
  warning = if (length(fit_warnings)) paste(fit_warnings, collapse = " | ") else "",
  stringsAsFactors = FALSE
)
utils::write.csv(
  status_record,
  file.path(output_dir, "fit-status.csv"),
  row.names = FALSE,
  na = "NA",
  fileEncoding = "UTF-8"
)

estimates <- data.frame(
  result_id = paste0("coefficient_", c("intercept", "x")),
  outcome = "outcome",
  term = rownames(coefficient_matrix),
  estimate = unname(coefficient_matrix[, "Estimate"]),
  conf_low = unname(wald_low),
  conf_high = unname(wald_high),
  conf_level = 0.95,
  scale = "log odds",
  units = c("log odds at x = 0", "log odds per one-unit increase in x"),
  n = nrow(dat),
  standard_error = unname(coefficient_matrix[, "Std. Error"]),
  p_value = unname(coefficient_matrix[, "Pr(>|z|)"]),
  method = "Nominal 95% model-based Wald interval from the nonconverged maxit=1 fit",
  status = "withheld",
  stringsAsFactors = FALSE
)

diagnostics <- data.frame(
  check = c(
    "fit_convergence",
    "iteration_budget",
    "fit_warning",
    "outcome_support",
    "missingness",
    "complete_ordering_separation",
    "independence"
  ),
  status = c(
    if (isTRUE(incident_fit$converged)) "pass" else "fail",
    "warn",
    if (length(fit_warnings)) "fail" else "pass",
    "pass",
    "pass",
    if (complete_ordering) "fail" else "pass",
    "assumed"
  ),
  detail = c(
    paste0("glm converged = ", incident_fit$converged, "; iterations = ", incident_fit$iter, "."),
    "The requested incident configuration used glm.control(maxit = 1); no alternative fit was run.",
    if (length(fit_warnings)) paste(fit_warnings, collapse = " | ") else "No warning was emitted.",
    paste0("Analytic n = ", nrow(dat), "; outcome 0 = ", sum(dat$outcome == 0),
           "; outcome 1 = ", sum(dat$outcome == 1), "."),
    "There are no missing x or outcome values.",
    paste0(
      "Complete ordering by x = ", complete_ordering,
      "; max x for outcome 0 = ", max(outcome_zero_x),
      "; min x for outcome 1 = ", min(outcome_one_x),
      ". This indicates complete separation when TRUE."
    ),
    "The file has one row per observation, but independence cannot be verified from these two columns."
  ),
  stringsAsFactors = FALSE
)

list(
  summary = c(
    paste0(
      "The exact maxit = 1 logistic regression did not converge (converged = ",
      incident_fit$converged, ", iterations = ", incident_fit$iter,
      ") and emitted: ", paste(fit_warnings, collapse = " | "), "."
    ),
    "Its nominal coefficient Wald intervals are retained in estimates.csv but marked withheld; they are not trustworthy for reporting because the likelihood optimization did not converge and the data show complete separation."
  ),
  estimates = estimates,
  diagnostics = diagnostics,
  limitations = c(
    "No model with a larger iteration budget, alternative estimator, or profile-likelihood interval was fitted.",
    "The data contain only x and outcome, so observation independence and broader design assumptions cannot be verified.",
    "The computed Wald intervals use the incomplete fit's curvature and therefore do not have a defensible usual confidence-interval interpretation."
  )
)
