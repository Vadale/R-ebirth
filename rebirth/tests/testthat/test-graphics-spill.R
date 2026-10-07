# Real Arrow IPC files, ordinary R CI, no model. 0-based disk versus 1-based R.
graphics_spill_fixture <- function(state, path, corrupt = FALSE) {
  tr <- state$trace
  df <- as.data.frame(tr); attributes(df) <- list(names = names(df), row.names = .set_row_names(nrow(df)), class = "data.frame")
  for (nm in c("prompt_id", "token_pos", "layer", "neuron")) df[[nm]] <- df[[nm]] - 1L
  metadata <- list("relm.spill_format" = "1", "relm.trace_id" = "graphics-test-nonce",
    "relm.spec" = "graphics-test-spec", "relm.position_space" = "model_context",
    "relm.prompt_token_count" = "3", "relm.state_id" = "1", "relm.source_pos" = "3",
    "relm.live_batch_rows" = "4096", "relm.live_batch_bytes" = "4096")
  if (corrupt) metadata$relm.trace_id <- "wrong-nonce"
  schema <- nanoarrow::nanoarrow_schema_modify(nanoarrow::na_struct(list(prompt_id = nanoarrow::na_int32(), token_pos = nanoarrow::na_int32(), token = nanoarrow::na_string(), layer = nanoarrow::na_int32(), component = nanoarrow::na_string(), neuron = nanoarrow::na_int32(), value = nanoarrow::na_double())), list(metadata = metadata))
  nanoarrow::write_nanoarrow(nanoarrow::as_nanoarrow_array(df, schema = schema), path)
  tr <- tr[FALSE, ]; attr(tr, "spilled") <- TRUE; attr(tr, "spill_files") <- path
  attr(tr, "spill_trace_id") <- "graphics-test-nonce"; attr(tr, "spill_spec") <- "graphics-test-spec"
  attr(tr, "spill_layers") <- 2L; attr(tr, "spill_components") <- "residual"
  attr(tr, "spill_n_embd") <- 4L; attr(tr, "spill_n_positions") <- 1
  attr(tr, "live_source_pos") <- 3L; attr(tr, "live_batch_rows") <- 4096L
  attr(tr, "live_batch_bytes") <- 4096
  state$trace <- tr
  state
}

test_that("selected spilled and in-memory observed values agree exactly", {
  file <- tempfile(fileext = ".arrow"); on.exit(unlink(file))
  a <- graphics_state_fixture(); b <- graphics_spill_fixture(a, file)
  x <- llm_compare(a, b, graphics_context_fixture(), 2, neurons = c(1, 4))
  expect_identical(x$reference, x$intervention)
  expect_identical(x$difference, c(0, 0))
  expect_true(isTRUE(attr(b$trace, "spilled")))
  expect_equal(nrow(b$trace), 0L)
  expect_error(llm_compare(a, b, graphics_context_fixture(), 2, max_bytes = 1024^2), class = "relm_error_oom")
})

test_that("mismatched and missing spill files remain classed failures", {
  file <- tempfile(fileext = ".arrow"); on.exit(unlink(file))
  a <- graphics_state_fixture(); b <- graphics_spill_fixture(a, file, corrupt = TRUE)
  expect_error(llm_compare(a, b, graphics_context_fixture(), 2), class = "relm_error_trace")
  unlink(file)
  expect_error(llm_compare(a, b, graphics_context_fixture(), 2), class = "relm_error_trace")
})

test_that("live spill preparation supplies the managed lease filename prefix", {
  # The compiled lease accepts trace-*.arrow, including live writer suffixes.
  # Capture the actual R request before native estimation, without a model.
  configs <- list()
  local_mocked_bindings(spill_session_dir = function() tempdir(),
    rebirth_live_preflight = function(ptr, config, max_tokens) {
      configs[[length(configs) + 1L]] <<- config
      stop("captured before preflight", call. = FALSE)
    }, .package = "relm")
  live <- list(spill = TRUE, spill_dir = NULL, layers = 2L,
    components = "residual", top = 0L, budget_bytes = 64 * 1024)
  for (custom in c(FALSE, TRUE)) {
    live$spill_dir <- if (custom) tempdir() else NULL
    expect_error(relm:::live_prepare(live, stub_llm(), "x", 2L), "captured before preflight", fixed = TRUE)
  }
  for (config in configs) {
    expect_match(paste0(config$trace_id, "-1.arrow"), "^trace-[0-9A-Za-z-]+-1[.]arrow$")
    expect_gt(config$r_fixed_bytes, 0)
  }
  expect_false(identical(configs[[1]]$trace_id, configs[[2]]$trace_id))
})
