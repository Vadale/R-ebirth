probe_abort <- function(message, reason, ...) {
  relm_abort("relm_error_probe", message, c(list(reason = reason), list(...)))
}

probe_require_glmnet <- function() {
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    probe_abort("Probes require the optional glmnet package. Install it with install.packages('glmnet').", "dependency")
  }
}

probe_aligned_vector <- function(x, ids, name) {
  if (length(x) != length(ids) || !is.null(dim(x))) {
    probe_abort(sprintf("`%s` must have one element per captured prompt (%d).", name, length(ids)), "alignment")
  }
  if (!is.null(names(x))) {
    if (anyNA(names(x)) || anyDuplicated(names(x)) || !setequal(names(x), as.character(ids))) {
      probe_abort(sprintf("Names of `%s` must match every captured prompt_id exactly once.", name), "alignment")
    }
    x <- x[match(as.character(ids), names(x))]
  }
  unname(x)
}

probe_formula <- function(formula) {
  if (!inherits(formula, "formula") || length(formula) != 3L) {
    probe_abort("Use a two-sided formula: label ~ activations(layer = 1:3).", "formula")
  }
  rhs <- formula[[3L]]
  head <- if (is.call(rhs)) rhs[[1L]] else NULL
  marker <- identical(head, as.name("activations")) ||
    identical(head, quote(relm::activations))
  if (!marker) probe_abort("The formula must contain exactly one activations(layer = ...) marker, without other predictors.", "formula")
  args <- tryCatch(as.list(match.call(activations, rhs))[-1L], error = function(e) NULL)
  if (is.null(args) || is.null(args$layer)) probe_abort("Specify layer = inside activations(); only layer and component are supported.", "formula")
  env <- environment(formula)
  value <- tryCatch(list(
    layer = eval(args$layer, env),
    component = if (is.null(args$component)) "residual" else eval(args$component, env)
  ), error = function(e) probe_abort(paste("Could not evaluate the activation specification:", conditionMessage(e)), "formula"))
  layer <- value$layer
  if (!is.numeric(layer) || is.complex(layer) || !length(layer) || any(!is.finite(layer)) ||
      any(layer < 1 | layer != floor(layer) | layer > .Machine$integer.max) || anyDuplicated(layer)) {
    probe_abort("`layer` must contain distinct positive whole-number layer indices.", "layer")
  }
  component <- value$component
  if (!is.character(component) || length(component) != 1L || is.na(component) ||
      !component %in% c("residual", "attn_out", "mlp_out")) {
    probe_abort("`component` must be residual, attn_out or mlp_out.", "component")
  }
  list(layers = sort(as.integer(layer)), component = component)
}

probe_labels <- function(formula, data, ids) {
  from_column <- any(all.vars(formula[[2L]]) %in% names(data))
  if (from_column && isTRUE(attr(data, "spilled"))) {
    probe_abort("A spilled trace needs a label vector in the formula environment, with one element per captured prompt.", "labels")
  }
  value <- tryCatch(eval(formula[[2L]], if (from_column) as.list(data) else environment(formula),
                         enclos = environment(formula)),
                    error = function(e) probe_abort(paste("Could not evaluate labels:", conditionMessage(e)), "labels"))
  if (from_column) {
    if (length(value) != nrow(data) || !is.null(dim(value))) {
      probe_abort("A trace label column must have one value per trace row, constant within each prompt.", "labels")
    }
    indices <- lapply(ids, function(id) which(data$prompt_id == id))
    if (any(vapply(indices, function(i) length(unique(value[i])) != 1L, logical(1)))) {
      probe_abort("Trace labels differ within a prompt. Attach a prompt-constant label or use an external vector.", "labels")
    }
    value <- value[vapply(indices, `[`, integer(1), 1L)]
    names(value) <- NULL
  } else {
    value <- probe_aligned_vector(value, ids, "label")
  }
  if (anyNA(value)) probe_abort("Labels cannot be missing. Provide a binary label for every captured prompt.", "labels")
  if (is.factor(value) && nlevels(value) == 2L) {
    mapping <- stats::setNames(levels(value), c("negative", "positive"))
    y <- as.integer(value) - 1L
  } else if (is.logical(value) || (is.numeric(value) && !is.complex(value) && all(value %in% c(0, 1)))) {
    mapping <- c(negative = "0", positive = "1")
    y <- as.integer(value)
  } else {
    probe_abort("Labels must be logical, numeric 0/1 or a two-level factor (second level positive).", "labels")
  }
  list(y = y, mapping = mapping)
}

