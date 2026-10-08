test_that("direction operators are exact plain strings before artifact work", {
  e <- projection_application_env(); touched <- 0L
  e$direction_validate <- function(...) { touched <<- touched + 1L; stop("unexpected validation") }
  for (op in list("pro", "PROJECT", NA_character_, c("add", "project"), c(named = "project"), 1)) {
    expect_error(e$llm_apply_direction(NULL, NULL, NULL, operator = op), class = "relm_error_argument")
  }
  expect_identical(touched, 0L)
  expect_identical(tail(names(formals(llm_apply_direction)), 1L), "operator")
  expect_identical(formals(llm_apply_direction)$operator, "add")
})

test_that("projection application routes validated first and last component sites", {
  for (component in c("mlp_out", "attn_out")) for (layer in c(1L, 24L)) {
    f <- projection_application_artifact(component, layer); e <- projection_application_env()
    result <- e$llm_apply_direction(f$m, f$x, f$context, coef = -1, operator = "project")
    expect_s3_class(result, "llm")
    expect_identical(e$seen$entry, list(kind = "project", layer = layer,
      component = component, direction = f$x$value, coef = -1))
    expected <- relm:::direction_validate(f$x, extra_bytes = 4 * as.double(object.size(f$context)))$estimate_bytes
    expect_identical(e$seen$estimate, expected)
    expect_identical(e$seen$budget, 64 * 2^20)
    expect_true(e$seen$application)
  }
})

test_that("operator mismatch tampering and foreign provenance precede derivation", {
  component <- projection_application_artifact(); residual <- projection_application_artifact("residual")
  e <- projection_application_env()
  e$llm_steer <- function(...) stop("unexpected additive derivation")
  expect_error(e$llm_apply_direction(component$m, component$x, component$context), class = "relm_error_intervention")
  expect_error(e$llm_apply_direction(residual$m, residual$x, residual$context, operator = "project"), class = "relm_error_intervention")
  bad <- component$x; bad$value[1] <- bad$value[1] + .01
  expect_error(e$llm_apply_direction(component$m, bad, component$context, operator = "project"), class = "relm_error_intervention")
  foreign <- component$context; foreign$sha256 <- paste(rep("b", 64), collapse = "")
  expect_error(e$llm_apply_direction(component$m, component$x, foreign, operator = "project"), class = "relm_error_intervention")
  expect_identical(e$calls, 0L)
})

test_that("projection coefficients retain zero and reject hidden or non-f32 values", {
  f <- projection_application_artifact(); e <- projection_application_env()
  for (coef in list(NA_real_, Inf, 4e38, c(1, 2), c(named = 1), structure(1, hidden = raw(8)))) {
    expect_error(e$llm_apply_direction(f$m, f$x, f$context, coef = coef, operator = "project"), class = "relm_error_intervention")
  }
  expect_identical(e$calls, 0L)
  e$llm_apply_direction(f$m, f$x, f$context, coef = 0L, operator = "project")
  expect_identical(e$seen$entry$coef, 0)
})

test_that("additive application preserves old dispatch and charges new artifact on projected source", {
  f <- projection_application_artifact("residual"); e <- projection_application_env(); additive <- NULL
  e$llm_steer <- function(m, layer, direction, coef, positions) {
    additive <<- list(m, layer, direction, coef, positions); structure(list(), class = "llm")
  }
  e$llm_apply_direction(f$m, f$x, f$context, coef = -.5)
  expect_identical(additive, list(f$m, 2L, f$x$value, -.5, "all"))
  expect_identical(e$calls, 0L)
  f$m$interventions <- list(list(kind = "project"))
  attr(f$m, "projection") <- list(max_bytes = 32 * 2^20, existing_direction_estimate = 512)
  e$llm_apply_direction(f$m, f$x, f$context, coef = .5, max_bytes = 48 * 2^20, operator = "add")
  expect_identical(e$seen$budget, 48 * 2^20)
  expect_gt(e$seen$estimate, 512)
  expect_identical(e$seen$entry, list(kind = "steer", layer = 2L, direction = f$x$value, coef = .5, positions = "all"))
  expect_true(e$seen$application)
})

test_that("ordinary residual derivation preserves the recorded projection admission", {
  e <- projection_application_env(); m <- direction_test_handle(direction_test_fixture()$context$model)
  m$interventions <- list(list(kind = "project"))
  attr(m, "projection") <- list(max_bytes = 32 * 2^20, existing_direction_estimate = 2048)
  for (entry in list(list(kind = "steer", layer = 2L, direction = rep(.25, 4), coef = 1, positions = "all"),
                     list(kind = "ablate", layer = 1L, neurons = 1L, value = 0, component = "residual"))) {
    e$derive_intervened(m, entry)
    expect_identical(e$seen$entry, entry)
    expect_identical(e$seen$budget, 32 * 2^20)
    expect_identical(e$seen$estimate, 2048)
    expect_false(e$seen$application)
  }
})

test_that("projection image requests and live projection revisions refuse without execution", {
  m <- direction_test_handle(direction_test_fixture()$context$model); m$vision <- TRUE
  m$interventions <- list(list(kind = "project", layer = 2L, coef = 1),
    list(kind = "steer", layer = 2L, coef = .5))
  expect_error(relm:::check_images_usable(m, list("absent.png")), "Projected handles", class = "relm_error_image")
  expect_null(relm:::check_images_usable(m, NULL))
  expect_null(relm:::check_images_usable(m, list(character())))
  expect_error(relm:::live_reply(list(steer = data.frame(intervention = 1L, coef = 0)),
    interventions = m$interventions), class = "relm_error_argument")
  reply <- relm:::live_reply(list(steer = data.frame(intervention = 2L, coef = 0)), interventions = m$interventions)
  expect_true(is.list(reply))
})

test_that("explicit direction inheritance uses a new combined budget and production preflight", {
  e <- projection_binding_fixture(); m <- projection_owner_model(interventions = list(projection_owner_entry()))
  attr(m, "projection") <- list(max_bytes = 32 * 2^20, existing_direction_estimate = 1024)
  entry <- list(kind = "steer", layer = 2L, direction = rep(.25, 3), coef = 1, positions = "all")
  z <- e$projection_prepare(m, entry, 48 * 2^20, 2048, direction_application = TRUE)
  expect_identical(z$config$max_bytes, 48 * 2^20)
  expect_identical(z$config$existing_direction_estimate, 2048)
  expect_identical(z$response$inputs$production_armed, 1)
  expect_error(e$projection_prepare(m, entry, 48 * 2^20, 2048), class = "relm_error_intervention")
  original <- e$rebirth_projection_preflight
  e$rebirth_projection_preflight <- function(...) { r <- original(...);r$inputs$production_armed <- 0;r }
  expect_error(e$projection_prepare(m, entry, 32 * 2^20, 1024), class = "relm_error_intervention")
})
