test_that("materialized direction stages fit the admitted independent envelope", {
  f <- direction_test_fixture(n = 64L, h = 4096L)
  input <- sum(vapply(f, function(x) as.double(utils::object.size(x)), numeric(1)))
  metadata <- as.double(utils::object.size(f$context))
  envelope <- input + 4 * metadata + 1048576 + 8 * (40 * 4096 + 16 * 64) + 4 * (64 + 4096)
  stages <- numeric(); original <- relm:::direction_stage
  testthat::local_mocked_bindings(direction_stage = function(estimate, ...) {
    actual <- sum(vapply(list(...), function(x) as.double(utils::object.size(x)), numeric(1)))
    stages <<- c(stages, actual)
    original(estimate, ...)
  }, .package = "relm")
  x <- direction_test_build(f, max_bytes = ceiling(envelope))
  expect_lte(as.double(utils::object.size(x)), envelope)
  expect_true(length(stages) >= 66L)
  expect_lte(max(stages), envelope)
  # Equality is admitted; one byte below must refuse before computation.
  expect_error(direction_test_build(f, max_bytes = ceiling(envelope) - 1), class = "relm_error_oom")
})

test_that("wide canonical matrices stream in capped chunks without transposition", {
  f <- direction_test_fixture(n = 2L, h = 65536L); maximum <- 0L; total <- 0
  relm:::direction_stream("matrix", f$target, function(bytes) {
    maximum <<- max(maximum, length(bytes)); total <<- total + length(bytes)
  })
  expect_lte(maximum, 4096L)
  expect_gt(total, 8 * length(f$target))
  expect_lt(total, 8 * length(f$target) + 2^20 + 136 * 2 + 16 * 65536)
})

test_that("maximum-width arithmetic fits without copying neuron labels into temporaries", {
  f <- direction_test_fixture(n = 2L, h = 65536L)
  metadata <- as.double(utils::object.size(f$context))
  input <- sum(vapply(f, function(x) as.double(utils::object.size(x)), numeric(1)))
  envelope <- input + 4 * metadata + 1048576 + 8 * (40 * 65536 + 16 * 2) + 4 * (2 + 65536)
  sizes <- numeric(); original <- relm:::direction_stage
  testthat::local_mocked_bindings(direction_stage = function(estimate, ...) {
    sizes <<- c(sizes, sum(vapply(list(...), function(x) as.double(utils::object.size(x)), numeric(1))))
    original(estimate, ...)
  }, .package = "relm")
  x <- direction_test_build(f, normalize_pairs = TRUE, orthogonalize = TRUE)
  expect_length(x$value, 65536L)
  expect_lte(max(sizes), envelope)
  expect_lte(as.double(utils::object.size(x)), envelope)
  expect_identical(x$neuron, seq_len(65536L))
  expect_null(names(x$value))
})

test_that("checksum byte caps precede writes and interrupt cleanup closes descriptors", {
  before <- list.files(tempdir(), pattern = "^relm-direction-", full.names = TRUE)
  connections <- nrow(showConnections(all = TRUE))
  expect_error(relm:::direction_hash("values", list(neuron = 1L, value = 1), 8), class = "relm_error_internal")
  expect_identical(list.files(tempdir(), pattern = "^relm-direction-", full.names = TRUE), before)
  testthat::local_mocked_bindings(direction_stream = function(domain, x, emit, vector) {
    emit(as.raw(1)); signalCondition(structure(list(message = "injected interruption", call = NULL), class = c("interrupt", "condition")))
  }, .package = "relm")
  caught <- tryCatch(relm:::direction_hash("values", list(), 100), interrupt = identity)
  expect_s3_class(caught, "interrupt")
  expect_identical(list.files(tempdir(), pattern = "^relm-direction-", full.names = TRUE), before)
  expect_identical(nrow(showConnections(all = TRUE)), connections)
})

test_that("application charges destination context before native allocation", {
  x <- direction_test_build(); model <- attr(x, "direction")$context$model
  m <- direction_test_handle(model); model$engine_revision <- strrep("a", 2^20)
  calls <- 0L
  testthat::local_mocked_bindings(llm_steer = function(...) { calls <<- calls + 1L }, .package = "relm")
  expect_error(llm_apply_direction(m, x, model, max_bytes = 2^20), class = "relm_error_oom")
  expect_identical(calls, 0L)
})

test_that("warning-only canonical I/O fails closed with its original condition", {
  before <- list.files(tempdir(), pattern = "^relm-direction-", full.names = TRUE)
  testthat::local_mocked_bindings(direction_write_bytes = function(bytes, con) {
    warning("injected short write", call. = FALSE)
  }, .package = "relm")
  error <- tryCatch(relm:::direction_hash("values", list(neuron = 1L, value = 1), 1024), error = identity)
  expect_s3_class(error, "relm_error_intervention")
  expect_identical(error$reason, "direction_checksum_io")
  expect_s3_class(error$parent, "warning")
  expect_match(conditionMessage(error$parent), "injected short write")
  expect_identical(list.files(tempdir(), pattern = "^relm-direction-", full.names = TRUE), before)
})

test_that("silent partial canonical writes cannot validate a different file", {
  before <- list.files(tempdir(), pattern = "^relm-direction-", full.names = TRUE)
  testthat::local_mocked_bindings(direction_write_bytes = function(bytes, con) invisible(NULL), .package = "relm")
  error <- tryCatch(relm:::direction_hash("values", list(neuron = 1L, value = 1), 1024), error = identity)
  expect_s3_class(error, "relm_error_intervention")
  expect_identical(error$reason, "direction_checksum_io")
  expect_match(conditionMessage(error$parent), "incomplete byte count")
  expect_identical(list.files(tempdir(), pattern = "^relm-direction-", full.names = TRUE), before)
})
