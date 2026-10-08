# WP11b statistical core, D-033. No trace or filesystem operations belong here.
probe_lambda_grid <- function() 10^seq(4, -4, length.out = 41L)

probe_preprocess <- function(x) {
  center <- colMeans(x)
  scale <- vapply(seq_len(ncol(x)), function(j) {
    column <- x[, j]
    if (all(column == column[[1L]])) return(0)
    delta <- column - center[[j]]
    largest <- max(abs(delta))
    # Rescaling before squaring avoids overflow/underflow in the RMS sum.
    value <- largest * sqrt(mean((delta / largest)^2))
    if (!is.finite(value) || value <= 0) {
      probe_abort("Feature scaling exceeded numerical precision; rescale the input features.", "scaling_nonfinite")
    }
    value
  }, numeric(1))
  names(center) <- names(scale) <- colnames(x)
  if (any(!is.finite(center))) {
    probe_abort("Feature means are not finite; rescale the input features.", "scaling_nonfinite")
  }
  keep <- which(scale > 0)
  if (!length(keep)) {
    probe_abort("All features are constant in a fitting partition; capture informative neurons or use more independent observations.", "constant_features")
  }
  list(center = center, scale = scale, keep = unname(keep))
}

probe_transform <- function(x, preprocess, layer = NULL, fold = NULL) {
  keep <- preprocess$keep
  result <- sweep(sweep(x[, keep, drop = FALSE], 2L, preprocess$center[keep], "-"),
    2L, preprocess$scale[keep], "/")
  if (any(!is.finite(result))) {
    probe_abort("Transformed features are not finite; rescale the input features.", "scaling_nonfinite", layer = layer, fold = fold)
  }
  result
}

# Narrow solver seam: callers/tests can replace this helper without modifying
# the glmnet namespace. Expected small-class warnings are deliberately visible.
probe_glmnet <- function(x, y, lambda) {
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    probe_abort("Probes require the optional glmnet package; install.packages('glmnet') and retry.", "missing_dependency")
  }
  previous <- glmnet::glmnet.control()
  on.exit(do.call(glmnet::glmnet.control, previous), add = TRUE)
  glmnet::glmnet.control(factory = TRUE)
  glmnet::glmnet.control(fdev = 0, devmax = 1)
  args <- list(x = x, y = y, family = "binomial", alpha = 0, lambda = lambda,
    standardize = FALSE, intercept = TRUE)
  settings <- list(thresh = 1e-14, maxit = 1000000L)
  if ("control" %in% names(formals(glmnet::glmnet))) {
    args$control <- settings
  } else {
    args <- c(args, settings)
  }
  do.call(glmnet::glmnet, args)
}

probe_ridge_fit <- function(x, y, lambda, layer = NULL, fold = NULL) {
  p <- ncol(x)
  if (p == 1L) x <- cbind(x, .probe_zero_padding = 0)
  fitted <- tryCatch(probe_glmnet(x, y, lambda), error = function(e) {
    probe_abort(paste0("Ridge fitting failed: ", conditionMessage(e)),
      if (inherits(e, "relm_error_probe")) e$reason else "solver_failure", layer = layer, fold = fold)
  })
  if (length(fitted$jerr) != 1L || is.na(fitted$jerr) || fitted$jerr != 0L) {
    probe_abort("The ridge solver did not converge for the complete requested path; use more independent observations or inspect feature scaling.",
      "solver_convergence", layer = layer, fold = fold, solver_code = fitted$jerr)
  }
  coefficients <- as.matrix(fitted$beta)
  complete <- length(fitted$lambda) == length(lambda) &&
    length(fitted$a0) == length(lambda) && ncol(coefficients) == length(lambda) &&
    nrow(coefficients) == ncol(x) && all(is.finite(fitted$lambda)) &&
    all(abs(fitted$lambda - lambda) <= 1e-12 * pmax(1, abs(lambda))) &&
    all(is.finite(fitted$a0)) && all(is.finite(coefficients))
  if (!complete) {
    probe_abort("The ridge solver returned an incomplete or nonfinite lambda path; no partial path can be selected.",
      "solver_path", layer = layer, fold = fold)
  }
  list(intercept = unname(fitted$a0), coefficients = coefficients[seq_len(p), , drop = FALSE],
    lambda = unname(fitted$lambda), solver = list(version = as.character(utils::packageVersion("glmnet")),
      thresh = 1e-14, maxit = 1000000L, fdev = 0, devmax = 1, jerr = fitted$jerr, npasses = fitted$npasses))
}

