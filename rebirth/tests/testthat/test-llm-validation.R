# Shared public-handle admission: no model, inference or download. Runs in every
# ordinary R CI job. Invalid handles must win before other arguments are forced.
handle_validation_calls <- function() {
  list(
    quote(llm_tokens(m, stop("token input was forced"))),
    quote(llm_generate(m, stop("prompt was forced"))),
    quote(llm_logits(m, stop("prompt was forced"))),
    quote(llm_embed(m, stop("embedding input was forced"))),
    quote(llm_trace(m, stop("trace input was forced"))),
    quote(llm_steer(m, stop("layer was forced"), stop("direction was forced"))),
    quote(llm_ablate(m, stop("layer was forced"), stop("neurons were forced"))),
    quote(llm_cancel(m))
  )
}

test_that("public handle guards retain argument error details and call sites", {
  m <- "not a model"
  for (call in handle_validation_calls()) {
    error <- tryCatch(eval(call), error = identity)
    expect_identical(class(error), c("relm_error_argument", "relm_error", "error", "condition"))
    expect_identical(error$argument, "m")
    expect_identical(conditionMessage(error), "`m` must be an `llm` handle returned by llm().")
    expect_identical(conditionCall(error), call)
  }
})

test_that("public handle guards retain closed errors before evaluating inputs", {
  m <- stub_llm(closed = TRUE)
  for (call in handle_validation_calls()) {
    error <- tryCatch(eval(call), error = identity)
    expect_identical(class(error), c("relm_error_closed", "relm_error", "error", "condition"))
    expect_identical(conditionMessage(error),
      "This model handle is closed. Load the model again with llm() to obtain a fresh handle.")
    expect_identical(conditionCall(error), call)
  }
})

test_that("public guards synchronize native closure once without reaching model work", {
  queries <- 0L
  local_mocked_bindings(rebirth_handle_is_closed = function(ptr) {
    queries <<- queries + 1L
    TRUE
  }, .package = "relm")
  m <- stub_llm()
  m$ptr <- methods::new("externalptr")
  for (call in handle_validation_calls()) {
    error <- tryCatch(eval(call), error = identity)
    expect_s3_class(error, "relm_error_closed")
    expect_identical(conditionCall(error), call)
  }
  expect_true(m$state$closed)
  expect_identical(queries, 1L)
})
