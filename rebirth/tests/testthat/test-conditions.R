# WP1 Step 4 (R side): the condition helpers that turn a boundary payload into a
# classed R error.

test_that("rebirth_abort raises the classed hierarchy with structured fields", {
  cnd <- tryCatch(
    rebirth:::rebirth_abort(
      "rebirth_error_model_load", "boom", list(failing_check = "path_exists")
    ),
    condition = function(c) c
  )
  expect_s3_class(cnd, "rebirth_error_model_load")
  expect_s3_class(cnd, "rebirth_error")
  expect_s3_class(cnd, "error")
  expect_s3_class(cnd, "condition")
  expect_identical(conditionMessage(cnd), "boom")
  expect_identical(cnd$failing_check, "path_exists")
})

test_that("rebirth_error is never raised bare (always has a specific leaf class)", {
  cnd <- tryCatch(
    rebirth:::rebirth_abort("rebirth_error_backend", "no backend"),
    condition = function(c) c
  )
  # The specific class is first; the base class is never the leaf.
  expect_identical(class(cnd)[1], "rebirth_error_backend")
})

test_that("rebirth_check returns success payloads unchanged", {
  ok <- list(ok = TRUE, ptr = "handle")
  expect_identical(rebirth:::rebirth_check(ok), ok)
})

test_that("rebirth_check raises the classed condition described by a failure payload", {
  bad <- list(
    ok = FALSE,
    class = "rebirth_error_backend",
    message = "Backend 'cuda' is not available.",
    fields = list(requested = "cuda", available = "cpu")
  )
  expect_error(rebirth:::rebirth_check(bad), class = "rebirth_error_backend")
  cnd <- tryCatch(rebirth:::rebirth_check(bad), condition = function(c) c)
  expect_identical(cnd$requested, "cuda")
  expect_identical(cnd$available, "cpu")
  expect_identical(conditionMessage(cnd), "Backend 'cuda' is not available.")
})
