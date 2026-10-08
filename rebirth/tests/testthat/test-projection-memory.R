test_that("projection R profile rejects hidden owners and incompatible compiled fields", {
  p <- projection_test_profile()
  expect_identical(relm:::projection_profile_validate(p), p)
  for (kind in c("extra", "duplicate", "list_attribute", "value_attribute", "class", "version",
                 "sites", "width", "proof", "callback", "ffi", "metadata", "fraction", "inexact")) {
    x <- p
    if (kind == "extra") x$extra <- 0
    if (kind == "duplicate") names(x)[2] <- names(x)[1]
    if (kind == "list_attribute") attr(x, "owner") <- raw(10)
    if (kind == "value_attribute") names(x$runtime_bytes) <- "owner"
    if (kind == "class") class(x) <- "record"
    if (kind == "version") x$version <- 1
    if (kind == "sites") x$max_sites <- 33
    if (kind == "width") x$max_width <- 65537
    if (kind == "proof") x$runtime_bytes <- 32 * x$proof_bytes - 1
    if (kind == "callback") x$callback_frame_bytes <- 1
    if (kind == "ffi") x$ffi_fixed_bytes <- 1
    if (kind == "metadata") x$metadata_owner_bytes <- 1
    if (kind == "fraction") x$site_bytes <- 1.5
    if (kind == "inexact") x$runtime_bytes <- 2^53
    expect_error(relm:::projection_profile_validate(x), class = "relm_error_intervention", info = kind)
  }
})

test_that("projection R arithmetic shares inherited directions and enforces exact budgets", {
  p <- projection_test_profile()
  for (mode in 0:1) for (old in c(0, 1, 31)) for (h in c(1, 3, 32, 65536)) {
    i <- projection_test_inputs(as.double(mode), h, old)
    e <- relm:::projection_memory_bound(p, i)
    expect_identical(names(e), relm:::projection_term_fields)
    expect_identical(e$direction_bytes, (old + mode) * (8 * h + p$direction_arc_header_bytes))
    if (old + mode > 0) {
      expect_identical(e$r_projection_bytes, 2000 + (old + 2 * mode) *
        (as.double(utils::object.size(double(h))) - as.double(utils::object.size(double()))))
    } else expect_identical(e$r_projection_bytes, 0)
    expect_identical(e$adapter_data_bytes, 12 * h + 48 * h + 4 * h + 16 * h + 8 + 48)
    i$max_bytes <- e$total_bytes
    expect_identical(relm:::projection_memory_bound(p, i), e)
    i$max_bytes <- i$max_bytes - 1
    expect_error(relm:::projection_memory_bound(p, i), class = "relm_error_oom")
  }
  i <- projection_test_inputs(0, 32, 32)
  expect_gt(relm:::projection_memory_bound(p, i)$projection_bytes, 0)
  i$mode <- 1
  expect_error(relm:::projection_memory_bound(p, i), class = "relm_error_intervention")
})

test_that("projection R exact arithmetic rejects overflow before multiplication", {
  expect_identical(relm:::projection_add(2^53 - 2, 1), 2^53 - 1)
  expect_error(relm:::projection_add(2^53 - 1, 1), class = "relm_error_intervention")
  expect_identical(relm:::projection_mul(2^26, 2^26), 2^52)
  expect_error(relm:::projection_mul(2^27, 2^27), class = "relm_error_intervention")
  for (key in c("hidden_size", "layers", "previous_sites", "steer_entries", "ablate_entries",
                "source_baseline_values", "r_projection_fixed_bytes", "r_adapter_bytes")) {
    i <- projection_test_inputs(); i[[key]] <- 2^53 - 1
    expect_error(relm:::projection_memory_bound(projection_test_profile(), i),
      class = "relm_error_intervention", info = key)
  }
})

