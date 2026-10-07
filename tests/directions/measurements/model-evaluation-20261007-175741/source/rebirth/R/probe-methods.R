#' Summarize and plot a statistical probe set
#'
#' @param x,object An `llm_probe` result.
#' @param ... Additional base plotting arguments for `plot()`. Ignored by print
#'   and summary methods.
#' @return `print()` returns its input invisibly. `summary()` returns a classed
#'   list of metrics, counts, split audit, preprocessing and statistical
#'   provenance. `plot()` invisibly returns the displayed metric table.
#' @details Held-out curves mark the layer chosen by development CV. Their
#'   intervals are conditional and pointwise, not simultaneous or causal claims.
#'   Unsupported intervals have a recorded reason. Exploratory CV curves never
#'   receive inferential error bars. The chosen layer is not changed by plotting.
#' @examplesIf requireNamespace("glmnet", quietly = TRUE)
#' # See llm_probe() for a complete model-free example.
#' @name probe-methods
NULL

#' @rdname probe-methods
#' @method print llm_probe
#' @export
print.llm_probe <- function(x, ...) {
  evaluated <- nrow(x$predictions) > 0L
  cat(sprintf("<llm_probe> %d layer(s), binary ridge logistic, %s\n", length(x$layers), x$metric))
  cat(sprintf("  development-selected layer: %d\n", x$selected_layer))
  cat(sprintf("  evaluation: %s\n", if (evaluated) "held-out groups; conditional pointwise intervals" else "exploratory CV only; no inferential intervals"))
  cat(sprintf("  development: %d prompts in %d groups; holdout: %d prompts in %d groups\n",
              x$counts$development$prompts, x$counts$development$groups,
              x$counts$test$prompts, x$counts$test$groups))
  if (isTRUE(x$independent_prompts_assumed)) cat("  grouping: independent prompts assumed (groups = NULL)\n")
  invisible(x)
}

#' @rdname probe-methods
#' @method summary llm_probe
#' @export
summary.llm_probe <- function(object, ...) {
  out <- object[c("call", "formula", "metric", "layers", "component", "selected_layer",
                  "label_mapping", "metrics", "counts", "audit", "protocol", "solver",
                  "independent_prompts_assumed", "estimate_bytes")]
  out$preprocessing <- lapply(object$fits, `[[`, "preprocess")
  class(out) <- "summary.llm_probe"
  out
}

#' @rdname probe-methods
#' @method print summary.llm_probe
#' @export
print.summary.llm_probe <- function(x, ...) {
  cat(sprintf("<llm_probe summary> %s; positive class: %s\n", x$metric, x$label_mapping[["positive"]]))
  cat(sprintf("  layer selected on development CV: %d\n", x$selected_layer))
  cat("  CV scores are selection diagnostics; held-out intervals are conditional and pointwise.\n")
  print(x$metrics, row.names = FALSE)
  cat("  Split audit, class/group counts and preprocessing are available in this summary.\n")
  invisible(x)
}

#' @rdname probe-methods
#' @method plot llm_probe
#' @export
plot.llm_probe <- function(x, ...) {
  table <- x$metrics
  evaluated <- nrow(x$predictions) > 0L
  value <- if (evaluated) table$test_score else table$cv_score
  defaults <- list(x = table$layer, y = value, type = "b", pch = 19,
                   ylim = c(0, 1), xlab = "Layer", ylab = toupper(x$metric),
                   main = if (evaluated) "Held-out decodability" else "Exploratory development CV",
                   sub = if (evaluated) "95% conditional pointwise intervals where supported" else "Selection diagnostics; no inferential confidence intervals")
  dots <- list(...)
  if (length(dots) && (is.null(names(dots)) || any(!nzchar(names(dots))))) {
    probe_abort("Supply plotting options by name, for example col = 'navy'.", "plot")
  }
  defaults[names(dots)] <- dots
  do.call(graphics::plot, defaults)
  if (evaluated) {
    show <- is.finite(table$lower) & is.finite(table$upper)
    if (any(show)) graphics::arrows(table$layer[show], table$lower[show],
                                    table$layer[show], table$upper[show], angle = 90,
                                    code = 3, length = 0.04)
  }
  chosen <- match(x$selected_layer, table$layer)
  graphics::points(table$layer[chosen], value[chosen], pch = 1, cex = 1.7, lwd = 2)
  graphics::legend("bottomright", "Layer selected on development data", pch = 1, bty = "n", cex = 0.8)
  invisible(table)
}

#' Predict binary probabilities from a fitted probe
#'
#' @param object An `llm_probe` result.
#' @param newdata A `relm_trace` with the same component and neuron coordinates
#'   and one position per prompt. It can contain new prompt IDs and needs no labels.
#' @param layer Optional fitted layer index. `NULL` uses the layer selected on
#'   development CV, regardless of held-out performance.
#' @param ... Ignored.
#' @return A numeric probability vector for the positive class, named by prompt
#'   ID in increasing order. Uses the saved development-only transformation and fit.
#' @examplesIf requireNamespace("glmnet", quietly = TRUE)
#' # See llm_probe() for a complete model-free fit and prediction example.
#' @method predict llm_probe
#' @export
predict.llm_probe <- function(object, newdata, layer = NULL, ...) {
  if (is.null(layer)) layer <- object$selected_layer
  if (!is.numeric(layer) || is.complex(layer) || length(layer) != 1L || !is.finite(layer) ||
      !layer %in% object$layers) probe_abort("`layer` must be one of the fitted layers.", "layer")
  if (missing(newdata)) probe_abort("Supply a new relm_trace to predict().", "trace")
  source <- probe_source(newdata, as.integer(layer), object$component,
                         expected_neurons = object$neurons)
  fit <- object$fits[[as.character(layer)]]
  matrix <- source$read(layer)
  transformed <- probe_transform(matrix, fit$preprocess)
  probability <- stats::plogis(as.vector(fit$intercept + transformed %*% fit$coefficients))
  if (any(!is.finite(probability))) probe_abort("Probe prediction produced nonfinite values. Check the captured activations.", "nonfinite")
  stats::setNames(probability, as.character(source$ids))
}
