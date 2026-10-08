test_that("projection maps append typed counts at configured component sites", {
  f <- direction_test_fixture(); m <- direction_test_handle(f$context$model)
  m$architecture <- "llama"
  m$interventions <- list(
    list(kind = "project", layer = 1L, component = "attn_out", coef = 0),
    list(kind = "project", layer = 2L, component = "mlp_out", coef = 1),
    list(kind = "steer", layer = 2L, coef = 1),
    list(kind = "ablate", layer = 2L, component = "residual"))
  tab <- graphics_model_table(m, 1:2)
  expect_identical(names(tab), c("layer", "site", "detail", "configured_steers",
    "configured_ablations", "configured_projections"))
  expect_identical(typeof(tab$configured_projections), "integer")
  expect_identical(tab$configured_projections, c(1L, 0L, 0L, 0L, 1L, 0L))
  expect_identical(tab$configured_steers, c(0L, 0L, 0L, 0L, 0L, 1L))
  expect_identical(tab$configured_ablations, c(0L, 0L, 0L, 0L, 0L, 1L))
  expect_false(any(c("direction", "ptr", "coef") %in% names(tab)))
})

test_that("projection descriptions distinguish static component edits from live steering", {
  iv <- list(kind = "project", layer = 1L, component = "attn_out", coef = -1,
    direction = c(1, 0), positions = "all")
  text <- format_intervention(iv)
  expect_match(text, "project")
  expect_match(text, "attn_out")
  expect_match(text, "fixed coef -1", fixed = TRUE)
  expect_match(text, "layer 1", fixed = TRUE)
  expect_false(grepl("1, 0", text, fixed = TRUE))
  history <- live_steering_table(list(iv,
    list(kind = "steer", layer = 2L, coef = 0.5)))
  expect_identical(history$intervention, 2L)
  expect_identical(history$coef, 0.5)
})