probe_metric <- function(y, score, metric) {
  if (length(y) != length(score) || anyNA(y) || any(!y %in% c(0L, 1L)) || any(!is.finite(score))) {
    probe_abort("Metrics require aligned binary labels and finite scores.", "metric_values")
  }
  if (!length(y)) return(NA_real_)
  if (metric == "accuracy") return(mean((score >= 0.5) == y))
  positive <- sum(y == 1L)
  negative <- sum(y == 0L)
  if (!positive || !negative) return(NA_real_)
  ranks <- rank(score, ties.method = "average")
  (sum(ranks[y == 1L]) - positive * (positive + 1) / 2) / (positive * negative)
}

probe_counts <- function(y, groups) {
  list(prompts = length(y), groups = length(unique(groups)), positive = sum(y == 1L),
    negative = sum(y == 0L), positive_groups = length(unique(groups[y == 1L])),
    negative_groups = length(unique(groups[y == 0L])))
}

probe_check_classes <- function(y, groups, partition, minimum = 1L, fold = NULL) {
  counts <- probe_counts(y, groups)
  if (min(counts$positive, counts$negative) < minimum) {
    probe_abort(sprintf("The %s partition needs at least %d observations of each class; use fewer folds, another seed, or more independent groups.", partition, minimum),
      "class_support", partition = partition, fold = fold, counts = counts)
  }
  counts
}

probe_allocate_folds <- function(y, groups, cv) {
  group_ids <- sort(unique(groups), method = "radix")
  counts <- probe_counts(y, groups)
  if (length(group_ids) < cv || min(counts$positive_groups, counts$negative_groups) < cv) {
    probe_abort("Grouped CV needs at least cv development groups containing each class; use fewer folds or more independent groups.",
      "cv_infeasible", cv = cv, counts = counts)
  }
  group_index <- match(groups, group_ids)
  class_counts <- cbind(tabulate(group_index[y == 0L], length(group_ids)),
    tabulate(group_index[y == 1L], length(group_ids)))
  group_order <- order(-rowSums(class_counts), sample.int(length(group_ids)))
  fold_order <- sample.int(cv)
  totals <- colSums(class_counts)
  target <- totals / cv
  allocated <- matrix(0, nrow = cv, ncol = 2L)
  assignment <- integer(length(group_ids))
  for (g in group_order) {
    # The other folds contribute a common constant to the specified global cost.
    costs <- vapply(fold_order, function(f) {
      sum(((allocated[f, ] + class_counts[g, ] - target)^2 -
        (allocated[f, ] - target)^2) / totals^2)
    }, numeric(1))
    chosen <- fold_order[which.min(costs)]
    assignment[[g]] <- chosen
    allocated[chosen, ] <- allocated[chosen, ] + class_counts[g, ]
  }
  assignment[group_index]
}

probe_intervals <- function(y, score, groups, metric, draws = NULL, display = TRUE) {
  if (length(groups) != length(y) || anyNA(groups) || any(!nzchar(groups))) {
    probe_abort("Bootstrap groups must be aligned, nonmissing and nonempty.", "bootstrap_groups")
  }
  probe_metric(y, score, metric)
  counts <- probe_counts(y, groups)
  if (!length(y)) {
    return(c(list(lower = NA_real_, upper = NA_real_, status = "not_evaluated",
      valid_draws = 0L, undefined_draws = 0L, values = numeric()), counts[c("groups", "positive_groups", "negative_groups")]))
  }
  group_ids <- sort(unique(groups), method = "radix")
  group_index <- match(groups, group_ids)
  n_groups <- length(group_ids)
  if (is.matrix(draws)) draws <- lapply(seq_len(nrow(draws)), function(i) draws[i, ])
  if (!is.null(draws) && (!is.list(draws) || !length(draws) ||
    any(vapply(draws, function(draw) length(draw) != n_groups || anyNA(draw) ||
      any(!draw %in% group_ids), logical(1))))) {
    probe_abort("Fixed bootstrap draws must each contain G known group IDs, preserving repetitions.", "bootstrap_draws")
  }
  n_draws <- if (is.null(draws)) 2000L else length(draws)
  ordered <- order(score)
  sorted_y <- y[ordered]
  tied_scores <- cumsum(c(TRUE, diff(score[ordered]) != 0))
  correct <- (score >= 0.5) == y
  values <- vapply(seq_len(n_draws), function(b) {
    selected <- if (is.null(draws)) sample.int(n_groups, n_groups, replace = TRUE) else match(draws[[b]], group_ids)
    weights <- tabulate(selected, n_groups)[group_index]
    if (metric == "accuracy") return(sum(weights * correct) / sum(weights))
    weights <- weights[ordered]
    # Weighted pair wins are exactly an expansion of every sampled group member,
    # but never allocate the potentially O(n*G) repeated observation vector.
    blocks <- rowsum(cbind(weights * sorted_y, weights * (1 - sorted_y)), tied_scores, reorder = FALSE)
    positive <- sum(blocks[, 1L])
    negative <- sum(blocks[, 2L])
    if (!positive || !negative) return(NA_real_)
    sum(blocks[, 1L] * (cumsum(blocks[, 2L]) - blocks[, 2L] / 2)) / (positive * negative)
  }, numeric(1))
  undefined <- sum(is.na(values))
  bounds <- if (undefined) c(NA_real_, NA_real_) else unname(stats::quantile(values, c(0.025, 0.975), type = 7))
  status <- if (display && n_groups < 20L) "insufficient_groups" else
    if (display && min(counts$positive_groups, counts$negative_groups) < 5L) "insufficient_class_groups" else
      if (undefined) "undefined_draw" else if (bounds[[1L]] == bounds[[2L]]) "degenerate_bootstrap" else "available"
  if (status != "available") bounds[] <- NA_real_
  c(list(lower = bounds[[1L]], upper = bounds[[2L]], status = status,
    valid_draws = n_draws - undefined, undefined_draws = undefined, values = values),
    counts[c("groups", "positive_groups", "negative_groups")])
}

