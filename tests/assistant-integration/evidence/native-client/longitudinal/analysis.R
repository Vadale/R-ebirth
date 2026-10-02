# Longitudinal score analysis
# Primary estimand: programme-minus-comparison difference in mean linear change
# per visit. The observational group labels describe associations, not effects.

options(contrasts = c("contr.treatment", "contr.poly"), warn = 1)
set.seed(20261002)

input_file <- input_paths[[1]]
d <- utils::read.csv(input_file, stringsAsFactors = FALSE, check.names = FALSE)

required <- c("visit", "person", "group", "score")
stopifnot(all(required %in% names(d)))
stopifnot(is.numeric(d$visit), is.numeric(d$score))
stopifnot(!anyNA(d[required]))
stopifnot(!anyDuplicated(d[c("person", "visit")]))
stopifnot(all(d$visit %in% 0:4))

d$person <- factor(d$person)
d$group <- factor(d$group, levels = c("comparison", "programme"))
stopifnot(!anyNA(d$group))
d <- d[order(d$person, d$visit), ]

n_obs <- nrow(d)
n_people <- nlevels(d$person)
people_by_group <- tapply(d$person, d$group, function(x) length(unique(x)))
visits_per_person <- table(d$person)

# Descriptive summaries by group and visit.
desc <- stats::aggregate(score ~ group + visit, data = d,
                         FUN = function(x) c(n = length(x), mean = mean(x), sd = stats::sd(x)))
descriptive <- data.frame(
  group = desc$group,
  visit = desc$visit,
  n = desc$score[, "n"],
  mean = desc$score[, "mean"],
  sd = desc$score[, "sd"],
  se = desc$score[, "sd"] / sqrt(desc$score[, "n"])
)
descriptive$ci_low <- descriptive$mean - stats::qt(0.975, descriptive$n - 1) * descriptive$se
descriptive$ci_high <- descriptive$mean + stats::qt(0.975, descriptive$n - 1) * descriptive$se
utils::write.csv(descriptive, file.path(output_dir, "descriptive_by_visit.csv"), row.names = FALSE,
                 na = "")

# Primary mixed model: person-specific random intercepts and slopes, fitted by REML.
# A general positive-definite covariance permits correlation between them.
m_primary <- nlme::lme(
  fixed = score ~ visit * group,
  random = ~ visit | person,
  data = d,
  method = "REML",
  na.action = stats::na.fail,
  control = nlme::lmeControl(opt = "optim", msMaxIter = 200, returnObject = FALSE)
)

tt <- summary(m_primary)$tTable
term <- "visit:groupprogramme"
stopifnot(term %in% rownames(tt))
beta <- unname(tt[term, "Value"])
se_beta <- unname(tt[term, "Std.Error"])
df_beta <- unname(tt[term, "DF"])
ci_beta <- beta + c(-1, 1) * stats::qt(0.975, df_beta) * se_beta
p_beta <- unname(tt[term, "p-value"])

# Correlation-structure sensitivity: add residual AR(1) correlation within person.
m_ar1 <- nlme::lme(
  fixed = score ~ visit * group,
  random = ~ visit | person,
  correlation = nlme::corAR1(form = ~ visit | person),
  data = d,
  method = "REML",
  na.action = stats::na.fail,
  control = nlme::lmeControl(opt = "optim", msMaxIter = 200, returnObject = FALSE)
)
tt_ar1 <- summary(m_ar1)$tTable
beta_ar1 <- unname(tt_ar1[term, "Value"])
se_ar1 <- unname(tt_ar1[term, "Std.Error"])
df_ar1 <- unname(tt_ar1[term, "DF"])
ci_ar1 <- beta_ar1 + c(-1, 1) * stats::qt(0.975, df_ar1) * se_ar1
p_ar1 <- unname(tt_ar1[term, "p-value"])
phi_ar1 <- unname(stats::coef(m_ar1$modelStruct$corStruct, unconstrained = FALSE))

# Group-specific estimated slopes and approximate 95% t intervals.
V <- stats::vcov(m_primary)
b <- nlme::fixef(m_primary)
slope_contrasts <- rbind(
  comparison = c(0, 1, 0, 0),
  programme = c(0, 1, 0, 1)
)
colnames(slope_contrasts) <- names(b)
slope_est <- as.vector(slope_contrasts %*% b)
slope_se <- sqrt(diag(slope_contrasts %*% V %*% t(slope_contrasts)))
slope_ci <- cbind(slope_est - stats::qt(0.975, df_beta) * slope_se,
                  slope_est + stats::qt(0.975, df_beta) * slope_se)

