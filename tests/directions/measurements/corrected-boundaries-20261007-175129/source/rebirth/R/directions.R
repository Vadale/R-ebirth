#' Construct a recorded contrast direction
#'
#' Build a unit residual direction from paired, already collected activations.
#' The positive sign is target minus control. This function performs no inference.
#'
#' @param target,control Plain double matrices with identical named pairs as rows
#'   and complete, ordered neuron names `"1"` through the hidden width as columns.
#' @param context For construction, a recorded list with `model`, `capture`,
#'   `pairs`, `splits` and `seed`; see Details and the contrast-directions vignette.
#'   For application, an independently recorded destination `model` record.
#' @param layer One whole layer from 2 through the recorded model's layer count.
#' @param normalize_pairs Whether to give each pair difference unit length before
#'   averaging. Defaults to FALSE, preserving relative pair magnitudes.
#' @param orthogonalize Whether to remove the component parallel to the mean
#'   original control vector before final normalization. Defaults to FALSE.
#' @param max_bytes Whole materialization budget, 1 MiB through 512 MiB; default
#'   64 MiB. Includes input matrices and metadata, working arrays and output.
#' @return `llm_direction()` returns a `relm_direction` data frame with integer
#'   `neuron`, double `value` and a versioned `direction` metadata attribute.
#'   No model pointer, input matrix or trace is retained.
#' @details
#' Context records a model checksum, architecture, quantization, hidden width,
#' layer count and patched engine revision. Capture is full residual space at
#' the last prompt position, raw text, embedded tokenizer, `add_special = TRUE`,
#' `parse_special = FALSE`, no external template, plus resolved backend, context
#' length and package version. Pairs record ordered IDs, exact UTF-8 prompt
#' checksums and source positions. The split manifest declares disjoint,
#' nonempty construction, selection and evaluation sets before fitting.
#'
#' At most 4096 pairs, 65536 coordinates, 16384 split rows and 8 MiB of context
#' are admitted. Computation is row-wise; a whole difference matrix is never
#' materialized. Zero, nearly cancelled or nonfinite directions are errors, not
#' silently dropped observations. Norm guards use `64 * .Machine$double.eps`.
#'
#' Trusted `saveRDS()` and `readRDS()` preserve the artifact. Application and
#' printing validate schema, unit values, coordinates and canonical checksums.
#' Checksums use one bounded temporary file at a time, removed even on error.
#' They detect modification but do not authenticate recorded provenance or
#' already-loaded weights. Caller deserialization and native model/context
#' memory are outside this budget. Never read untrusted RDS files.
#' @seealso [llm_trace()], [llm_steer()], [llm_apply_direction()],
#'   [llm_compare()], [llm_timeline()]
#' @export
llm_direction <- function(target, control, context, layer,
                          normalize_pairs = FALSE, orthogonalize = FALSE,
                          max_bytes = 64 * 1024^2) {
  budget <- direction_budget(max_bytes)
  dims <- direction_matrix_shape(target, "target")
  if (!identical(dims, direction_matrix_shape(control, "control")) ||
      !identical(dimnames(target), dimnames(control))) {
    abort_argument("target/control", "Both matrices must have identical dimensions and exact coordinate order.")
  }
  input_bytes <- sum(vapply(list(target, control, context), function(x) as.double(utils::object.size(x)), numeric(1)))
  context_bytes <- as.double(utils::object.size(context))
  estimate <- direction_estimate(input_bytes, context_bytes, dims[1L], dims[2L])
  direction_admit(estimate, budget)
  direction_matrix_names(target, "target")
  context <- direction_context(context, rownames(target), dims[2L])
  if (!direction_number(layer, 2L, context$model$layers)) abort_argument("layer", "Use one whole supported layer, from 2 through the recorded layer count.")
  for (arg in c("normalize_pairs", "orthogonalize")) {
    value <- get(arg)
    if (!is.logical(value) || !is.null(attributes(value)) || length(value) != 1L || is.na(value)) {
      abort_argument(arg, "Use one nonmissing logical value.")
    }
  }
  fitted <- direction_arithmetic(target, control, normalize_pairs, orthogonalize, estimate, context)
  n <- dims[1L]; h <- dims[2L]
  limit <- 2^20 + 4 * context_bytes + 64 * (n + h)
  matrix_limit <- 8 * as.double(n) * h + 2^20 + 136 * n + 16 * h
  meta <- list(schema = "relm_direction/1", layer = as.integer(layer), component = "residual",
    context = context,
    method = list(algorithm = "paired_difference_mean/1", normalize_pairs = normalize_pairs, orthogonalize = orthogonalize),
    diagnostics = fitted$diagnostics,
    producer = list(relm_version = as.character(utils::packageVersion("relm")), r_version = as.character(getRversion())),
    digests = list(target = direction_hash("matrix", target, matrix_limit),
      control = direction_hash("matrix", control, matrix_limit),
      pairs = direction_hash("pairs", context$pairs, limit),
      splits = direction_hash("splits", context$splits, limit),
      values = direction_hash("values", list(neuron = seq_len(h), value = fitted$value), limit)))
  result <- structure(list(neuron = seq_len(h), value = fitted$value),
    row.names = .set_row_names(h), class = c("relm_direction", "data.frame"), direction = meta)
  meta$digests$payload <- direction_hash("artifact", direction_payload(result), limit)
  attr(result, "direction") <- meta
  direction_stage(estimate, target, control, context, fitted, meta, result, double(8L * h), raw(4096L))
  result
}

