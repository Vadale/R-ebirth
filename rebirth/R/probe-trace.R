# Probe reads need stricter observation identity checks and a fitting-workspace
# budget; the ordinary as.matrix(trace) contract does not provide either.
probe_memory_estimate <- function(n, p, n_layers, cv = 10, input_bytes = 0,
                                  read_bytes = 0) {
  # Doubles: 16 dense working copies covers slice/order/standardization/solver
  # work; paths cover 41 lambdas; output grows with layers, not CV fitted paths.
  # Include resident input and the current Arrow batch separately. The fixed
  # allowance covers small R objects and the 2,000 bootstrap scalar results.
  input_bytes + read_bytes + 2^20 + 8 * (
    16 * n * p + 8 * (n + p) * 41 + 10 * p * n_layers +
      8 * n * n_layers + 16 * n + 32 * 2000 + 32 * cv * 41 * n_layers
  )
}

probe_check_memory <- function(n, p, n_layers, cv = 10, input_bytes = 0,
                               read_bytes = 0) {
  estimate <- probe_memory_estimate(n, p, n_layers, cv, input_bytes, read_bytes)
  budget <- trace_budget()
  if (!is.finite(estimate) || estimate > budget) {
    relm_abort("relm_error_oom", sprintf(
      "Probe work needs an estimated %s, above the %s trace budget. Capture fewer prompts or fit fewer layers; spilling does not make the solver out of core.",
      format_bytes(estimate), format_bytes(budget)
    ), list(estimate_bytes = estimate, budget_bytes = budget))
  }
  invisible(estimate)
}

probe_spill_slice <- function(data, layer, component, n, p, n_layers, cv, input_bytes) {
  path <- attr(data, "spill_files")
  if (length(path) != 1L || is.na(path) || !file.exists(path)) {
    probe_abort("The trace spill file is missing. Re-run llm_trace().", "spill")
  }
  verify_spill_integrity(data, path)
  stream <- nanoarrow::read_nanoarrow(path, lazy = TRUE)
  parts <- list()
  rows <- 0
  repeat {
    batch <- stream$get_next()
    if (is.null(batch)) break
    raw_bytes <- sum(vapply(batch$children, function(child) {
      sum(vapply(child$buffers, function(buffer) buffer$size_bytes, numeric(1)))
    }, numeric(1)))
    # Check before materializing any batch, including nonmatching layers. String
    # buffers are charged too, rather than assuming every token is short.
    probe_check_memory(n, p, n_layers, cv, input_bytes,
                       raw_bytes * 3 + as.double(batch$length) * 224)
    frame <- as.data.frame(batch)
    take <- frame$layer == layer - 1L & frame$component == component
    if (anyNA(take)) probe_abort("The spill has missing layer/component identities. Re-run llm_trace().", "coordinates")
    if (any(take)) {
      rows <- rows + sum(take)
      if (rows > n * p) probe_abort("The spill has more observations than declared. Re-run llm_trace().", "coordinates")
      part <- frame[take, c("prompt_id", "token_pos", "neuron", "value"), drop = FALSE]
      for (name in c("prompt_id", "token_pos", "neuron")) part[[name]] <- as.double(part[[name]]) + 1
      parts[[length(parts) + 1L]] <- part
    }
  }
  if (!length(parts)) probe_abort("The requested layer/component is absent from the spill. Capture it with llm_trace().", "coordinates", layer = layer)
  do.call(rbind, parts)
}

