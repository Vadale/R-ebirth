# Public input and trace-boundary guards: every per-commit Mac/Linux R check.
test_that("probe labels and group identities are checked without coercion or recycling", {
  data <- probe_test_data()
  label <- data$y
  run <- function(label = data$y, groups = data$groups, test_groups = data$heldout, ...) {
    llm_probe(label ~ activations(layer = 1:2), data$trace, groups = groups,
              test_groups = test_groups, cv = 3, seed = 914, ...)
  }
  for (bad in list(rep(2, length(label)), replace(label, 1, NA), label[-1],
                   as.character(label), factor(label, levels = 0:2), rep(0, length(label)),
                   setNames(label, rep("1", length(label))),
                   setNames(label, c("unknown", as.character(2:length(label)))))) {
    expect_error(run(label = bad), class = "relm_error_probe")
  }
  for (bad in list(data$groups[-1], replace(data$groups, 1, ""), replace(data$groups, 1, NA_character_),
                   as.integer(factor(data$groups)), setNames(data$groups, rep("1", length(label))))) {
    expect_error(run(groups = bad), class = "relm_error_probe")
  }
  for (bad in list(character(), "unknown", NA_character_, rep(data$heldout[1], 2), unique(data$groups))) {
    expect_error(run(test_groups = bad), class = "relm_error_probe")
  }
  unsupported <- label
  unsupported[data$groups %in% data$heldout] <- 1
  condition <- tryCatch(run(label = unsupported), error = identity)
  expect_s3_class(condition, "relm_error_probe")
  expect_true(is.list(condition$counts))
  expect_match(conditionMessage(condition), "each class|independent groups")
  numeric <- run()
  logical <- run(label = as.logical(label))
  factor <- run(label = factor(ifelse(label, "yes", "no"), levels = c("no", "yes")))
  expect_identical(logical$fits, numeric$fits)
  expect_identical(factor$fits, numeric$fits)
  expect_true(!is.null(factor$label_mapping))
  implicit <- llm_probe(label ~ activations(layer = 1), data$trace, cv = 3, seed = 914)
  expect_identical(implicit$audit$group, as.character(implicit$audit$prompt_id))
})

test_that("probe formulas and fitting controls reject unsupported ambiguity", {
  data <- probe_test_data(); label <- data$y
  for (formula in list(label ~ 1, label ~ activations(1) + 1, label ~ activations(1) + label,
                       label ~ activations(1) * label, label ~ activations(1) + activations(2),
                       label ~ log(activations(1)), ~ activations(1))) {
    expect_error(llm_probe(formula, data$trace, cv = 3, seed = 914), class = "relm_error_probe")
  }
  for (cv in list(2, 3.5, NA_integer_, c(3, 4), 100)) {
    expect_error(llm_probe(label ~ activations(1), data$trace, cv = cv, seed = 914), class = "relm_error_probe")
  }
  for (seed in list(-1, NA_real_, 1.5, .Machine$integer.max + 1, c(1, 2))) {
    expect_error(llm_probe(label ~ activations(1), data$trace, cv = 3, seed = seed), class = "relm_error_probe")
  }
  expect_error(llm_probe(label ~ activations(1), data$trace, method = "unknown"), class = "relm_error_probe")
  expect_error(llm_probe(label ~ activations(1), data$trace, metric = "f1"), class = "relm_error_probe")
  expect_error(llm_probe(label ~ activations(99), data$trace), class = "relm_error_probe")
  expect_error(llm_probe(label ~ activations(1, component = "unknown"), data$trace), class = "relm_error_probe")
  expect_error(activations(1), class = "relm_error_probe")
})

test_that("balanced row counts cannot conceal duplicate or missing neuron coordinates", {
  data <- probe_test_data()
  baseline <- data$trace
  bad <- baseline
  bad$neuron[2] <- bad$neuron[1] # one duplicate and one hole, unchanged dimensions
  data$trace <- bad
  expect_error(probe_test_fit(data), class = "relm_error_probe")
  data$trace <- baseline[-2, ]
  expect_error(probe_test_fit(data), class = "relm_error_probe")
  data$trace <- baseline[!(baseline$layer == 2 & baseline$prompt_id == 1), ]
  expect_error(probe_test_fit(data), class = "relm_error_probe")
  bad <- baseline
  bad$token_pos[bad$layer == 2 & bad$prompt_id == 1] <- 99L
  data$trace <- bad
  expect_error(probe_test_fit(data), class = "relm_error_probe")
  bad <- baseline
  bad$token_pos[1] <- 99L # more than one position for a single prompt/layer
  data$trace <- bad
  expect_error(probe_test_fit(data), class = "relm_error_probe")
  for (value in c(NA_real_, Inf, -Inf, NaN)) {
    data$trace <- baseline; data$trace$value[1] <- value
    expect_error(probe_test_fit(data), class = "relm_error_probe")
  }
})

test_that("long trace labels must be constant within prompt and prediction coordinates exact", {
  data <- probe_test_data()
  data$trace$label <- data$y[data$trace$prompt_id]
  fit <- llm_probe(label ~ activations(1:2), data$trace, groups = data$groups,
                   test_groups = data$heldout, cv = 3, seed = 914)
  expect_identical(fit$fits, probe_test_fit(probe_test_data())$fits)
  data$trace$label[1] <- 1 - data$trace$label[1]
  expect_error(llm_probe(label ~ activations(1:2), data$trace, cv = 3, seed = 914), class = "relm_error_probe")
  predict_data <- probe_test_data()$trace
  expect_error(predict(fit, predict_data, layer = 99), class = "relm_error_probe")
  predict_data$neuron[predict_data$neuron == 3] <- 4L
  expect_error(predict(fit, predict_data), class = "relm_error_probe")
})

test_that("authentic Arrow spill, memory and shuffled rows yield identical fitted probes", {
  data <- probe_test_data()
  path <- tempfile(fileext = ".arrow")
  on.exit(unlink(path), add = TRUE)
  data$trace <- data$trace[rev(seq_len(nrow(data$trace))), ]
  expected <- probe_test_fit(data)
  spill <- probe_test_spill(data$trace, path)
  expect_equal(nrow(spill), 0L)
  expect_no_error(relm:::verify_spill_integrity(spill, path))
  expect_identical(nanoarrow::read_nanoarrow(path, lazy = TRUE)$get_schema()$children$value$format, "f")
  data$trace <- spill
  actual <- probe_test_fit(data)
  expect_identical(actual$fits, expected$fits)
  expect_identical(actual$audit, expected$audit)
  expect_identical(actual$cv_scores, expected$cv_scores)
  expect_identical(predict(actual, spill), predict(expected, probe_test_data()$trace))
  attr(spill, "spill_trace_id") <- "stale-provenance"
  data$trace <- spill
  expect_error(probe_test_fit(data), class = "relm_error_probe")
})
