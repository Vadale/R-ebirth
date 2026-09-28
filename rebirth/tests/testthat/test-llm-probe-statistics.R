# Product numerical/uncertainty guards run in every Mac/Linux R package check.
# All 82 frozen ridge solutions are additionally mandatory in tests/probe-product/run.R.
test_that("ridge coefficients solve the mean-loss objective with an unpenalized intercept", {
  x <- as.matrix(expand.grid(`1` = c(-1, 1), `2` = c(-1, 1)))
  y <- as.integer(x[, 1] > 0)
  expect_warning(fit <- relm:::probe_ridge_fit(x, y, lambda = c(10, 1, .1), layer = 7L, fold = 2L), "fewer than 8")
  expect_equal(fit$intercept, rep(0, 3), tolerance = 2e-5)
  expect_equal(unname(fit$coefficients[2, ]), rep(0, 3), tolerance = 2e-5)
  expect_equal(unname(fit$coefficients[1, 2]), .401058137542, tolerance = 2e-5)
  for (j in seq_along(fit$lambda)) {
    p <- plogis(fit$intercept[j] + x %*% fit$coefficients[, j])
    expect_lt(abs(mean(p - y)), 2e-7)
    expect_lt(max(abs(colMeans(x * as.vector(p - y)) + fit$lambda[j] * fit$coefficients[, j])), 2e-7)
  }
})

test_that("train-only RMS preprocessing drops constants and handles one retained neuron", {
  x <- cbind(`1` = c(1, 2, 3), `2` = c(5, 5, 5))
  pre <- relm:::probe_preprocess(x)
  expect_equal(unname(pre$center), c(2, 5))
  expect_equal(unname(pre$scale), c(sqrt(2/3), 0))
  expect_equal(pre$keep, 1L)
  expect_equal(as.vector(relm:::probe_transform(rbind(x, c(1000, -999)), pre)),
               (c(1, 2, 3, 1000) - 2) / sqrt(2/3))
  one <- matrix(rep(c(-1, 1), 8), ncol = 1, dimnames = list(NULL, "9"))
  fit <- relm:::probe_ridge_fit(one, rep(c(0, 1), 8), lambda = 1)
  expect_equal(dim(fit$coefficients), c(1L, 1L))
  expect_identical(rownames(fit$coefficients), "9")
  expect_equal(unname(fit$coefficients[1, 1]), .401058137542, tolerance = 2e-5)
  expect_error(relm:::probe_preprocess(matrix(1, 10, 2)), class = "relm_error_probe")
})

test_that("metric ties and threshold equality follow the frozen pair-count contract", {
  y <- c(0, 1, 0, 1)
  expect_equal(relm:::probe_metric(y, c(.1, .2, .2, .1), "auc"), .5)
  expect_equal(relm:::probe_metric(y, c(.1, .2, .2, 0), "auc"), .375)
  expect_equal(relm:::probe_metric(y, rep(.5, 4), "auc"), .5)
  expect_equal(relm:::probe_metric(c(1, 0), c(.5, .49), "accuracy"), 1)
  expect_true(is.na(relm:::probe_metric(c(1, 1), c(.1, .9), "auc")))
})

test_that("cluster intervals preserve multiplicities, use type7 and fail closed", {
  groups <- rep(paste0("g", 1:20), each = 2)
  y <- rep(c(0, 1), 20)
  scores <- c(rep(c(.1, .9), 19), .9, .1)
  draws <- list(rep("g1", 20), rep("g20", 20))
  ci <- relm:::probe_intervals(y, scores, groups, "auc", draws = draws)
  expect_equal(ci$values, c(1, 0))
  expect_equal(c(ci$lower, ci$upper), c(.025, .975))
  expect_identical(ci$status, "available")
  expect_equal(ci$valid_draws, 2L)
  expect_equal(ci$undefined_draws, 0L)
  perfect <- relm:::probe_intervals(y, rep(c(.1, .9), 20), groups, "auc", draws = draws)
  expect_identical(perfect$status, "degenerate_bootstrap")
  expect_true(is.na(perfect$lower) && is.na(perfect$upper))
  sparse <- relm:::probe_intervals(y[1:6], scores[1:6], groups[1:6], "auc",
                                  draws = list(c("g1", "g2", "g3")))
  expect_identical(sparse$status, "insufficient_groups")
  homogeneous <- paste0("g", 1:20)
  unbalanced <- relm:::probe_intervals(c(rep(0, 16), rep(1, 4)), seq(.01, .99, length.out = 20),
    homogeneous, "auc", draws = list(homogeneous))
  expect_identical(unbalanced$status, "insufficient_class_groups")
  missing <- relm:::probe_intervals(rep(0:1, each = 10), seq(.01, .99, length.out = 20),
    homogeneous, "auc", draws = list(homogeneous, rep("g1", 20)))
  expect_identical(missing$status, "undefined_draw")
  expect_equal(missing$valid_draws, 1L)
  expect_equal(missing$undefined_draws, 1L)
  expect_true(is.na(missing$lower) && is.na(missing$upper))
})

