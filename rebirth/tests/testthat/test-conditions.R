# WP1 Step 4 (R side): the condition helpers that turn a boundary payload into a
# classed R error.

test_that("relm_abort raises the classed hierarchy with structured fields", {
  cnd <- tryCatch(
    relm:::relm_abort(
      "relm_error_model_load", "boom", list(failing_check = "path_exists")
    ),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_model_load")
  expect_s3_class(cnd, "relm_error")
  expect_s3_class(cnd, "error")
  expect_s3_class(cnd, "condition")
  expect_identical(conditionMessage(cnd), "boom")
  expect_identical(cnd$failing_check, "path_exists")
})

test_that("relm_error is never raised bare (always has a specific leaf class)", {
  cnd <- tryCatch(
    relm:::relm_abort("relm_error_backend", "no backend"),
    condition = function(c) c
  )
  # The specific class is first; the base class is never the leaf.
  expect_identical(class(cnd)[1], "relm_error_backend")
})

test_that("relm_check returns success payloads unchanged", {
  ok <- list(ok = TRUE, ptr = "handle")
  expect_identical(relm:::relm_check(ok), ok)
})

test_that("relm_check raises the classed condition described by a failure payload", {
  bad <- list(
    ok = FALSE,
    class = "relm_error_backend",
    message = "Backend 'cuda' is not available.",
    fields = list(requested = "cuda", available = "cpu")
  )
  expect_error(relm:::relm_check(bad), class = "relm_error_backend")
  cnd <- tryCatch(relm:::relm_check(bad), condition = function(c) c)
  expect_identical(cnd$requested, "cuda")
  expect_identical(cnd$available, "cpu")
  expect_identical(conditionMessage(cnd), "Backend 'cuda' is not available.")
})

# No engine or optional async dependency; runs in every ordinary R CI job.
test_that("thrown and async payload errors retain the same fields and hierarchy", {
  parent <- simpleError("original callback failure")
  fields <- list(callback = "on_token", parent = parent, reason = "delivery")
  payload <- list(ok = FALSE, class = "relm_error_callback",
    message = "Callback failed.", fields = fields)
  asynchronous <- relm:::async_payload_condition(payload)
  thrown <- tryCatch(relm:::relm_check(payload, call = NULL), error = identity)
  expect_identical(asynchronous, thrown)
  expect_identical(names(asynchronous), c("message", "call", "callback", "parent", "reason"))
  expect_identical(class(asynchronous), c("relm_error_callback", "relm_error", "error", "condition"))
  expect_null(conditionCall(asynchronous))
  expect_identical(asynchronous$parent, parent)

  origin <- quote(llm_generate(m, "hello"))
  thrown <- tryCatch(relm:::relm_check(payload, call = origin), error = identity)
  expect_identical(conditionCall(thrown), origin)
  thrown["call"] <- list(NULL)
  expect_identical(thrown, asynchronous)
})
