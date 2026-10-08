direction_diagnostics <- function(x, context, method) {
  fields <- c("guard_relative", "pairs", "mean_pair_norm", "control_mean_norm",
    "mean_control_norm", "pre_projection_norm", "post_projection_norm", "final_norm")
  x <- direction_record(x, fields, "direction")
  if (!identical(x$guard_relative, 64 * .Machine$double.eps)) {
    direction_fail("direction_schema", "The direction's numerical guard does not match schema version 1.")
  }
  p <- direction_frame(x$pairs, c("pair_id", "target_norm", "control_norm", "difference_norm", "used_norm"),
    c("character", rep("double", 4L)), 2L, 4096L, "direction")
  if (!identical(p$pair_id, context$pairs$pair_id)) {
    direction_fail("direction_coordinates", "Diagnostic pair order does not match construction provenance.")
  }
  for (field in names(p)[-1L]) {
    if (anyNA(p[[field]]) || any(!is.finite(p[[field]])) || any(p[[field]] < 0)) {
      direction_fail("direction_diagnostics", "Direction norm diagnostics must be finite and nonnegative.")
    }
  }
  if (any(p$difference_norm <= x$guard_relative * pmax(p$target_norm, p$control_norm)) ||
      any(p$difference_norm == 0) ||
      (method$normalize_pairs && any(abs(p$used_norm - 1) > 1e-12)) ||
      (!method$normalize_pairs && !identical(p$used_norm, p$difference_norm))) {
    direction_fail("direction_diagnostics", "The stored pair norms violate construction or normalization guards.")
  }
  for (field in fields[-c(1L, 2L)]) {
    if (!identical(typeof(x[[field]]), "double") ||
        !direction_number(x[[field]], 0, .Machine$double.xmax, FALSE)) {
      direction_fail("direction_diagnostics", "Stored aggregate norms must be finite nonnegative doubles.")
    }
  }
  near <- function(a, b) abs(a - b) <= 1e-12 * (1 + abs(b))
  if (!near(x$mean_pair_norm, sum(p$used_norm / nrow(p))) ||
      !near(x$mean_control_norm, sum(p$control_norm / nrow(p))) ||
      x$pre_projection_norm <= x$guard_relative * x$mean_pair_norm ||
      x$post_projection_norm == 0 || !near(x$final_norm, 1) ||
      (!method$orthogonalize && !identical(x$pre_projection_norm, x$post_projection_norm)) ||
      (method$orthogonalize &&
       (x$control_mean_norm <= x$guard_relative * x$mean_control_norm ||
        x$post_projection_norm <= x$guard_relative * x$pre_projection_norm))) {
    direction_fail("direction_diagnostics", "Aggregate diagnostics are inconsistent with the declared construction method.")
  }
  x$pairs <- p
  x
}