# Secondary scale: implied difference in change from visit 0 to 4.
change4 <- 4 * beta
change4_ci <- 4 * ci_beta

# Person-level sensitivity check: estimate one OLS slope per person, then compare
# the 30 independent slopes in each group using Welch's interval/test.
person_split <- split(d, d$person)
person_slopes <- do.call(rbind, lapply(person_split, function(z) {
  data.frame(person = as.character(z$person[1]), group = as.character(z$group[1]),
             slope = unname(stats::coef(stats::lm(score ~ visit, data = z))["visit"]))
}))
person_slopes$group <- factor(person_slopes$group, levels = levels(d$group))
utils::write.csv(person_slopes, file.path(output_dir, "person_slopes.csv"), row.names = FALSE,
                 na = "")
welch <- stats::t.test(slope ~ group, data = person_slopes, var.equal = FALSE)
# t.test reports mean(comparison)-mean(programme); reverse for programme-comparison.
sens_est <- -unname(diff(welch$estimate))
# In the known estimate ordering, diff gives programme-comparison already.
sens_est <- unname(welch$estimate[[2]] - welch$estimate[[1]])
sens_ci <- -rev(unname(welch$conf.int))
sens_p <- unname(welch$p.value)

# Check whether categorical visit-by-group patterns materially outperform linear
# time-by-group patterns. ML is used for fixed-effect model comparison.
d$visit_factor <- factor(d$visit, levels = 0:4)
m_linear_ml <- nlme::lme(
  fixed = score ~ visit * group,
  random = ~ visit | person,
  data = d,
  method = "ML",
  na.action = stats::na.fail,
  control = nlme::lmeControl(opt = "optim", msMaxIter = 200, returnObject = FALSE)
)
m_factor_ml <- nlme::lme(
  fixed = score ~ visit_factor * group,
  random = ~ visit | person,
  data = d,
  method = "ML",
  na.action = stats::na.fail,
  control = nlme::lmeControl(opt = "optim", msMaxIter = 200, returnObject = FALSE)
)
nonlinear_lrt <- stats::anova(m_linear_ml, m_factor_ml)
nonlinear_p <- nonlinear_lrt$`p-value`[2]

# Targeted diagnostics.
resid_norm <- stats::residuals(m_primary, type = "normalized")
fitted_vals <- stats::fitted(m_primary)
resid_lm <- stats::lm(abs(resid_norm) ~ fitted_vals)
hetero_p <- summary(resid_lm)$coefficients["fitted_vals", "Pr(>|t|)"]
shapiro <- stats::shapiro.test(resid_norm)
qq_cor <- stats::cor(sort(resid_norm), stats::qnorm(stats::ppoints(length(resid_norm))))

# Within-person lag-1 residual correlation as a check for residual serial dependence.
lag_pairs <- do.call(rbind, lapply(split(data.frame(person = d$person, visit = d$visit,
                                                   resid = resid_norm), d$person), function(z) {
  z <- z[order(z$visit), ]
  data.frame(a = head(z$resid, -1), b = tail(z$resid, -1))
}))
lag1_cor <- stats::cor(lag_pairs$a, lag_pairs$b)

# Influence check: refit omitting each person and summarize interaction stability.
loo_beta <- vapply(levels(d$person), function(id) {
  fit <- try(nlme::lme(score ~ visit * group, random = ~ visit | person,
                       data = d[d$person != id, ], method = "REML",
                       na.action = stats::na.fail,
                       control = nlme::lmeControl(opt = "optim", msMaxIter = 200)), silent = TRUE)
  if (inherits(fit, "try-error")) return(NA_real_)
  unname(nlme::fixef(fit)[term])
}, numeric(1))

# Predictions and labelled plot.
pred_grid <- expand.grid(visit = 0:4, group = levels(d$group), KEEP.OUT.ATTRS = FALSE)
X <- stats::model.matrix(~ visit * group, pred_grid,
                         contrasts.arg = list(group = stats::contr.treatment(2)))
colnames(X) <- names(b)
pred_grid$fit <- as.vector(X %*% b)
pred_grid$se <- sqrt(diag(X %*% V %*% t(X)))
pred_grid$low <- pred_grid$fit - stats::qt(0.975, df_beta) * pred_grid$se
pred_grid$high <- pred_grid$fit + stats::qt(0.975, df_beta) * pred_grid$se

