# WP1 Step 6: deterministic close, the closed tag, and double-close no-op. The
# real native free / flat-RSS / GC-only free checks are Step 8 ([MODEL]).

test_that("close.llm on an already-closed handle is an invisible NULL no-op", {
  m <- stub_llm(closed = TRUE)
  expect_null(close(m))
  expect_invisible(close(m))
})

test_that("any use of a closed handle raises relm_error_closed", {
  m <- stub_llm(closed = TRUE)
  expect_error(print(m), class = "relm_error_closed")
  expect_error(summary(m), class = "relm_error_closed")
})

test_that("close.llm marks the handle closed and is idempotent (empty handle)", {
  # A real, already-empty native handle exercises the close boundary with no
  # model file: the free is a safe no-op, the R-side tag transitions once.
  m <- empty_handle_llm()
  expect_false(m$state$closed)

  expect_null(close(m))
  expect_true(m$state$closed)

  # Double close: still an invisible NULL, no error.
  expect_null(close(m))
  expect_true(m$state$closed)
})

test_that("the closed tag is shared across copies of a handle (env semantics)", {
  m <- empty_handle_llm()
  m2 <- m # copying the R object never copies the native state
  close(m)
  # Closing one binding closes the shared handle.
  expect_true(m2$state$closed)
  expect_error(print(m2), class = "relm_error_closed")
})

test_that("the boundary closed tag: is_closed TRUE on an empty handle, close a no-op", {
  ptr <- relm:::rebirth_selftest_new_handle()
  expect_true(relm:::rebirth_handle_is_closed(ptr))
  expect_null(relm:::rebirth_handle_close(ptr)) # no-op, no crash
  expect_true(relm:::rebirth_handle_is_closed(ptr))
})

test_that("is_closed treats a NULL or foreign object as closed (defensive)", {
  expect_true(relm:::rebirth_handle_is_closed(NULL))
  expect_true(relm:::rebirth_handle_is_closed(42L))
  expect_true(relm:::rebirth_handle_is_closed("not a pointer"))
})
