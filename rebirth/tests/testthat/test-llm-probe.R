# WP11b public acceptance: runs in the per-commit Mac/Linux R matrix, model-free.
test_that("probes keep source pairs isolated and choose using development data", {
  data <- probe_test_data()
  fit <- probe_test_fit(data)
  expect_s3_class(fit, "llm_probe")
  expect_s3_class(fit$audit, "data.frame")
  expect_named(fit$fits, c("1", "2"))
  expect_equal(fit$selected_layer, 1L)
  expect_equal(fit$metrics$lambda, rep(1e4, 2))
  expect_true(all(fit$metrics$boundary))
  for (source in unique(data$groups)) {
    rows <- fit$audit[fit$audit$group == source, ]
    expect_equal(nrow(rows), 2L)
    expect_length(unique(rows$partition), 1L)
    expect_length(unique(rows$fold), 1L)
  }
  expect_setequal(fit$audit$group[fit$audit$partition == "test"], data$heldout)
  expect_true(all(is.na(fit$audit$fold[fit$audit$partition == "test"])))
  expect_equal(fit$metrics$test_score, c(1, 1))
  expect_true(all(fit$metrics$interval_status == "degenerate_bootstrap"))
  expect_true(all(is.na(fit$metrics$lower) & is.na(fit$metrics$upper)))
  expect_equal(fit$metrics$valid_draws + fit$metrics$undefined_draws, rep(2000L, 2))
  expect_equal(fit$cv_scores$lambda |> unique(), 10^seq(4, -4, length.out = 41))
})

test_that("holdout mutations cannot alter folds, preprocessing, fits or selection", {
  original <- probe_test_data()
  fit <- probe_test_fit(original)
  held <- original$groups %in% original$heldout
  changed <- original
  changed$y[held] <- 1 - changed$y[held]
  changed$trace$value[changed$trace$prompt_id %in% which(held)] <-
    1000 + changed$trace$value[changed$trace$prompt_id %in% which(held)] * -31
  mutated <- probe_test_fit(changed)
  expect_identical(mutated$fits, fit$fits)
  expect_identical(mutated$cv_scores, fit$cv_scores)
  expect_identical(mutated$selected_layer, fit$selected_layer)
  expect_identical(mutated$audit[!held, ], fit$audit[!held, ])
  expect_false(identical(mutated$predictions$probability, fit$predictions$probability))

  # A different held-out winner must not change predict()'s default layer.
  changed <- original
  which <- changed$trace$prompt_id %in% which(held) & changed$trace$layer == 1L & changed$trace$neuron == 1L
  changed$trace$value[which] <- -changed$trace$value[which]
  swapped <- probe_test_fit(changed)
  expect_equal(swapped$metrics$test_score, c(0, 1))
  expect_equal(swapped$selected_layer, 1L)
  expect_identical(predict(swapped, changed$trace), predict(swapped, changed$trace, layer = 1L))
  expect_false(identical(predict(swapped, changed$trace), predict(swapped, changed$trace, layer = 2L)))
})

test_that("trace row order and exact prompt-name matching leave predictions invariant", {
  data <- probe_test_data()
  fit <- probe_test_fit(data)
  label <- setNames(data$y, as.character(seq_along(data$y)))
  groups <- setNames(data$groups, names(label))
  named_label <- label[rev(seq_along(label))]
  shuffled <- data$trace[rev(seq_len(nrow(data$trace))), ]
  matched <- llm_probe(named_label ~ activations(layer = 2:1), shuffled,
                      groups = groups[rev(seq_along(groups))], test_groups = data$heldout, cv = 3, seed = 914)
  expect_identical(matched$fits, fit$fits)
  expect_identical(matched$audit, fit$audit)
  expect_identical(predict(fit, shuffled), predict(fit, data$trace))
  expect_named(predict(fit, shuffled), as.character(seq_along(data$y)))
})