probe_layer_matrix <- function(data, layer, component, n, p, n_layers, cv,
                               input_bytes, expected = NULL) {
  probe_check_memory(n, p, n_layers, cv, input_bytes)
  rows <- tryCatch({
    if (isTRUE(attr(data, "spilled"))) {
      probe_spill_slice(data, layer, component, n, p, n_layers, cv, input_bytes)
    } else {
      take <- data$layer == layer & data$component == component
      if (anyNA(take)) probe_abort("The trace has missing layer/component identities. Re-run llm_trace().", "coordinates")
      data.frame(prompt_id = data$prompt_id[take], token_pos = data$token_pos[take],
                 neuron = data$neuron[take], value = data$value[take])
    }
  }, error = function(e) {
    if (inherits(e, c("relm_error_probe", "relm_error_oom"))) stop(e)
    probe_abort(paste("The activation slice could not be read:", conditionMessage(e),
                      "Re-run llm_trace()."), "trace_read", layer = layer)
  })
  if (!nrow(rows)) probe_abort("The requested layer/component has no activations. Capture it with llm_trace().", "coordinates", layer = layer)
  for (name in c("prompt_id", "token_pos", "neuron")) {
    x <- rows[[name]]
    if (!is.numeric(x) || is.complex(x) || anyNA(x) || any(!is.finite(x)) ||
        any(x < 1 | x != floor(x) | x > .Machine$integer.max)) {
      probe_abort("Trace coordinates must be finite positive integers. Re-run llm_trace().", "coordinates", layer = layer)
    }
  }
  if (!is.numeric(rows$value) || is.complex(rows$value) || any(!is.finite(rows$value))) {
    probe_abort("Activations must be finite numeric values. Re-run llm_trace().", "nonfinite", layer = layer)
  }
  rows <- rows[order(rows$prompt_id, rows$token_pos, rows$neuron), , drop = FALSE]
  pairs <- unique(rows[c("prompt_id", "token_pos")])
  neurons <- sort(unique(rows$neuron))
  if (anyDuplicated(pairs$prompt_id) || anyDuplicated(rows[c("prompt_id", "token_pos", "neuron")]) ||
      nrow(rows) != nrow(pairs) * length(neurons)) {
    probe_abort("A probe needs exactly one position per prompt and one value per neuron. Capture positions = 'last' and remove no coordinate rows.", "coordinates", layer = layer)
  }
  if (nrow(pairs) != n || length(neurons) != p) {
    probe_abort("Captured prompt/neuron counts differ between layers or from spill metadata. Re-run llm_trace().", "alignment", layer = layer)
  }
  layout <- list(ids = as.integer(pairs$prompt_id), positions = as.integer(pairs$token_pos),
                 neurons = as.integer(neurons))
  if (!is.null(expected) && !identical(layout, expected)) {
    probe_abort("Prompt IDs, token positions or neuron coordinates differ between layers. Capture the same observations at every layer.", "alignment", layer = layer)
  }
  # Sorted unique coordinates plus a full cell count guarantee a complete grid,
  # including the duplicate-plus-missing case that preserves total row count.
  out <- matrix(as.double(rows$value), nrow = n, ncol = p, byrow = TRUE,
                dimnames = list(as.character(layout$ids), as.character(layout$neurons)))
  attr(out, "probe_layout") <- layout
  out
}

probe_source <- function(data, layers, component, cv = 10, expected_neurons = NULL) {
  required <- c("prompt_id", "token_pos", "neuron", "value", "layer", "component")
  if (!inherits(data, "relm_trace") || !is.data.frame(data) || !all(required %in% names(data))) {
    probe_abort("`data` must be a relm_trace from llm_trace().", "trace")
  }
  input_bytes <- as.double(utils::object.size(data))
  if (isTRUE(attr(data, "spilled"))) {
    n <- attr(data, "spill_n_positions")
    p <- attr(data, "spill_n_embd")
    if (length(n) != 1L || length(p) != 1L || !is.numeric(n) || !is.numeric(p) ||
        !is.finite(n) || !is.finite(p) || n < 1 || p < 1 || n != floor(n) || p != floor(p)) {
      probe_abort("The spill dimension metadata is invalid. Re-run llm_trace().", "spill")
    }
    if (n != length(attr(data, "prompts"))) {
      probe_abort("Probes require one captured position per prompt. Re-run llm_trace(positions = 'last').", "coordinates")
    }
  } else {
    # Bound the metadata/filter work before allocating a slice. Feature storage
    # is already resident and included in the fitting budget.
    probe_check_memory(1, 1, length(layers), cv, input_bytes, 32 * as.double(nrow(data)))
    take <- data$layer == layers[1L] & data$component == component
    if (anyNA(take)) probe_abort("Trace layer/component identities are missing. Re-run llm_trace().", "coordinates")
    n <- length(unique(data$prompt_id[take]))
    p <- length(unique(data$neuron[take]))
    if (!n || !p) probe_abort("The requested layer/component is absent. Capture it with llm_trace().", "coordinates")
  }
  estimate <- probe_check_memory(n, p, length(layers), cv, input_bytes)
  cached <- probe_layer_matrix(data, layers[1L], component, n, p, length(layers), cv, input_bytes)
  layout <- attr(cached, "probe_layout")
  attr(cached, "probe_layout") <- NULL
  if (!is.null(expected_neurons) && !identical(as.character(layout$neurons), expected_neurons)) {
    probe_abort("Prediction neuron coordinates differ from the fitted probe. Use the same capture component and neurons.", "alignment")
  }
  read <- function(layer) {
    if (identical(as.integer(layer), as.integer(layers[1L])) && !is.null(cached)) {
      out <- cached
      cached <<- NULL
    } else {
      out <- probe_layer_matrix(data, layer, component, n, p, length(layers), cv, input_bytes, layout)
      attr(out, "probe_layout") <- NULL
    }
    out
  }
  list(read = read, ids = layout$ids, positions = layout$positions,
       neurons = as.character(layout$neurons), estimate_bytes = estimate)
}