#' Apply a compatible recorded direction
#'
#' Validate a trusted direction artifact, then derive an additive steering
#' handle using the existing native capability checks.
#' @inheritParams llm_direction
#' @param m A live `llm` handle. Its metadata is checked for compatibility, not
#'   treated as authenticated weight identity.
#' @param direction A `relm_direction` returned by [llm_direction()].
#' @param coef One finite coefficient. Zero and negative coefficients retain
#'   the existing [llm_steer()] semantics.
#' @return A new `llm` handle; `m` is unchanged. Close the derived handle when done.
#' @details The independently recorded destination context must match all six
#'   fields of the construction model record exactly. Verify the model file and
#'   keep it unchanged while loading and experimenting. Same path or width alone
#'   is insufficient. This check cannot authenticate already-loaded weights.
#'   Steering is additive residual editing at all positions, not runtime
#'   projection. Extracting `direction$value` and calling [llm_steer()] directly
#'   deliberately bypasses artifact checks. Native busy/closed errors propagate.
#' @export
llm_apply_direction <- function(m, direction, context, coef = 1,
                                max_bytes = 64 * 1024^2) {
  budget <- direction_budget(max_bytes)
  if (!inherits(m, "llm")) abort_argument("m", "Use an llm handle returned by llm().")
  extra <- 4 * as.double(utils::object.size(context))
  direction_admit(extra + as.double(utils::object.size(direction)) + 2^20, budget)
  context <- direction_model(context)
  validated <- direction_validate(direction, budget, extra_bytes = extra)
  record <- validated$metadata$context$model
  if (!identical(context, record) || !identical(m$architecture, record$architecture) ||
      !identical(m$quantization, record$quantization) ||
      !direction_number(m$hidden_size, record$hidden_size, record$hidden_size) ||
      !direction_number(m$layers, record$layers, record$layers)) {
    direction_fail("direction_incompatible", "The independently recorded destination model and handle metadata must match the direction's model record.")
  }
  llm_steer(m, layer = validated$metadata$layer, direction = validated$artifact$value,
    coef = coef, positions = "all")
}

#' @rdname llm_direction
#' @param x A trusted `relm_direction` artifact.
#' @param ... Must be empty.
#' @export
print.relm_direction <- function(x, ...) {
  if (length(list(...))) abort_argument("...", "No additional print arguments are supported.")
  valid <- direction_validate(x); meta <- valid$metadata
  cat(sprintf("<relm_direction> layer %d, %d residual coordinates, %d pairs\n", meta$layer, nrow(x), nrow(meta$context$pairs)))
  cat(sprintf("  pair normalization: %s; control orthogonalization: %s\n", meta$method$normalize_pairs, meta$method$orthogonalize))
  cat(sprintf("  recorded model: %s / %s\n", meta$context$model$architecture, meta$context$model$quantization))
  cat(sprintf("  recorded SHA-256: %s\n", meta$context$model$sha256))
  cat("  Provenance is recorded, not authenticated; positive sign is target minus control.\n")
  invisible(x)
}
