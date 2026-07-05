# WP1 Step 6: deterministic close, the closed tag, and double-close no-op. The
# real native free / flat-RSS / GC-only free checks are Step 8 ([MODEL]).

test_that("close.llm on an already-closed handle is an invisible NULL no-op", {
  m <- stub_llm(closed = TRUE)
  expect_null(close(m))
  expect_invisible(close(m))
})

test_that("any use of a closed handle raises rebirth_error_closed", {
  m <- stub_llm(closed = TRUE)
  expect_error(print(m), class = "rebirth_error_closed")
  expect_error(summary(m), class = "rebirth_error_closed")
})

test_that("close.llm marks the handle closed and is idempotent (empty handle)", {
  # A real, already-empty native handle exercises the close boundary with no
  # model file: the free is a safe no-op, the R-side tag transitions once.
  ptr <- rebirth:::rebirth_selftest_new_handle()
  payload <- list(
    ok = TRUE, ptr = ptr, architecture = "x", parameters = 1,
    quantization = "q", layers = 1L, hidden_size = 1L, context_length = 1L,
    backend = "cpu", context_train = 1L, size_bytes = 1, vocab_size = 1L,
    description = ""
  )
  m <- rebirth:::new_llm(payload, "x.gguf")
  expect_false(m$state$closed)

  expect_null(close(m))
  expect_true(m$state$closed)

  # Double close: still an invisible NULL, no error.
  expect_null(close(m))
  expect_true(m$state$closed)
})

test_that("the closed tag is shared across copies of a handle (env semantics)", {
  ptr <- rebirth:::rebirth_selftest_new_handle()
  payload <- list(
    ok = TRUE, ptr = ptr, architecture = "x", parameters = 1,
    quantization = "q", layers = 1L, hidden_size = 1L, context_length = 1L,
    backend = "cpu", context_train = 1L, size_bytes = 1, vocab_size = 1L,
    description = ""
  )
  m <- rebirth:::new_llm(payload, "x.gguf")
  m2 <- m # copying the R object never copies the native state
  close(m)
  # Closing one binding closes the shared handle.
  expect_true(m2$state$closed)
  expect_error(print(m2), class = "rebirth_error_closed")
})

test_that("the boundary closed tag: is_closed TRUE on an empty handle, close a no-op", {
  ptr <- rebirth:::rebirth_selftest_new_handle()
  expect_true(rebirth:::rebirth_handle_is_closed(ptr))
  expect_null(rebirth:::rebirth_handle_close(ptr)) # no-op, no crash
  expect_true(rebirth:::rebirth_handle_is_closed(ptr))
})

test_that("is_closed treats a NULL or foreign object as closed (defensive)", {
  expect_true(rebirth:::rebirth_handle_is_closed(NULL))
  expect_true(rebirth:::rebirth_handle_is_closed(42L))
  expect_true(rebirth:::rebirth_handle_is_closed("not a pointer"))
})