#' Fit grouped statistical probes to activation traces
#'
#' Fits one binary ridge logistic probe per layer using the optional glmnet
#' package. Group-disjoint development cross-validation selects regularization
#' and the default layer. Scaling and fitted coefficients use development data
#' only. A declared holdout evaluates frozen fits; absent a holdout, results are
#' exploratory CV diagnostics without inferential confidence intervals.
#'
#' @param formula A formula such as `label ~ activations(layer = 1:3)`. Labels
#'   are logical, numeric 0/1, or a two-level factor (second level positive), from
#'   a prompt-constant trace column or an external vector in the formula environment.
#' @param data A `relm_trace`, with one captured position per prompt, matching
#'   prompt/position/neuron coordinates across requested layers. Spilled traces
#'   require an external label vector.
#' @param method Currently only `"glmnet"` (binary ridge logistic regression).
#' @param cv Number of group-disjoint development folds, an integer at least 3.
#'   Infeasible class support raises an error rather than reducing this value.
#' @param metric Selection and reporting metric: `"auc"` or `"accuracy"`.
#'   Accuracy uses a fixed probability threshold of 0.5.
#' @param seed Optional nonnegative integer. Seeded calls restore the caller's
#'   RNG state, including its prior absence; `NULL` uses the caller's RNG.
#' @param groups Character source-group IDs, one per captured prompt in increasing
#'   prompt-ID order, or named by exact prompt IDs. `NULL` assumes each prompt is
#'   independent. Related documents, revisions, paraphrases and matched contrasts
#'   must share a caller-supplied group.
#' @param test_groups Character IDs of whole groups reserved before analysis,
#'   or `NULL` for exploratory development CV without held-out estimates.
#' @return An `llm_probe` classed list: development-only `fits`, per-layer
#'   `metrics`, fold-level `cv_scores`, prompt-level split `audit`, held-out
#'   `predictions`, `selected_layer`, counts and statistical provenance. Fits store
#'   compact coefficients and preprocessing, not every CV path or the source trace.
#' @details The fixed ridge grid is `10^seq(4, -4, length.out = 41)`. Each fitting
#'   partition supplies its own means and RMS scales. Constant features are
#'   dropped. Selection uses the mean of fold metrics, with stronger regularization
#'   and then the lower layer breaking ties. Errors inherit `relm_error_probe`;
#'   an estimated materialized-memory excess raises `relm_error_oom` before
#'   densification, using `options(relm.trace_budget)` as a ceiling.
#'
#'   Held-out intervals use 2,000 whole-group bootstrap draws and type-7
#'   percentile quantiles. They are approximate 95% pointwise intervals for
#'   sampling variability conditional on the frozen fits, development data,
#'   selection and split, not training/selection uncertainty or simultaneous
#'   coverage. Intervals are withheld with a reason below 20 evaluation groups,
#'   below five groups containing either class, on undefined draws, or for a
#'   degenerate interval. Larger groups contribute more observations to metrics.
#'   Decodability is association, not evidence of causal use. Repeatedly changing
#'   an analysis after inspecting the holdout consumes its independent status.
#' @seealso [llm_trace()], [activations()], [predict.llm_probe()]
#' @examplesIf requireNamespace("glmnet", quietly = TRUE)
#' # Model-free trace for demonstrating the API, not scientific evidence.
#' label <- rep(0:1, 12)
#' tr <- expand.grid(neuron = 1:2, layer = 1:2, prompt_id = seq_along(label))
#' tr$token_pos <- 1L
#' tr$token <- "example"
#' tr$component <- "residual"
#' tr$value <- sin(tr$prompt_id * tr$neuron) + label[tr$prompt_id]
#' class(tr) <- c("relm_trace", "data.frame")
#' fit <- llm_probe(label ~ activations(layer = 1:2), tr, cv = 3, seed = 42)
#' summary(fit)
#' predict(fit, tr)
#' @export
llm_probe <- function(formula, data, method = "glmnet", cv = 10,
                      metric = c("auc", "accuracy"), seed = NULL,
                      groups = NULL, test_groups = NULL) {
  if (missing(formula) || missing(data)) {
    probe_abort("Supply a formula and a relm_trace: llm_probe(label ~ activations(layer = 1:3), data).", "arguments")
  }
  spec <- probe_formula(formula)
  if (!is.character(method) || length(method) != 1L || is.na(method) || method != "glmnet") {
    probe_abort("`method` currently supports only 'glmnet'.", "method")
  }
  if (!is.numeric(cv) || is.complex(cv) || length(cv) != 1L || !is.finite(cv) ||
      cv < 3 || cv != floor(cv) || cv > .Machine$integer.max) {
    probe_abort("`cv` must be a whole number at least 3.", "cv")
  }
  if (!is.null(seed) && (!is.numeric(seed) || is.complex(seed) || length(seed) != 1L ||
                        !is.finite(seed) || seed < 0 || seed != floor(seed) || seed > .Machine$integer.max)) {
    probe_abort("`seed` must be NULL or a nonnegative whole number within R's integer range.", "seed")
  }
  metric <- tryCatch(match.arg(metric, c("auc", "accuracy")), error = function(e) probe_abort("`metric` must be 'auc' or 'accuracy'.", "metric"))
  probe_require_glmnet()
  source <- probe_source(data, spec$layers, spec$component, as.integer(cv))
  label <- probe_labels(formula, data, source$ids)
  independent <- is.null(groups)
  if (independent) groups <- as.character(source$ids)
  groups <- probe_aligned_vector(groups, source$ids, "groups")
  if (!is.character(groups) || anyNA(groups) || any(!nzchar(groups))) {
    probe_abort("`groups` must contain nonmissing, nonempty character IDs.", "groups")
  }
  if (!is.null(test_groups) && (!is.character(test_groups) || !length(test_groups) ||
      anyNA(test_groups) || any(!nzchar(test_groups)) || anyDuplicated(test_groups) ||
      !all(test_groups %in% groups))) {
    probe_abort("`test_groups` must be NULL or distinct known character group IDs.", "test_groups")
  }
  out <- probe_fit_layers(source$read, spec$layers, source$ids, label$y, groups,
                          test_groups, as.integer(cv), metric, seed, spec$component)
  out$call <- match.call()
  out$formula <- paste(deparse(formula), collapse = " ")
  out$label_mapping <- label$mapping
  out$component <- spec$component
  out$layers <- spec$layers
  out$neurons <- source$neurons
  out$metric <- metric
  out$independent_prompts_assumed <- independent
  out$estimate_bytes <- source$estimate_bytes
  structure(out, class = "llm_probe")
}

#' Select activation features inside a probe formula
#'
#' A formula marker interpreted by [llm_probe()]. Calling it directly is an error.
#' @param layer Distinct positive 1-based layer indices.
#' @param component One of `"residual"`, `"attn_out"` or `"mlp_out"`.
#' @return No standalone value; identifies activation slices inside a probe formula.
#' @examples
#' label ~ activations(layer = 1:3, component = "residual")
#' @export
activations <- function(layer, component = "residual") {
  probe_abort("Use activations() only inside llm_probe(label ~ activations(layer = ...), data).", "formula")
}
