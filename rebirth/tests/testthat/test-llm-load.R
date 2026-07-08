# WP1 Steps 4-5: llm() argument validation (all in R, before the boundary) and
# the boundary's error-payload mapping. Real-model loads are Step 8 ([MODEL]).

# --- argument validation: each bad argument errors before any engine call ----

test_that("llm() rejects a non-string path with relm_error_model_load", {
  expect_error(llm(42), class = "relm_error_model_load")
  expect_error(llm(c("a", "b")), class = "relm_error_model_load")
  expect_error(llm(character(0)), class = "relm_error_model_load")
  expect_error(llm(NA_character_), class = "relm_error_model_load")
  expect_error(llm(""), class = "relm_error_model_load")
})

test_that("llm() names the failing check for a missing file", {
  cnd <- tryCatch(
    llm(tempfile(fileext = ".gguf")),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_model_load")
  expect_identical(cnd$failing_check, "path_exists")
})

test_that("llm() rejects a directory path", {
  d <- tempfile()
  dir.create(d)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  cnd <- tryCatch(llm(d), condition = function(c) c)
  expect_s3_class(cnd, "relm_error_model_load")
  expect_identical(cnd$failing_check, "path_is_directory")
})

test_that("llm() validates context_length / gpu_layers / mmap with relm_error_argument", {
  f <- tempfile(fileext = ".gguf")
  file.create(f)
  on.exit(unlink(f), add = TRUE)

  expect_error(llm(f, context_length = 0), class = "relm_error_argument")
  expect_error(llm(f, context_length = -5), class = "relm_error_argument")
  expect_error(llm(f, context_length = 1.5), class = "relm_error_argument")
  expect_error(llm(f, context_length = c(10L, 20L)), class = "relm_error_argument")
  expect_error(llm(f, context_length = NA_integer_), class = "relm_error_argument")

  expect_error(llm(f, gpu_layers = -1), class = "relm_error_argument")
  expect_error(llm(f, gpu_layers = 1.5), class = "relm_error_argument")
  expect_error(llm(f, gpu_layers = c(1L, 2L)), class = "relm_error_argument")

  # values above the R integer range would otherwise coerce to NA at as.integer()
  expect_error(llm(f, context_length = 3e9), class = "relm_error_argument")
  expect_error(llm(f, gpu_layers = 3e9), class = "relm_error_argument")

  expect_error(llm(f, mmap = NA), class = "relm_error_argument")
  expect_error(llm(f, mmap = "yes"), class = "relm_error_argument")
  expect_error(llm(f, mmap = c(TRUE, FALSE)), class = "relm_error_argument")

  # the offending argument is named in a structured field
  cnd <- tryCatch(llm(f, context_length = 0), condition = function(c) c)
  expect_identical(cnd$argument, "context_length")
})

test_that("llm() rejects an unknown backend name (match.arg)", {
  f <- tempfile(fileext = ".gguf")
  file.create(f)
  on.exit(unlink(f), add = TRUE)
  expect_error(llm(f, backend = "opencl"))
})

test_that("llm() raises relm_error_backend for a backend the build lacks", {
  f <- tempfile(fileext = ".gguf")
  file.create(f)
  on.exit(unlink(f), add = TRUE)
  # CUDA is never built in WP1, so it is unavailable on every CI platform.
  cnd <- tryCatch(llm(f, backend = "cuda"), condition = function(c) c)
  expect_s3_class(cnd, "relm_error_backend")
  expect_identical(cnd$requested, "cuda")
  expect_match(cnd$available, "cpu")
})
