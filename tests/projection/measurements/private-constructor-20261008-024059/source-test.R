projection_test_profile <- function() {
    p <- setNames(as.list(rep(64, length(projection_profile_fields))), projection_profile_fields)
    p$version <- 2
    p$direction_arc_header_bytes <- 16
    p$runtime_bytes <- 8192
    p$derive_frame_bytes <- 1024
    p$callback_frame_bytes <- 512
    p$ffi_fixed_bytes <- 1024
    p$metadata_owner_bytes <- 0
    p$ffi_handle_tag_bytes <- 24
    p$layout_checksum <- 1234
    p$max_sites <- 32
    p$max_width <- 65536
    p
}
projection_test_inputs <- function(mode = 1, h = 32, old = 0) {
    list(mode = mode, hidden_size = h, layers = 3, previous_sites = old, steer_entries = 2, ablate_entries = 3, source_baseline_values = h * 3, metadata_bytes = 0, metadata_scratch_bytes = 0, existing_direction_estimate = 1000, r_projection_fixed_bytes = 2000, r_adapter_bytes = 3000, max_bytes = 512 * 2^20, backend = 0, production_armed = 0)
}
# New D046 constructor version-2 equations; CI R CMD check, no model needed.
# Compiled native receipts are compared separately by the owner's R-hosted gate.
test_that("projection constructor schema 2 refuses old or missing probe ledgers", {
  p <- projection_test_profile()
  expect_length(p, 27L)
  expect_length(projection_input_fields, 15L)
  expect_length(projection_term_fields, 14L)
  expect_identical(projection_profile_validate(p), p)
  for (kind in c("old_version", "missing", "zero", "fraction", "attributed")) {
    bad <- p
    if (kind == "old_version") bad$version <- 1
    if (kind == "missing") bad$residual_probe_fixed_bytes <- NULL
    if (kind == "zero") bad$residual_probe_fixed_bytes <- 0
    if (kind == "fraction") bad$residual_probe_fixed_bytes <- .5
    if (kind == "attributed") names(bad$residual_probe_fixed_bytes) <- "hidden"
    expect_error(projection_profile_validate(bad), class = "relm_error_intervention")
  }
})

test_that("projection constructor counts one residual sentinel peak for either kind", {
  p <- projection_test_profile()
  # Independent byte arithmetic from two dense 4HD owners and one 4H row.
  for (shape in list(c(1, 1), c(32, 3), c(65536, 3))) {
    h <- shape[[1]]; depth <- shape[[2]]
    for (s in 0:1) for (a in 0:1) {
      input <- projection_test_inputs(h = h)
      input$layers <- depth; input$steer_entries <- as.double(s)
      input$ablate_entries <- as.double(a); input$source_baseline_values <- 0
      got <- projection_memory_bound(p, input)
      wanted <- if (s + a == 0) 0 else
        2 * (h * depth * 4) + h * 4 + p$residual_probe_fixed_bytes
      expect_identical(got$residual_probe_bytes, wanted)
      # No accidental double counting inside projection_bytes.
      expect_identical(got$total_bytes, sum(unlist(got[c("projection_bytes",
        "residual_probe_bytes", "adapter_data_bytes", "adapter_fixed_bytes",
        "metadata_bytes", "r_projection_bytes", "r_adapter_bytes",
        "existing_direction_estimate")], use.names = FALSE)))
      exact <- input; exact$max_bytes <- got$total_bytes
      expect_identical(projection_memory_bound(p, exact), got)
      exact$max_bytes <- exact$max_bytes - 1
      expect_error(projection_memory_bound(p, exact), class = "relm_error_oom")
    }
  }
})

test_that("projection constructor scalar probe charge reaches transport and owner inventory", {
  p <- projection_test_profile()
  base <- projection_transport_bytes(p)
  # Dynamic native registry values change native terms, not R scalar object sizes.
  wider <- p; wider$ffi_registry_bytes <- wider$ffi_registry_bytes + 64
  wider$ffi_fixed_bytes <- wider$ffi_fixed_bytes + 64
  expect_identical(projection_transport_bytes(wider), base)
  i <- projection_test_inputs()
  before <- projection_memory_bound(p, i)
  after <- projection_memory_bound(wider, i)
  expect_identical(after$total_bytes - before$total_bytes, 64)
  expect_identical(after$residual_probe_bytes, before$residual_probe_bytes)
  # The schema enlargement is measured by actual profile/response objects.
  expect_identical(base$profile, as.double(utils::object.size(p)))
})