test_that("seeded fitting restores RNG state including its absence and error paths", {
  data <- probe_test_data()
  set.seed(841)
  before <- .Random.seed
  first <- probe_test_fit(data)
  expect_identical(.Random.seed, before)
  expect_identical(probe_test_fit(data)$audit, first$audit)
  expect_identical(.Random.seed, before)
  bad <- data; bad$y[] <- 0
  expect_error(probe_test_fit(bad), class = "relm_error_probe")
  expect_identical(.Random.seed, before)
  label <- data$y
  llm_probe(label ~ activations(1:2), data$trace, groups = data$groups,
            test_groups = data$heldout, cv = 3, seed = NULL)
  expect_false(identical(.Random.seed, before))
  rm(".Random.seed", envir = .GlobalEnv)
  on.exit(assign(".Random.seed", before, envir = .GlobalEnv), add = TRUE)
  expect_false(exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE))
  probe_test_fit(data)
  expect_false(exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE))
})

test_that("S3 methods distinguish held-out and exploratory results", {
  data <- probe_test_data()
  fit <- probe_test_fit(data)
  expect_output(print(fit), "probe", ignore.case = TRUE)
  report <- summary(fit)
  expect_s3_class(report, "summary.llm_probe")
  expect_identical(report$audit, fit$audit)
  expect_identical(report$preprocessing, lapply(fit$fits, `[[`, "preprocess"))
  expect_output(print(fit), "held-out")
  label <- data$y
  exploratory <- llm_probe(label ~ activations(layer = 1:2), data$trace,
                            groups = data$groups, cv = 3, seed = 914)
  expect_true(all(exploratory$metrics$interval_status == "not_evaluated"))
  expect_true(all(is.na(exploratory$metrics$test_score)))
  expect_true(all(is.na(exploratory$metrics$lower)))
  expect_output(print(exploratory), "exploratory CV.*no inferential")
  path <- tempfile(fileext = ".pdf")
  grDevices::pdf(path)
  on.exit({ grDevices::dev.off(); unlink(path) }, add = TRUE)
  expect_identical(plot(fit), fit$metrics)
  expect_identical(plot(exploratory), exploratory$metrics)
})

test_that("a whole-procedure paired-label control exposes perfect lexical confounding", {
  data <- probe_test_data()
  signal <- probe_test_fit(data)
  expect_equal(signal$metrics$test_score, c(1, 1))
  # A fixed within-source swap of half the development pairs removes the
  # constructed label-feature association. Held-out targets remain untouched.
  swap_groups <- unique(data$groups)[seq_len(12)][rep(c(TRUE, TRUE, FALSE, FALSE), 3)]
  swap <- data$groups %in% swap_groups & !data$groups %in% data$heldout
  data$y[swap] <- 1 - data$y[swap]
  control <- probe_test_fit(data)
  expect_equal(control$metrics$test_score, c(.5, .5))
  expect_identical(control$predictions$label, signal$predictions$label)
  expect_false(identical(control$audit$label, signal$audit$label))
  expect_true(all(vapply(control$fits, function(x) max(abs(x$coefficients)) < 1e-12, logical(1))))
})

test_that("selection diagnostics average unequal folds without observation weights", {
  group_id <- rep(seq_len(12), c(rep(2L, 11), 40L))
  label <- rep(0:1, length.out = length(group_id))
  x <- cbind(`1` = (2 * label - 1) * ifelse(group_id <= 5 | group_id == 12, 1, -1),
             `2` = cos(group_id))
  trace <- probe_test_trace(list(`1` = x))
  fit <- llm_probe(label ~ activations(1), trace, groups = as.character(group_id), cv = 3, seed = 914)
  fold <- fit$cv_scores[fit$cv_scores$lambda == fit$metrics$lambda, ]
  counts <- tabulate(fit$audit$fold, 3)
  expect_gt(length(unique(counts)), 1L)
  expect_equal(fit$metrics$cv_score, mean(fold$score))
  expect_gt(abs(mean(fold$score) - weighted.mean(fold$score, counts[fold$fold])), .01)
})