colors <- c(comparison = "#0072B2", programme = "#D55E00")
p <- ggplot2::ggplot(descriptive, ggplot2::aes(x = visit, y = mean, colour = group)) +
  ggplot2::geom_ribbon(data = pred_grid,
                       ggplot2::aes(x = visit, ymin = low, ymax = high, fill = group),
                       colour = NA, alpha = 0.14, inherit.aes = FALSE) +
  ggplot2::geom_line(data = pred_grid, ggplot2::aes(y = fit), linewidth = 1.1) +
  ggplot2::geom_point(size = 2.6) +
  ggplot2::geom_errorbar(ggplot2::aes(ymin = ci_low, ymax = ci_high), width = 0.08,
                         linewidth = 0.55) +
  ggplot2::scale_colour_manual(values = colors, labels = c("Comparison", "Programme")) +
  ggplot2::scale_fill_manual(values = colors, labels = c("Comparison", "Programme")) +
  ggplot2::scale_x_continuous(breaks = 0:4) +
  ggplot2::labs(
    title = "Scores diverged over visits by observational group",
    subtitle = sprintf("Mixed-model difference in slope: %.2f points/visit (95%% CI %.2f to %.2f)",
                       beta, ci_beta[1], ci_beta[2]),
    x = "Visit", y = "Mean score (points)", colour = "Group", fill = "Group",
    caption = "Points/error bars: observed means and 95% CIs. Lines/bands: linear mixed-model means and 95% CIs. n = 30 people/group."
  ) +
  ggplot2::theme_minimal(base_size = 12) +
  ggplot2::theme(legend.position = "top", panel.grid.minor = ggplot2::element_blank(),
                 plot.caption = ggplot2::element_text(hjust = 0))
ggplot2::ggsave(file.path(output_dir, "trajectory_plot.png"), p, width = 8, height = 5.5,
                dpi = 180, bg = "white")

# Residual diagnostic panel.
png(file.path(output_dir, "diagnostic_plots.png"), width = 1400, height = 650, res = 150)
oldpar <- graphics::par(mfrow = c(1, 2), mar = c(4.5, 4.5, 2.5, 1))
graphics::plot(fitted_vals, resid_norm, pch = 19, col = grDevices::adjustcolor("#0072B2", 0.55),
               xlab = "Fitted score (points)", ylab = "Normalized residual",
               main = "Residuals vs fitted")
graphics::abline(h = 0, lty = 2, col = "grey40")
stats::qqnorm(resid_norm, pch = 19, col = grDevices::adjustcolor("#D55E00", 0.55),
              main = "Normal Q-Q plot")
stats::qqline(resid_norm, col = "grey30", lwd = 2)
graphics::par(oldpar)
grDevices::dev.off()

estimates <- data.frame(
  result_id = c("primary_slope_difference", "comparison_slope", "programme_slope",
                "visit0_to_4_difference_in_change", "person_level_sensitivity",
                "ar1_correlation_sensitivity"),
  outcome = "score",
  term = c("Programme minus comparison difference in slope",
           "Comparison-group slope", "Programme-group slope",
           "Programme minus comparison difference in change, visit 0 to 4",
           "Programme minus comparison difference in mean person-specific slope",
           "Programme minus comparison difference in slope with residual AR(1)"),
  estimate = c(beta, slope_est[1], slope_est[2], change4, sens_est, beta_ar1),
  conf_low = c(ci_beta[1], slope_ci[1, 1], slope_ci[2, 1], change4_ci[1], sens_ci[1], ci_ar1[1]),
  conf_high = c(ci_beta[2], slope_ci[1, 2], slope_ci[2, 2], change4_ci[2], sens_ci[2], ci_ar1[2]),
  conf_level = 0.95,
  scale = c("difference in linear slopes", "linear slope", "linear slope",
            "difference in linear change", "difference in mean OLS slopes",
            "difference in linear slopes"),
  units = c("points per visit", "points per visit", "points per visit", "points", "points per visit",
            "points per visit"),
  n = c(n_obs, n_obs, n_obs, n_obs, n_people, n_obs),
  n_clusters = n_people,
  p_value = c(p_beta, NA, NA, p_beta, sens_p, p_ar1),
  method = c("Linear mixed model with random person intercept and slope; t-based 95% CI",
             "Linear mixed model; t-based 95% CI", "Linear mixed model; t-based 95% CI",
             "Four times mixed-model interaction; t-based 95% CI",
             "Welch comparison of independently estimated person-level OLS slopes; 95% CI",
             "Linear mixed model with random intercept/slope and residual AR(1); t-based 95% CI"),
  status = "ok",
  stringsAsFactors = FALSE
)

