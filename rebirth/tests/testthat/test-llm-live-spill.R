# F6a Arrow conversion/identity gates: every R CMD check CI leg, model-free.
# Real nanoarrow arrays/IPC files exercise lengths and allocated child buffers.
# These checks do not claim a bound on arbitrary IPC decoding or process RSS.

live_spill_test_schema <- function(metadata) {
  nanoarrow::nanoarrow_schema_modify(nanoarrow::na_struct(list(
    prompt_id = nanoarrow::na_int32(), token_pos = nanoarrow::na_int32(),
    token = nanoarrow::na_string(), layer = nanoarrow::na_int32(),
    component = nanoarrow::na_string(), neuron = nanoarrow::na_int32(),
    value = nanoarrow::na_double())), list(metadata = metadata))
}

live_spill_test_metadata <- function() {
  list("relm.spill_format" = "1", "relm.trace_id" = "live-fixture-nonce",
    "relm.model" = "/fixture.gguf", "relm.spec" = "live-fixture-spec",
    "relm.position_space" = "model_context", "relm.prompt_token_count" = "3",
    "relm.state_id" = "1", "relm.source_pos" = "3", "relm.live_batch_rows" = "4096",
    "relm.live_batch_bytes" = "2048")
}

live_spill_test_proxy <- function(path) {
  x <- relm:::live_empty_trace(stub_llm(), "abc")
  attr(x, "spilled") <- TRUE
  attr(x, "spill_files") <- path
  attr(x, "spill_trace_id") <- "live-fixture-nonce"
  attr(x, "spill_spec") <- "live-fixture-spec"
  attr(x, "prompt_token_count") <- 3L
  attr(x, "state_id") <- 1L
  attr(x, "live_source_pos") <- 3L
  attr(x, "live_batch_rows") <- 4096L
  attr(x, "live_batch_bytes") <- 2048
  x
}

live_spill_test_write <- function(path, metadata) {
  df <- data.frame(prompt_id = 0L, token_pos = 2L, token = "c", layer = 0L,
    component = "residual", neuron = 0L, value = 0.25, stringsAsFactors = FALSE)
  nanoarrow::write_nanoarrow(nanoarrow::as_nanoarrow_array(df,
    schema = live_spill_test_schema(metadata)), path)
}

test_that("live Arrow batches enforce exact row and child-buffer byte boundaries", {
  batch <- nanoarrow::as_nanoarrow_array(data.frame(value = rep.int(1L, 4096L)))
  expect_equal(batch$length, 4096)
  # Primitive int32 data is precisely 4 bytes per element. Root buffers are
  # empty here, so a guard forgetting child buffers would accept the bad case.
  expect_equal(batch$children[[1L]]$buffers[[2L]]$size_bytes, 4096 * 4)
  proxy <- structure(list(), live_batch_bytes = 4096 * 4)
  expect_true(relm:::live_check_arrow_batch(batch, proxy))
  attr(proxy, "live_batch_bytes") <- 4096 * 4 - 1
  expect_error(relm:::live_check_arrow_batch(batch, proxy), class = "relm_error_trace")
  too_many <- nanoarrow::as_nanoarrow_array(data.frame(value = rep.int(1L, 4097L)))
  attr(proxy, "live_batch_bytes") <- 1024^2
  expect_error(relm:::live_check_arrow_batch(too_many, proxy), class = "relm_error_trace")
  # The row count alone cannot bound a one-row variable-width string buffer.
  wide <- nanoarrow::as_nanoarrow_array(data.frame(token = strrep("x", 65536L)))
  attr(proxy, "live_batch_bytes") <- 4096
  expect_error(relm:::live_check_arrow_batch(wide, proxy), class = "relm_error_trace")
  for (bound in list(NULL, 0, -1, Inf, NaN, c(1, 2))) {
    attr(proxy, "live_batch_bytes") <- bound
    expect_error(relm:::live_check_arrow_batch(batch, proxy), class = "relm_error_trace")
  }
})

test_that("live spill metadata binds every coordinate and batch bound", {
  path <- tempfile(fileext = ".arrow")
  on.exit(unlink(path), add = TRUE)
  metadata <- live_spill_test_metadata()
  live_spill_test_write(path, metadata)
  proxy <- live_spill_test_proxy(path)
  expect_true(relm:::verify_spill_integrity(proxy, path))
  slice <- relm:::read_spill_slice(proxy, 1L, "residual")
  expect_identical(slice$token_pos, 3L)
  expect_identical(slice$neuron, 1L)
  expect_identical(slice$value, 0.25)
  for (attribute in c("prompt_token_count", "state_id", "live_source_pos",
    "live_batch_rows", "live_batch_bytes", "position_space", "spill_trace_id")) {
    stale <- proxy
    old <- attr(stale, attribute)
    attr(stale, attribute) <- if (is.numeric(old)) old + 1 else "stale"
    expect_error(relm:::verify_spill_integrity(stale, path), class = "relm_error_trace")
  }
  # An ordinary prompt proxy cannot validate the same file accidentally.
  ordinary <- proxy
  attr(ordinary, "position_space") <- NULL
  expect_error(relm:::verify_spill_integrity(ordinary, path), class = "relm_error_trace")
  # Matching trace nonce/spec alone is insufficient if live metadata is absent.
  for (key in c("relm.position_space", "relm.prompt_token_count", "relm.state_id",
    "relm.source_pos", "relm.live_batch_rows", "relm.live_batch_bytes")) {
    missing <- metadata
    missing[[key]] <- NULL
    live_spill_test_write(path, missing)
    expect_error(relm:::verify_spill_integrity(proxy, path), class = "relm_error_trace")
  }
})

test_that("oversized live record is rejected before data-frame materialization", {
  path <- tempfile(fileext = ".arrow")
  on.exit(unlink(path), add = TRUE)
  metadata <- live_spill_test_metadata()
  metadata[["relm.live_batch_bytes"]] <- "1"
  live_spill_test_write(path, metadata)
  proxy <- live_spill_test_proxy(path)
  attr(proxy, "live_batch_bytes") <- 1
  # Metadata matches: only the actual record-byte bound can reject this input.
  expect_true(relm:::verify_spill_integrity(proxy, path))
  converted <- FALSE
  # Give a local copy of the actual reader an injected conversion dependency;
  # do not rely on S3 registration tables following a namespace-method mock.
  reader <- relm:::read_spill_slice
  guard <- new.env(parent = environment(reader))
  guard$as.data.frame <- function(...) {
    converted <<- TRUE
    stop("oversized live record reached R materialization")
  }
  environment(reader) <- guard
  expect_error(reader(proxy, 1L, "residual"), class = "relm_error_trace")
  expect_false(converted)
})
