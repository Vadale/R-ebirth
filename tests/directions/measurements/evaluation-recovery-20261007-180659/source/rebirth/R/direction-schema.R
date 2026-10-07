# D-045: bounded recorded provenance. These checks do not authenticate weights.
direction_fail <- function(reason, message, ...) {
  relm_abort("relm_error_intervention", message, c(list(reason = reason), list(...)))
}

direction_number <- function(x, lower = 0, upper = .Machine$integer.max,
                             whole = TRUE) {
  is.numeric(x) && is.null(attributes(x)) && length(x) == 1L &&
    !is.na(x) && is.finite(x) && x >= lower && x <= upper &&
    (!whole || x == floor(x))
}

direction_text <- function(x, limit = 256L) {
  is.character(x) && is.null(attributes(x)) && length(x) == 1L && !is.na(x) &&
    nzchar(x) && Encoding(x) != "bytes" && validUTF8(x) &&
    nchar(x, type = "bytes") <= limit
}

direction_digest <- function(x) {
  direction_text(x, 64L) && grepl("^[0-9a-f]{64}$", x)
}

direction_record <- function(x, fields, argument = "context") {
  if (!is.list(x) || is.object(x) || !identical(names(attributes(x)), "names") ||
      length(x) != length(fields) || anyDuplicated(names(x)) ||
      !setequal(names(x), fields)) {
    abort_argument(argument, paste("Supply exactly these named fields:",
                                  paste(fields, collapse = ", ")))
  }
  x[fields]
}

direction_row_names <- function(x) {
  rows <- attr(x, "row.names", exact = TRUE)
  (is.integer(rows) || is.character(rows)) && is.null(attributes(rows)) &&
    length(rows) == .row_names_info(x, 2L) && !anyNA(rows) && !anyDuplicated(rows)
}

direction_frame <- function(x, fields, types, lower, upper, argument = "context") {
  if (!identical(class(x), "data.frame") ||
      !setequal(names(attributes(x)), c("names", "class", "row.names")) ||
      length(x) != length(fields) || anyDuplicated(names(x)) ||
      !setequal(names(x), fields) ||
      !direction_number(.row_names_info(x, 2L), lower, upper) || !direction_row_names(x)) {
    abort_argument(argument, "Supply a plain, bounded data frame with the documented columns.")
  }
  x <- x[fields]
  n <- .row_names_info(x, 2L)
  attr(x, "row.names") <- .set_row_names(n)
  for (j in seq_along(fields)) {
    if (!identical(typeof(x[[j]]), types[j]) ||
        !is.null(attributes(x[[j]])) || length(x[[j]]) != n) {
      abort_argument(argument, "Data-frame columns must have the documented plain types and equal lengths.")
    }
  }
  x
}

direction_budget <- function(x) {
  if (!direction_number(x, 2^20, 512 * 2^20)) {
    abort_argument("max_bytes", "Use whole max_bytes from 1 MiB through 512 MiB.")
  }
  as.double(x)
}

direction_estimate <- function(input_bytes, context_bytes, n, h) {
  input_bytes + 4 * context_bytes + 2^20 + 8 * (40 * h + 16 * n) + 4 * (n + h)
}

direction_admit <- function(estimate, budget) {
  if (!is.finite(estimate) || estimate > budget) {
    relm_abort("relm_error_oom", "Direction inputs and working copies exceed max_bytes. Use fewer pairs or a larger explicit budget.",
      list(reason = "direction_materialization", estimate_bytes = estimate,
           budget_bytes = budget))
  }
  invisible(estimate)
}

direction_stage <- function(estimate, ...) {
  actual <- sum(vapply(list(...), function(x) as.double(utils::object.size(x)), numeric(1)))
  if (actual > estimate) {
    relm_abort("relm_error_internal", "Direction workspace exceeded its admitted ledger; report this invariant failure.",
      list(reason = "direction_allocation", actual_bytes = actual, estimate_bytes = estimate))
  }
  invisible(actual)
}

direction_model <- function(x) {
  x <- direction_record(x, c("sha256", "architecture", "quantization", "hidden_size", "layers", "engine_revision"))
  if (!direction_digest(x$sha256) || !direction_text(x$architecture) ||
      !direction_text(x$quantization) || !direction_text(x$engine_revision) ||
      !direction_number(x$hidden_size, 1L, 65536L) || !direction_number(x$layers, 2L)) {
    abort_argument("context", "Provide a checksum, build, architecture, quantization and valid complete model geometry.")
  }
  x$hidden_size <- as.integer(x$hidden_size)
  x$layers <- as.integer(x$layers)
  x
}