test_that("projection command validation refuses attributes nonunit and incompatible modes", {
  c <- projection_test_config()
  expect_identical(relm:::projection_config_validate(c, 32, 3), c)
  for (kind in c("names", "mode", "component", "layer", "coefficient", "attributes", "length", "nonfinite", "norm", "budget")) {
    x <- c
    if (kind == "names") names(x)[2] <- "mode"
    if (kind == "mode") x$mode <- "new"
    if (kind == "component") x$component <- "residual"
    if (kind == "layer") x$layer <- 0
    if (kind == "coefficient") x$coef <- Inf
    if (kind == "attributes") attr(x$direction, "extra") <- 1
    if (kind == "length") x$direction <- 1
    if (kind == "nonfinite") x$direction[5] <- NA_real_
    if (kind == "norm") x$direction[1] <- 2
    if (kind == "budget") x$max_bytes <- 512 * 2^20 + 1
    expect_error(relm:::projection_config_validate(x, 32, 3), class = "relm_error_intervention", info = kind)
  }
  c$mode <- "inherit"; c$layer <- 0; c$coef <- 0; c$direction <- double()
  expect_identical(relm:::projection_config_validate(c, 32, 3), c)
  c$component <- "attn_out"
  expect_error(relm:::projection_config_validate(c, 32, 3), class = "relm_error_intervention")
})

test_that("projection responses bind every term and actual model fact before derivation", {
  p <- projection_test_profile(); i <- projection_test_inputs(); c <- projection_test_config()
  r <- list(ok = TRUE, armed = FALSE, profile = p, inputs = i,
    terms = relm:::projection_memory_bound(p, i))
  check <- function(x) relm:::projection_response_validate(x, c, 32, 3, 0, 0, p)
  expect_identical(check(r), r$terms)
  for (name in relm:::projection_term_fields) {
    bad <- r; bad$terms[[name]] <- bad$terms[[name]] + 1
    expect_error(check(bad), class = "relm_error_intervention", info = name)
  }
  for (name in setdiff(relm:::projection_input_fields, "source_baseline_values")) {
    bad <- r; bad$inputs[[name]] <- bad$inputs[[name]] + 1
    expect_error(check(bad), class = "relm_error_intervention", info = name)
  }
  bad <- r; bad$armed <- TRUE
  expect_error(check(bad), class = "relm_error_intervention")
  bad <- r; bad$profile$ffi_registry_bytes <- bad$profile$ffi_registry_bytes + 8
  expect_error(check(bad), class = "relm_error_intervention")
})

test_that("projection R transport accounts actual pool sizes and untraversed pointer tags", {
  p <- projection_test_profile()
  expect_length(relm:::projection_r_fingerprint(), 11)
  fixed <- relm:::projection_transport_bytes(p)
  expect_identical(fixed$total, sum(unlist(fixed[names(fixed) != "total"])))
  expect_identical(fixed$tags, 2 * as.double(utils::object.size(list(NULL))) +
    as.double(utils::object.size(strrep("x", p$ffi_handle_tag_bytes))) -
    as.double(utils::object.size(list(NULL))))
  wider <- p; wider$ffi_handle_tag_bytes <- 129
  expect_gt(relm:::projection_transport_bytes(wider)$tags, fixed$tags)
})

test_that("projection transport covers OOM fields and the bounded intervention alternative", {
  oom <- list(ok = FALSE, class = "relm_error_oom",
    message = "Projection owners and working copies exceed max_bytes. Reduce projection sites or increase max_bytes.",
    fields = list(estimate_bytes = 1520411, budget_bytes = 1520410))
  for (width in c(64, 150, 256)) {
    p <- projection_test_profile(); p$error_format_bytes <- width
    intervention <- list(ok = FALSE, class = "relm_error_intervention",
      message = strrep("x", width), fields = list(reason = strrep("x", width)))
    fixed <- relm:::projection_transport_bytes(p)
    expect_gte(fixed$failure, as.double(utils::object.size(oom)))
    expect_gte(fixed$failure, as.double(utils::object.size(intervention)))
    expect_identical(fixed$failure,
      max(as.double(utils::object.size(oom)), as.double(utils::object.size(intervention))))
    expect_identical(fixed$total, sum(unlist(fixed[names(fixed) != "total"])))
  }
})
