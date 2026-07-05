# WP1 Step 4: the rebirth-ffi boundary. Each entry returns a classed payload
# (never throws from Rust), a caught panic becomes rebirth_error_internal, and
# the capability query R uses to resolve backends is correct.

test_that("the boundary maps a missing file to a model_load payload", {
  p <- rebirth:::rebirth_model_load(
    tempfile(fileext = ".gguf"), 512L, -1L, "cpu", TRUE
  )
  expect_false(p$ok)
  expect_identical(p$class, "rebirth_error_model_load")
  expect_identical(p$fields$failing_check, "file_not_found")
  expect_true(nzchar(p$message))
})

test_that("the boundary maps garbage bytes to a model_load payload (no crash)", {
  f <- tempfile(fileext = ".gguf")
  writeBin(as.raw(c(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)), f)
  on.exit(unlink(f), add = TRUE)
  p <- rebirth:::rebirth_model_load(f, 512L, -1L, "cpu", TRUE)
  expect_false(p$ok)
  expect_identical(p$class, "rebirth_error_model_load")
  expect_identical(p$fields$failing_check, "model_parse")
})

test_that("the boundary maps an unavailable backend to a backend payload", {
  p <- rebirth:::rebirth_model_load("nowhere.gguf", 512L, -1L, "cuda", TRUE)
  expect_false(p$ok)
  expect_identical(p$class, "rebirth_error_backend")
  expect_identical(p$fields$requested, "cuda")
  expect_match(p$fields$available, "cpu")
})

test_that("a forced panic maps to rebirth_error_internal, never reaching R raw", {
  p <- rebirth:::rebirth_selftest_panic()
  expect_false(p$ok)
  expect_identical(p$class, "rebirth_error_internal")
  expect_true(nzchar(p$fields$context))
  expect_error(rebirth:::rebirth_check(p), class = "rebirth_error_internal")
})

test_that("rebirth_available_backends reports cpu and never cuda in WP1", {
  b <- rebirth:::rebirth_available_backends()
  expect_type(b, "character")
  expect_true("cpu" %in% b)
  expect_false("cuda" %in% b)
  if (Sys.info()[["sysname"]] == "Darwin" &&
    R.version[["arch"]] %in% c("aarch64", "arm64")) {
    expect_true("metal" %in% b)
  }
})