test_that("a validation-only extreme cannot affect its fold's training transformation", {
  data <- probe_test_data()
  fit <- probe_test_fit(data)
  dev <- fit$audit$partition == "development"
  validation <- fit$audit$prompt_id[dev & fit$audit$fold == 1L]
  training <- as.character(fit$audit$prompt_id[dev & fit$audit$fold != 1L])
  original <- relm:::probe_preprocess
  seen <- list()
  testthat::local_mocked_bindings(probe_preprocess = function(x) {
    value <- original(x)
    if (setequal(rownames(x), training)) seen[[length(seen) + 1L]] <<- value
    value
  }, .package = "relm")
  probe_test_fit(data)
  before <- seen
  expect_length(before, 2L)
  seen <- list()
  data$trace$value[data$trace$prompt_id %in% validation & data$trace$neuron == 2L] <- 1e5
  probe_test_fit(data)
  expect_identical(seen, before)
})

test_that("solver failures and incomplete paths cannot become partial probe fits", {
  x <- cbind(`1` = rep(c(-1, 1), 8), `2` = rep(c(-1, -1, 1, 1), 4))
  y <- rep(c(0, 1), 8)
  original <- relm:::probe_glmnet
  for (mode in c("throw", "jerr", "truncate")) {
    local({
      failure <- mode
      testthat::local_mocked_bindings(probe_glmnet = function(x, y, lambda) {
        if (failure == "throw") stop("solver sentinel")
        fit <- original(x, y, lambda)
        if (failure == "jerr") fit$jerr <- -1L
        if (failure == "truncate") {
          fit$lambda <- head(fit$lambda, -1L)
          fit$beta <- fit$beta[, -ncol(fit$beta), drop = FALSE]
          fit$a0 <- head(fit$a0, -1L)
        }
        fit
      }, .package = "relm")
      condition <- tryCatch(relm:::probe_ridge_fit(x, y, c(10, 1, .1), layer = 4L, fold = 2L), error = identity)
      expect_s3_class(condition, "relm_error_probe")
      expect_true(is.character(condition$reason) && nzchar(condition$reason))
      expect_equal(condition$layer, 4L)
      expect_equal(condition$fold, 2L)
      if (failure == "throw") {
        set.seed(135)
        before <- .Random.seed
        expect_error(probe_test_fit(), class = "relm_error_probe")
        expect_identical(.Random.seed, before)
      }
    })
  }
})

test_that("a deliberately leaky allocator is rejected before fitting", {
  testthat::local_mocked_bindings(
    probe_allocate_folds = function(y, groups, cv) rep(seq_len(cv), length.out = length(y)),
    probe_glmnet = function(...) stop("SOLVER WAS REACHED WITH LEAKY GROUPS"), .package = "relm")
  condition <- tryCatch(probe_test_fit(), error = identity)
  expect_s3_class(condition, "relm_error_probe")
  expect_match(condition$reason, "group|fold|split|audit")
})

test_that("caller glmnet controls are restored and cannot silently change the objective path", {
  previous <- glmnet::glmnet.control()
  on.exit(do.call(glmnet::glmnet.control, previous), add = TRUE)
  glmnet::glmnet.control(fdev = .2, devmax = .1)
  caller <- glmnet::glmnet.control()
  fit <- probe_test_fit()
  expect_identical(glmnet::glmnet.control(), caller)
  expect_length(unique(fit$cv_scores$lambda), 41L)
})

test_that("the development refit warm-starts through the selected endpoint and retains it", {
  # Replay the interior index from the real wide-trace cold-start failure.
  # Tagged solver columns distinguish a cold fit, the complete path, and an
  # accidental extraction of the first prefix column; numerics are tested above.
  grid <- 10^seq(4, -4, length.out = 41)
  chosen <- 35L
  calls <- list()
  testthat::local_mocked_bindings(
    probe_ridge_fit = function(x, y, lambda, layer = NULL, fold = NULL) {
      calls[[length(calls) + 1L]] <<- list(lambda = lambda, fold = fold)
      index <- match(lambda, grid)
      coefficients <- matrix(0, ncol(x), length(lambda), dimnames = list(colnames(x), NULL))
      if (is.null(fold)) coefficients[] <- outer(seq_len(ncol(x)), index) / 100
      list(intercept = index / 100, coefficients = coefficients,
           lambda = lambda, solver = list(version = "controlled replay"))
    },
    probe_metric = function(y, score, metric) 1 - abs(qlogis(mean(score)) - chosen / 100),
    .package = "relm")
  label <- rep(0:1, 12)
  x <- cbind(`1` = 2 * label - 1, `2` = rep(c(-1, -1, 1, 1), 6))
  trace <- probe_test_trace(list(`1` = x))
  fit <- llm_probe(label ~ activations(1), trace,
                   groups = rep(paste0("pair", 1:12), each = 2), cv = 3, seed = 914)
  expect_length(calls, 4L)
  for (call in calls[1:3]) expect_identical(call$lambda, grid)
  expect_null(calls[[4]]$fold)
  expect_identical(calls[[4]]$lambda, grid[seq_len(chosen)])
  expect_equal(fit$fits[[1]]$lambda, grid[chosen])
  expect_equal(fit$fits[[1]]$intercept, .35)
  expect_equal(unname(fit$fits[[1]]$coefficients), c(.35, .7))
  expect_equal(unname(predict(fit, trace)), as.vector(plogis(.35 + x %*% c(.35, .7))))
})
