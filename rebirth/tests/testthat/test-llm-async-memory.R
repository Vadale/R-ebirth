# WP9 materialized-R memory gate: pure R, every R PR matrix leg, no model/native
# generation. Distinct strings avoid hiding payload bytes behind CHARSXP sharing.

test_that("the R result estimate covers the full UTF-8 output bound and names", {
  output_bytes <- relm:::relm_async_max_output_bytes
  for (n in c(1L, 128L)) {
    bytes_each <- output_bytes / n
    suffix <- sprintf("%08d", seq_len(n))
    result <- paste0(strrep("é", (bytes_each - 8) / 2), suffix)
    attr(result, "seed") <- 17
    expect_identical(length(unique(result)), n)
    expect_equal(sum(nchar(result, type = "bytes")), output_bytes)
    expect_gt(sum(nchar(result, type = "bytes")), sum(nchar(result)))
    expect_lte(as.numeric(object.size(result)),
      relm:::async_result_size_bound(n, output_bytes))
    names(result) <- paste0("prompt-é-", seq_len(n))
    names_bytes <- sum(nchar(names(result), type = "bytes"))
    expect_lte(as.numeric(object.size(result)),
      relm:::async_result_size_bound(n, output_bytes, names_bytes))
  }
  # The largest legal names collection leaves one input byte per prompt within
  # the aggregate 16 MiB input cap. Names also need their own R string storage.
  names_each <- (relm:::relm_async_max_input_bytes - n) / n
  names(result) <- paste0(strrep("é", (names_each - 7) / 2),
    sprintf("%07d", seq_len(n)))
  names_bytes <- sum(nchar(names(result), type = "bytes"))
  expect_equal(names_bytes, relm:::relm_async_max_input_bytes - n)
  expect_lte(as.numeric(object.size(result)),
    relm:::async_result_size_bound(n, output_bytes, names_bytes))
})

test_that("the full buffer accounting separates copies tokens and R materialization", {
  estimate <- relm:::async_transport_peak_bound(context_length = 4096)
  expect_identical(estimate$total_bytes, sum(estimate$components))
  expect_identical(names(estimate$components), c("native_input", "r_input_copies",
    "template_scratch", "prompt_token_buffer", "native_output_text",
    "generated_token_ids", "generation_descriptors", "r_result"))
  expect_equal(estimate$components[["prompt_token_buffer"]], 4 * 4096)
  expect_equal(estimate$components[["generated_token_ids"]], 4 * 128 * 8192)
  expect_gt(estimate$total_bytes, relm:::relm_async_max_output_bytes)
  larger <- relm:::async_transport_peak_bound(context_length = 8192)
  expect_equal(larger$total_bytes - estimate$total_bytes, 4 * (8192 - 4096))
  smaller <- relm:::async_transport_peak_bound(context_length = 4096,
    n = 1, max_tokens = 1, names_bytes = 0)
  expect_lt(smaller$total_bytes, estimate$total_bytes)
})


test_that("prompt admission precedes image-list recycling", {
  local_mocked_bindings(normalize_images = function(...) {
    stop("Image normalization must not run for an oversized async request.")
  }, .package = "relm")
  expect_error(llm_generate(stub_llm(), rep("prompt", 129),
    images = "unused.png", async = TRUE), class = "relm_error_argument")
})