probe_fit_layers <- function(read_layer, layers, ids, labels, groups, test_groups,
                             cv, metric, seed, component) {
  rng_kind <- RNGkind()
  if (!is.null(seed)) {
    had_seed <- exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)
    previous_seed <- if (had_seed) get(".Random.seed", envir = .GlobalEnv) else NULL
    on.exit({
      do.call(RNGkind, as.list(rng_kind))
      if (had_seed) assign(".Random.seed", previous_seed, envir = .GlobalEnv) else
        if (exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)) rm(".Random.seed", envir = .GlobalEnv)
    }, add = TRUE)
    set.seed(seed)
  }
  test <- groups %in% test_groups
  development <- !test
  development_counts <- probe_check_classes(labels[development], groups[development], "development", 2L)
  test_counts <- if (any(test)) probe_check_classes(labels[test], groups[test], "test") else probe_counts(integer(), character())
  folds <- rep(NA_integer_, length(ids))
  allocated <- probe_allocate_folds(labels[development], groups[development], cv)
  if (!is.numeric(allocated) || is.complex(allocated) || length(allocated) != sum(development) ||
    anyNA(allocated) || any(!is.finite(allocated)) || any(allocated != round(allocated)) ||
    any(allocated < 1L | allocated > cv) || length(unique(allocated)) != cv) {
    probe_abort("Grouped CV returned incomplete or invalid fold assignments; no observations were fitted.",
      "fold_allocation", cv = cv, counts = development_counts)
  }
  first_member <- match(groups[development], groups[development])
  if (any(allocated != allocated[first_member])) {
    probe_abort("A development source group crosses CV folds; no observations were fitted.",
      "fold_leakage", cv = cv)
  }
  folds[development] <- as.integer(allocated)
  fold_counts <- vector("list", cv * 2L)
  for (f in seq_len(cv)) {
    validation <- development & !is.na(folds) & folds == f
    training <- development & !is.na(folds) & folds != f
    fold_counts[[2L * f - 1L]] <- data.frame(fold = f, partition = "training",
      as.data.frame(probe_check_classes(labels[training], groups[training], "CV fitting", 2L, f)))
    fold_counts[[2L * f]] <- data.frame(fold = f, partition = "validation",
      as.data.frame(probe_check_classes(labels[validation], groups[validation], "CV validation", 1L, f)))
  }
  audit <- data.frame(prompt_id = ids, group = groups, partition = ifelse(test, "test", "development"),
    fold = folds, label = labels, stringsAsFactors = FALSE)
  lambda <- probe_lambda_grid()
  fits <- stats::setNames(vector("list", length(layers)), as.character(layers))
  metrics <- data.frame(layer = layers, lambda = NA_real_, cv_score = NA_real_, test_score = NA_real_,
    lower = NA_real_, upper = NA_real_, interval_status = "not_evaluated", valid_draws = 0L,
    undefined_draws = 0L, boundary = FALSE, stringsAsFactors = FALSE)
  cv_scores <- vector("list", length(layers))
  probabilities <- matrix(NA_real_, nrow = sum(test), ncol = length(layers))
  solver <- NULL
  for (i in seq_along(layers)) {
    layer <- layers[[i]]
    x <- read_layer(layer)
    fold_scores <- matrix(NA_real_, nrow = length(lambda), ncol = cv)
    for (f in seq_len(cv)) {
      training <- which(development & !is.na(folds) & folds != f)
      validation <- which(development & !is.na(folds) & folds == f)
      preprocessing <- tryCatch(probe_preprocess(x[training, , drop = FALSE]), relm_error_probe = function(e) {
        e$layer <- layer; e$fold <- f; stop(e)
      })
      fit <- probe_ridge_fit(probe_transform(x[training, , drop = FALSE], preprocessing, layer, f), labels[training], lambda, layer, f)
      validation_x <- probe_transform(x[validation, , drop = FALSE], preprocessing, layer, f)
      predicted <- stats::plogis(sweep(validation_x %*% fit$coefficients, 2L, fit$intercept, "+"))
      if (any(!is.finite(predicted))) {
        probe_abort("CV probabilities are nonfinite; inspect feature scaling.", "prediction_nonfinite", layer = layer, fold = f)
      }
      fold_scores[, f] <- vapply(seq_along(lambda), function(j) probe_metric(labels[validation], predicted[, j], metric), numeric(1))
      rm(fit, validation_x, predicted, preprocessing)
    }
    scores <- rowMeans(fold_scores)
    if (any(!is.finite(scores))) {
      probe_abort("CV produced a nonfinite selection score; inspect class support and feature scaling.", "cv_score", layer = layer)
    }
    chosen <- which(scores >= max(scores) - 1e-12)[[1L]]
    cv_scores[[i]] <- data.frame(layer = layer, lambda = rep(lambda, each = cv),
      fold = rep(seq_len(cv), times = length(lambda)), score = as.vector(t(fold_scores)))
    preprocessing <- tryCatch(probe_preprocess(x[development, , drop = FALSE]), relm_error_probe = function(e) {
      e$layer <- layer; stop(e)
    })
    # Warm-start the development refit along the same fixed descending grid.
    # A cold fit at a small selected lambda can fail on wide correlated traces;
    # no weaker penalty beyond the selected endpoint is needed or accepted.
    fit <- probe_ridge_fit(probe_transform(x[development, , drop = FALSE], preprocessing, layer),
      labels[development], lambda[seq_len(chosen)], layer)
    fits[[i]] <- list(intercept = fit$intercept[[chosen]], coefficients = stats::setNames(fit$coefficients[, chosen],
      colnames(x)[preprocessing$keep]), preprocess = preprocessing, lambda = lambda[[chosen]])
    metrics$lambda[[i]] <- lambda[[chosen]]
    metrics$cv_score[[i]] <- scores[[chosen]]
    metrics$boundary[[i]] <- chosen %in% c(1L, length(lambda))
    solver <- fit$solver
    if (any(test)) {
      probabilities[, i] <- stats::plogis(as.vector(
        probe_transform(x[test, , drop = FALSE], preprocessing, layer) %*% fits[[i]]$coefficients) + fits[[i]]$intercept)
      if (any(!is.finite(probabilities[, i]))) {
        probe_abort("Held-out probabilities are nonfinite; inspect feature scaling.", "prediction_nonfinite", layer = layer)
      }
    }
    rm(x, fit, preprocessing, fold_scores)
  }
  selected_layer <- layers[which(metrics$cv_score >= max(metrics$cv_score) - 1e-12)[[1L]]]
  # Fitting and development selection are complete before evaluation labels are
  # scored. Replaying this state gives every layer identical group draws, without
  # retaining a G-by-2000 sample matrix. NULL-seed calls advance one such stream.
  if (any(test)) {
    bootstrap_seed <- get(".Random.seed", envir = .GlobalEnv)
    for (i in seq_along(layers)) {
      assign(".Random.seed", bootstrap_seed, envir = .GlobalEnv)
      metrics$test_score[[i]] <- probe_metric(labels[test], probabilities[, i], metric)
      interval <- probe_intervals(labels[test], probabilities[, i], groups[test], metric)
      metrics$lower[[i]] <- interval$lower
      metrics$upper[[i]] <- interval$upper
      metrics$interval_status[[i]] <- interval$status
      metrics$valid_draws[[i]] <- interval$valid_draws
      metrics$undefined_draws[[i]] <- interval$undefined_draws
    }
  }
  predictions <- data.frame(prompt_id = rep(ids[test], times = length(layers)),
    group = rep(groups[test], times = length(layers)), label = rep(labels[test], times = length(layers)),
    layer = rep(layers, each = sum(test)), probability = as.vector(probabilities), stringsAsFactors = FALSE)
  list(fits = fits, metrics = metrics, cv_scores = do.call(rbind, cv_scores), audit = audit,
    selected_layer = selected_layer, predictions = predictions,
    counts = list(development = development_counts, test = test_counts, folds = do.call(rbind, fold_counts)),
    layers = layers, component = component, metric = metric, cv = cv, seed = seed, rng_kind = rng_kind,
    lambda_grid = lambda, solver = solver,
    protocol = list(version = "grouped-probe-v1", fold_allocation = "class-balanced-greedy-v1",
      selection = "unweighted mean fold score; ties within 1e-12 prefer largest lambda and smallest layer",
      bootstrap_draws = 2000L, bootstrap_unit = "whole evaluation groups", quantile_type = 7L,
      interval = "Approximate 95% pointwise held-out sampling intervals conditional on fitted models, development data, selection and split",
      evaluation = if (any(test)) "held_out" else "exploratory_cv_only"))
}
