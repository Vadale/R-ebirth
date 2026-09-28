# Materialized-object budgets and classed dependency failure, per-commit R CI.
test_that("probe memory refusal precedes dense layer allocation for both storage modes", {
  data <- probe_test_data()
  path <- tempfile(fileext = ".arrow")
  on.exit(unlink(path), add = TRUE)
  spilled <- probe_test_spill(data$trace, path)
  testthat::local_mocked_bindings(probe_layer_matrix = function(...) stop("DENSE ALLOCATION WAS REACHED"), .package = "relm")
  old <- options(relm.trace_budget = 1024)
  on.exit(options(old), add = TRUE)
  for (trace in list(data$trace, spilled)) {
    data$trace <- trace
    condition <- tryCatch(probe_test_fit(data), error = identity)
    expect_s3_class(condition, "relm_error_oom")
    expect_gt(condition$estimate_bytes, condition$budget_bytes)
    expect_equal(condition$budget_bytes, 1024)
    expect_match(conditionMessage(condition), "fewer|narrow", ignore.case = TRUE)
  }
})

test_that("the estimate covers measured materialized input and concurrent fit objects", {
  n <- 240L; p <- 32L
  x <- matrix(sin(seq_len(n * p)), n, p, dimnames = list(as.character(seq_len(n)), as.character(seq_len(p))))
  trace <- probe_test_trace(list(`1` = x, `2` = x))
  pre <- relm:::probe_preprocess(x)
  scaled <- relm:::probe_transform(x, pre)
  fit <- relm:::probe_ridge_fit(scaled, rep(0:1, length.out = n), lambda = 10^seq(4, -4, length.out = 41))
  # Measured R objects include long input, slice, original/transformed/training
  # matrices, full coefficient path and validation probabilities simultaneously.
  resident <- list(trace = trace, slice = as.data.frame(trace[trace$layer == 1, ]), x = x,
                   scaled = scaled, training = scaled[-seq_len(n/3), ], fit = fit,
                   probabilities = plogis(scaled %*% fit$coefficients))
  estimate <- relm:::probe_memory_estimate(n, p, 2L, cv = 3L, input_bytes = as.double(object.size(trace)))
  expect_lte(as.double(object.size(resident)), estimate)
  expect_gt(relm:::probe_memory_estimate(n * 2, p, 2L), relm:::probe_memory_estimate(n, p, 2L))
  expect_gt(relm:::probe_memory_estimate(n, p * 2, 2L), relm:::probe_memory_estimate(n, p, 2L))
  expect_gt(relm:::probe_memory_estimate(n, p, 4L), relm:::probe_memory_estimate(n, p, 2L))
  input <- 123456; read <- 654321
  expect_equal(relm:::probe_memory_estimate(n, p, 2L, input_bytes = input, read_bytes = read) -
                 relm:::probe_memory_estimate(n, p, 2L), input + read)
})

test_that("a missing optional solver fails through the real classed dependency guard", {
  guard <- relm:::probe_require_glmnet
  lookup <- new.env(parent = environment(guard))
  lookup$requireNamespace <- function(...) FALSE
  environment(guard) <- lookup
  testthat::local_mocked_bindings(probe_require_glmnet = guard, .package = "relm")
  condition <- tryCatch(probe_test_fit(), error = identity)
  expect_s3_class(condition, "relm_error_probe")
  expect_match(conditionMessage(condition), "install.packages.*glmnet")
  expect_true(is.character(condition$reason) && nzchar(condition$reason))
})

test_that("large Arrow string buffers count toward the slice read budget", {
  data <- probe_test_data()
  data$trace$token <- paste(rep("x", 10000), collapse = "")
  path <- tempfile(fileext = ".arrow")
  on.exit(unlink(path), add = TRUE)
  data$trace <- probe_test_spill(data$trace, path)
  initial <- relm:::probe_memory_estimate(72, 3, 2, 3, input_bytes = as.double(object.size(data$trace)))
  old <- options(relm.trace_budget = initial + 100000)
  on.exit(options(old), add = TRUE)
  condition <- tryCatch(probe_test_fit(data), error = identity)
  expect_s3_class(condition, "relm_error_oom")
  expect_gt(condition$estimate_bytes, initial + 100000)
})
