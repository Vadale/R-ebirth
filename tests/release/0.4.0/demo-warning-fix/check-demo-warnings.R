# Model-free affected check: retained result plot and glmnet selection equivalence.
root <- "/private/tmp/relm-release-0.4.0/warning-fixes"
env <- new.env(parent = globalenv())
for (file in c("tests/demos/demo-utils.R", "tests/demos/demo-A-anatomy-lab.R")) {
  for (expr in parse(file)) {
    if (is.call(expr) && identical(expr[[1L]], as.name("<-"))) eval(expr, env)
  }
}
plot_warnings <- character()
saved <- readRDS("/private/tmp/relm-release-0.4.0/demo-A.rds")
plotted <- withCallingHandlers(env$demo_A_plot(saved, file.path(root, "demo-A-corrected.png")),
  warning = function(w) plot_warnings <<- c(plot_warnings, conditionMessage(w)))
stopifnot(identical(saved, plotted), length(plot_warnings) == 0L,
          sum(saved$lower == saved$upper) == 6L)
set.seed(20240707L)
x <- matrix(rnorm(40L * 12L), 40L, 12L)
y <- factor(rep(c("neg", "pos"), each = 20L), levels = c("neg", "pos"))
foldid <- env$.demo_A_foldid(y == "pos")
# Evaluate the actual producer's measure assignment on this fixture.
find_measure <- function(e) {
  if (!is.call(e)) return(list())
  if (identical(e[[1L]], as.name("<-")) && identical(e[[2L]], as.name("measure"))) return(list(e))
  unlist(lapply(as.list(e)[-1L], find_measure), recursive = FALSE)
}
measure_expr <- find_measure(body(env$.demo_A_probe_by_layer))
stopifnot(length(measure_expr) == 1L)
eval(measure_expr[[1L]])
old_warnings <- new_warnings <- character()
old <- withCallingHandlers(glmnet::cv.glmnet(x, y, family = "binomial", alpha = 0,
  foldid = foldid, type.measure = "auc", keep = TRUE),
  warning = function(w) old_warnings <<- c(old_warnings, conditionMessage(w)))
new <- withCallingHandlers(glmnet::cv.glmnet(x, y, family = "binomial", alpha = 0,
  foldid = foldid, type.measure = measure, keep = TRUE),
  warning = function(w) new_warnings <<- c(new_warnings, conditionMessage(w)))
stopifnot(length(old_warnings) == 1L, length(new_warnings) == 0L,
          grepl("Too few (< 10)", old_warnings, fixed = TRUE), measure == "deviance")
fields <- c("lambda", "lambda.min", "lambda.1se", "cvm", "cvsd", "fit.preval", "foldid")
stopifnot(all(vapply(fields, function(n) identical(old[[n]], new[[n]]), TRUE)),
          identical(coef(old), coef(new)))
x <- matrix(0, 100L, 1L); foldid <- rep(1:10, 10L)
eval(measure_expr[[1L]]); stopifnot(measure == "auc")
saveRDS(list(status = "passed", model_calls = 0L, collapsed_intervals = 6L,
             plot_warnings = plot_warnings, old_warnings = old_warnings,
             new_warnings = new_warnings, exact_fields = fields,
             coefficients_identical = TRUE, larger_fold_policy = measure),
        file.path(root, "demo-warning-owner.rds"))
cat("PASS: six collapsed intervals drawn without warnings; small-fold fits/selection/coefficients exact; larger folds retain AUC; zero model calls.\n")