diagnostics <- data.frame(
  check = c("data_structure", "missingness", "mixed_model_convergence",
            "linear_time_form", "residual_shape", "variance_pattern",
            "residual_serial_correlation", "person_influence", "causal_interpretation"),
  status = c("pass", "pass", "pass",
             if (is.na(nonlinear_p)) "not_assessed" else if (nonlinear_p < 0.05) "warn" else "pass",
             if (qq_cor < 0.98) "warn" else "pass",
             if (hetero_p < 0.01) "warn" else "pass",
             if (abs(phi_ar1) > 0.25 || abs(beta_ar1 - beta) > 0.1) "warn" else "pass",
             if (anyNA(loo_beta) || max(abs(loo_beta - beta), na.rm = TRUE) > abs(beta) * 0.25) "warn" else "pass",
             "warn"),
  detail = c(
    sprintf("%d observations from %d people; %d people per group; every person has %s visits; no duplicate person-visit rows.",
            n_obs, n_people, people_by_group[[1]], paste(sort(unique(visits_per_person)), collapse = ", ")),
    "No missing values in visit, person, group, or score.",
    sprintf("nlme fit completed; convergence code is implicit success. Random-effects structure: correlated person intercept and slope. AIC %.1f.", stats::AIC(m_primary)),
    sprintf("ML likelihood-ratio comparison of categorical versus linear visit: p = %.4g (lower values indicate departures from a linear time-by-group pattern).", nonlinear_p),
    sprintf("Normalized residual Q-Q correlation = %.3f; Shapiro-Wilk p = %.4g. The Q-Q plot is provided; the p-value is descriptive, not a model-selection rule.", qq_cor, shapiro$p.value),
    sprintf("Regression of absolute normalized residual on fitted value: p = %.4g.", hetero_p),
    sprintf("The primary model's pooled conditional-residual lag-1 correlation was %.3f. An AR(1) sensitivity model estimated phi = %.3f and a slope difference of %.3f (95%% CI %.3f to %.3f), versus %.3f primary.", lag1_cor, phi_ar1, beta_ar1, ci_ar1[1], ci_ar1[2], beta),
    sprintf("Leave-one-person-out interaction estimates ranged %.3f to %.3f points/visit; %d of %d refits failed.", min(loo_beta, na.rm = TRUE), max(loo_beta, na.rm = TRUE), sum(is.na(loo_beta)), n_people),
    "Groups are observational; estimates describe association and should not be interpreted as causal programme effects without identification assumptions and confounder adjustment."
  ), stringsAsFactors = FALSE
)

summary_text <- c(
  sprintf("Scores increased faster in the programme group: the estimated slope difference was %.2f points per visit (95%% CI %.2f to %.2f; p = %.3g).", beta, ci_beta[1], ci_beta[2], p_beta),
  sprintf("This corresponds to %.2f more points of change from visit 0 to 4 (95%% CI %.2f to %.2f).", change4, change4_ci[1], change4_ci[2]),
  sprintf("The person-level sensitivity estimate was %.2f points per visit (95%% CI %.2f to %.2f; p = %.3g), using each person as the independent unit.", sens_est, sens_ci[1], sens_ci[2], sens_p),
  sprintf("Allowing residual AR(1) correlation gave %.2f points per visit (95%% CI %.2f to %.2f; estimated phi %.2f).", beta_ar1, ci_ar1[1], ci_ar1[2], phi_ar1),
  "Because group membership is observational, these are trajectory associations rather than causal effects."
)

list(
  summary = summary_text,
  estimates = estimates,
  diagnostics = diagnostics,
  limitations = c(
    "The observational design does not by itself support a causal programme-effect interpretation.",
    "The primary estimand summarizes trajectories as linear over visits 0 through 4; the categorical-time comparison diagnoses material departures.",
    "Mixed-model intervals rely on the specified Gaussian random-effects/residual model and approximate finite-sample t inference."
  )
)