direction_context <- function(x, pair_ids = NULL, h = NULL) {
  x <- direction_record(x, c("model", "capture", "pairs", "splits", "seed"))
  bytes <- as.double(utils::object.size(x))
  if (bytes > 8 * 2^20) {
    relm_abort("relm_error_oom", "Direction context exceeds its 8 MiB bound. Reduce the manifest.",
      list(reason = "direction_context", actual_bytes = bytes, budget_bytes = 8 * 2^20))
  }
  x$model <- direction_model(x$model)
  if (!is.null(h) && x$model$hidden_size != h) {
    abort_argument("context", "The recorded hidden width must equal the complete matrix width.")
  }
  cpt <- direction_record(x$capture, c("component", "positions", "input_format", "tokenizer",
    "add_special", "parse_special", "template_sha256", "context_length", "backend", "relm_version"))
  fixed <- list(component = "residual", positions = "last", input_format = "raw_text",
    tokenizer = "gguf_embedded", add_special = TRUE, parse_special = FALSE, template_sha256 = NULL)
  if (!identical(cpt[names(fixed)], fixed) ||
      !direction_number(cpt$context_length, 1L) || !direction_text(cpt$backend) ||
      !cpt$backend %in% c("cpu", "metal", "cuda") || !direction_text(cpt$relm_version)) {
    abort_argument("context", "Use the documented raw-text, last-position residual capture profile and explicit resolved backend.")
  }
  cpt$context_length <- as.integer(cpt$context_length)
  x$capture <- cpt
  p <- direction_frame(x$pairs, c("pair_id", "target_sha256", "control_sha256", "target_pos", "control_pos"),
    c("character", "character", "character", "integer", "integer"), 2L, 4096L)
  for (i in seq_len(nrow(p))) {
    if (!direction_text(p$pair_id[i], 128L) ||
        !direction_digest(p$target_sha256[i]) || !direction_digest(p$control_sha256[i]) ||
        !direction_number(p$target_pos[i], 1L, cpt$context_length) ||
        !direction_number(p$control_pos[i], 1L, cpt$context_length)) {
      abort_argument("context", "Each construction pair needs a bounded ID, prompt checksums and actual source positions.")
    }
  }
  if (anyDuplicated(p$pair_id) || (!is.null(pair_ids) && !identical(p$pair_id, pair_ids))) {
    abort_argument("context", "Construction pair IDs must be unique and match the matrix row order exactly.")
  }
  s <- direction_frame(x$splits, c("prompt_sha256", "split"), c("character", "character"), 3L, 16384L)
  for (i in seq_len(nrow(s))) {
    if (!direction_digest(s$prompt_sha256[i]) || !direction_text(s$split[i]) ||
        !s$split[i] %in% c("construction", "selection", "evaluation")) {
      abort_argument("context", "Split rows require a prompt checksum and construction, selection or evaluation label.")
    }
  }
  if (anyDuplicated(s$prompt_sha256) ||
      !setequal(s$split, c("construction", "selection", "evaluation")) ||
      !setequal(s$prompt_sha256[s$split == "construction"], c(p$target_sha256, p$control_sha256))) {
    abort_argument("context", "Declare disjoint, nonempty splits with exactly the construction prompt checksums used by the pairs.")
  }
  if (!is.null(x$seed)) {
    if (!direction_number(x$seed)) abort_argument("context", "Construction seed must be NULL or a nonnegative integer.")
    x$seed <- as.integer(x$seed)
  }
  x$pairs <- p; x$splits <- s
  x
}

direction_matrix_shape <- function(x, argument) {
  dims <- dim(x)
  if (!is.matrix(x) || typeof(x) != "double" || is.object(x) ||
      !setequal(names(attributes(x)), c("dim", "dimnames")) ||
      !direction_number(dims[1L], 2L, 4096L) ||
      !direction_number(dims[2L], 1L, 65536L) || length(dimnames(x)) != 2L ||
      !is.character(rownames(x)) || !is.character(colnames(x))) {
    abort_argument(argument, "Supply a plain double matrix with 2..4096 named pairs and 1..65536 full-width neurons.")
  }
  dims
}

direction_matrix_names <- function(x, argument) {
  for (id in rownames(x)) {
    if (!direction_text(id, 128L)) abort_argument(argument, "Pair IDs must be nonempty UTF-8 strings of at most 128 bytes.")
  }
  if (anyDuplicated(rownames(x)) || !identical(colnames(x), as.character(seq_len(ncol(x))))) {
    abort_argument(argument, "Use unique pair IDs and complete, ordered neuron names 1 through hidden width.")
  }
  invisible(NULL)
}
