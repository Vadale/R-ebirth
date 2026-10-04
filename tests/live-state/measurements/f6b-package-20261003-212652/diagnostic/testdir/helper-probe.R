# WP11b fixtures, per-commit Mac/Linux R matrix; no model load or download.
probe_test_trace <- function(matrices, ids = seq_len(nrow(matrices[[1L]]))) {
  layers <- as.integer(names(matrices))
  parts <- lapply(seq_along(matrices), function(i) {
    x <- matrices[[i]]
    grid <- expand.grid(neuron = seq_len(ncol(x)), row = seq_len(nrow(x)))
    data.frame(prompt_id = as.integer(ids[grid$row]),
               token_pos = as.integer(2L + ids[grid$row] %% 3L), token = "fixture",
               layer = layers[i], component = "residual", neuron = as.integer(grid$neuron),
               value = as.double(x[cbind(grid$row, grid$neuron)]), stringsAsFactors = FALSE)
  })
  structure(do.call(rbind, parts), class = c("relm_trace", "data.frame"),
            model = testthat::test_path("fixtures", "synthetic-llama-2l.gguf"),
            prompts = paste("prompt", ids), spilled = FALSE, spill_files = character())
}

probe_test_data <- function(groups = 36L) {
  y <- rep(c(0, 1), groups)
  source <- rep(sprintf("source-%02d", seq_len(groups)), each = 2L)
  x <- cbind(signal = 2 * y - 1, nuisance = rep(rep(c(-1, 1), length.out = groups), each = 2L), constant = 7)
  list(trace = probe_test_trace(list(`1` = x, `2` = x)), y = y, groups = source,
       heldout = unique(source)[seq.int(13L, groups)])
}

probe_test_fit <- function(data = probe_test_data(), ...) {
  label <- data$y
  llm_probe(label ~ activations(layer = 1:2), data$trace,
            groups = data$groups, test_groups = data$heldout, cv = 3L, seed = 914L, ...)
}

probe_test_spill <- function(trace, path) {
  # Genuine D-013 IPC schema: uint32 coordinates, utf8 text, float32 values.
  # Build unsigned/float buffers directly using nanoarrow; no arrow dependency.
  disk <- as.data.frame(trace)
  index <- c("prompt_id", "token_pos", "layer", "neuron")
  disk[index] <- lapply(disk[index], function(x) x - 1L)
  array <- nanoarrow::as_nanoarrow_array(disk)
  children <- array$children
  for (name in index) nanoarrow::nanoarrow_array_set_schema(children[[name]], nanoarrow::na_uint32())
  children$value <- nanoarrow::nanoarrow_array_modify(
    nanoarrow::nanoarrow_array_init(nanoarrow::na_float()),
    list(length = nrow(disk), null_count = 0L,
         buffers = list(NULL, writeBin(disk$value, raw(), size = 4L, endian = .Platform$endian))))
  model <- list(path = attr(trace, "model"))
  prompts <- attr(trace, "prompts")
  layers <- sort(unique(trace$layer))
  spec <- relm:::trace_spec_key(model, prompts, layers, "last", "residual")
  nonce <- relm:::next_trace_id()
  schema <- nanoarrow::nanoarrow_schema_modify(
    nanoarrow::na_struct(lapply(children, nanoarrow::infer_nanoarrow_schema)),
    list(metadata = list("relm.spill_format" = "1", "relm.trace_id" = nonce,
                         "relm.model" = model$path, "relm.spec" = spec)))
  array <- nanoarrow::nanoarrow_array_modify(array, list(children = children))
  nanoarrow::nanoarrow_array_set_schema(array, schema)
  nanoarrow::write_nanoarrow(array, path)
  relm:::new_spilled_trace(list(spill_path = path, layers = layers,
    positions = sort(unique(trace$token_pos)), components = "residual", n_rows = nrow(trace),
    n_positions = length(unique(trace$prompt_id)), n_embd = length(unique(trace$neuron)),
    trace_id = nonce), model, prompts, spec)
}