direction_validate <- function(x, max_bytes = 64 * 1024^2, extra_bytes = 0) {
  budget <- direction_budget(max_bytes)
  tryCatch({
    if (!identical(class(x), c("relm_direction", "data.frame")) ||
        !setequal(names(attributes(x)), c("names", "row.names", "class", "direction")) ||
        !identical(names(x), c("neuron", "value")) ||
        !direction_number(.row_names_info(x, 2L), 1L, 65536L) || !direction_row_names(x) ||
        typeof(x$neuron) != "integer" || typeof(x$value) != "double" ||
        !is.null(attributes(x$neuron)) || !is.null(attributes(x$value)) ||
        length(x$neuron) != .row_names_info(x, 2L) || length(x$value) != length(x$neuron)) {
      direction_fail("direction_schema", "Use an unchanged relm_direction data frame with complete coordinates.")
    }
    meta <- direction_record(attr(x, "direction", exact = TRUE),
      c("schema", "layer", "component", "context", "method", "diagnostics", "producer", "digests"), "direction")
    input_bytes <- as.double(utils::object.size(x)) + extra_bytes
    context_bytes <- as.double(utils::object.size(meta$context))
    # Admission precedes expanded validation arrays, canonical copies or hashing.
    direction_admit(input_bytes + 4 * context_bytes + 2^20, budget)
    context <- direction_context(meta$context, h = length(x$value))
    n <- nrow(context$pairs); h <- length(x$value)
    estimate <- direction_estimate(input_bytes, context_bytes, n, h)
    direction_admit(estimate, budget)
    schema <- direction_component_schema(context$capture$component)
    first_layer <- if (context$capture$component == "residual") 2L else 1L
    if (!identical(meta$schema, schema) || !identical(meta$component, context$capture$component) ||
        typeof(meta$layer) != "integer" || !direction_number(meta$layer, first_layer, context$model$layers) ||
        !identical(x$neuron, seq_len(h)) || anyNA(x$value) || any(!is.finite(x$value)) ||
        abs(direction_norm(x$value) - 1) > 1e-12) {
      direction_fail("direction_coordinates", "The artifact's schema, component, layer, full coordinates or unit values are invalid.")
    }
    method <- direction_record(meta$method, c("algorithm", "normalize_pairs", "orthogonalize"), "direction")
    if (!identical(method$algorithm, "paired_difference_mean/1") ||
        !identical(typeof(method$normalize_pairs), "logical") ||
        !identical(typeof(method$orthogonalize), "logical") ||
        !is.null(attributes(method$normalize_pairs)) || !is.null(attributes(method$orthogonalize)) ||
        length(method$normalize_pairs) != 1L || length(method$orthogonalize) != 1L ||
        is.na(method$normalize_pairs) || is.na(method$orthogonalize)) {
      direction_fail("direction_method", "The direction construction method is unsupported or incomplete.")
    }
    diagnostics <- direction_diagnostics(meta$diagnostics, context, method)
    producer <- direction_record(meta$producer, c("relm_version", "r_version"), "direction")
    if (!direction_text(producer$relm_version) || !direction_text(producer$r_version)) {
      direction_fail("direction_producer", "The artifact must record bounded producer version strings.")
    }
    digests <- direction_record(meta$digests, c("target", "control", "pairs", "splits", "values", "payload"), "direction")
    if (!all(vapply(digests, direction_digest, logical(1)))) {
      direction_fail("direction_digest", "The artifact has missing or malformed content checksums.")
    }
    meta$context <- context; meta$method <- method; meta$diagnostics <- diagnostics
    meta$producer <- producer; meta$digests <- digests
    # Canonical field order affects encoding only; caller-owned input is unchanged.
    canonical <- structure(list(neuron = x$neuron, value = x$value),
      names = c("neuron", "value"), row.names = .set_row_names(h),
      class = c("relm_direction", "data.frame"), direction = meta)
    limit <- 2^20 + 4 * context_bytes + 64 * (n + h)
    actual <- c(
      pairs = direction_hash("pairs", context$pairs, limit, schema = schema),
      splits = direction_hash("splits", context$splits, limit, schema = schema),
      values = direction_hash("values", list(neuron = x$neuron, value = x$value), limit, schema = schema),
      payload = direction_hash("artifact", direction_payload(canonical), limit, schema = schema))
    if (!identical(unname(actual), unname(unlist(digests[names(actual)], use.names = FALSE)))) {
      direction_fail("direction_integrity", "Direction data or provenance changed since construction. Reload the original verified artifact.")
    }
    direction_stage(estimate, x, canonical, meta, context, diagnostics, actual, double(h), raw(4096L))
    list(artifact = canonical, metadata = meta, estimate_bytes = estimate)
  }, error = function(e) {
    if (inherits(e, "relm_error_argument")) {
      direction_fail("direction_schema", "The saved direction does not match its documented schema. Recreate it from validated inputs.", parent = e)
    }
    stop(e)
  })
}
