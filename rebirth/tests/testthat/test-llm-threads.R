# D055: ordinary R CI, production-compatible tiny fixture; no downloaded model.
test_that("llm refuses invalid explicit CPU thread counts before loading", {
  path <- test_path("fixtures", "synthetic-llama-2l.gguf")
  for (threads in list(0, -1, 1.5, NA_real_, NaN, Inf, -Inf,
                      .Machine$integer.max + 1, TRUE, "8", numeric(), c(1, 2))) {
    error <- tryCatch(llm(path, threads = threads), error = identity)
    expect_s3_class(error, "relm_error_argument")
    expect_identical(error$argument, "threads")
  }
})

test_that("explicit threads load through the public CPU route", {
  path <- test_path("fixtures", "synthetic-llama-2l.gguf")
  for (threads in list(NULL, 1L, 8)) {
    model <- llm(path, context_length = 64L, backend = "cpu", threads = threads)
    expect_s3_class(model, "llm")
    expect_identical(summary(model)$backend, "cpu")
    close(model)
  }
})

test_that("the native load boundary independently rejects negative CPU threads", {
  for (threads in c(-1L, -2L)) {
    payload <- relm:::rebirth_model_load("missing.gguf", 64L, 0L, "cpu", TRUE, "", threads)
    expect_false(payload$ok)
    expect_identical(payload$class, "relm_error_argument")
    expect_identical(payload$fields$argument, "threads")
  }
  # NA cannot be represented by extendr's private i32 argument. Public llm()
  # rejects it above with relm_error_argument before reaching this conversion.
  expect_error(
    relm:::rebirth_model_load("missing.gguf", 64L, 0L, "cpu", TRUE, "", NA_integer_),
    "Must not be NA", fixed = TRUE
  )
})
