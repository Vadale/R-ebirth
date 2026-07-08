# llm_tokens(): encode text -> named integer ids, decode ids -> text.
#
# Three layers of coverage:
#   1. R-side argument validation (no model needed; uses stub_llm()).
#   2. The no_vocab synthetic model raises relm_error_tokenize, never a crash
#      (download-free, runs in CI).
#   3. Real-model round-trips incl. Italian accented text (env-gated on
#      RELM_TEST_MODEL_QWEN, skipped in CI).

qwen_model <- function() {
  path <- Sys.getenv("RELM_TEST_MODEL_QWEN")
  skip_if(!nzchar(path), "RELM_TEST_MODEL_QWEN not set")
  skip_if_not(file.exists(path), "RELM_TEST_MODEL_QWEN points at a missing file")
  path
}

synthetic_model_path <- function() {
  p <- testthat::test_path("fixtures", "synthetic-llama-2l.gguf")
  skip_if_not(file.exists(p), "synthetic GGUF fixture is missing")
  p
}

# --- 1. argument validation (no boundary crossing) -------------------------

test_that("llm_tokens rejects a non-llm handle", {
  expect_error(
    llm_tokens("not a model", "hello"),
    class = "relm_error_argument"
  )
})

test_that("llm_tokens rejects a non-logical decode", {
  m <- stub_llm()
  expect_error(llm_tokens(m, "hi", decode = "yes"), class = "relm_error_argument")
  expect_error(llm_tokens(m, "hi", decode = c(TRUE, FALSE)), class = "relm_error_argument")
  expect_error(llm_tokens(m, "hi", decode = NA), class = "relm_error_argument")
})

test_that("llm_tokens (encode) rejects non-character x", {
  m <- stub_llm()
  expect_error(llm_tokens(m, 1:3), class = "relm_error_tokenize")
  expect_error(llm_tokens(m, c("a", NA)), class = "relm_error_tokenize")
})

test_that("llm_tokens (decode) rejects non-integer or non-positive ids", {
  m <- stub_llm()
  expect_error(llm_tokens(m, c(1.5, 2), decode = TRUE), class = "relm_error_tokenize")
  expect_error(llm_tokens(m, "abc", decode = TRUE), class = "relm_error_tokenize")
  # 0 is invalid: token ids are 1-based in the R API.
  expect_error(llm_tokens(m, c(1L, 0L), decode = TRUE), class = "relm_error_tokenize")
})

test_that("llm_tokens on a closed handle raises relm_error_closed", {
  m <- empty_handle_llm()
  close(m)
  expect_error(llm_tokens(m, "hi"), class = "relm_error_closed")
})

# --- 2. no_vocab model: a classed condition, not a crash -------------------

test_that("llm_tokens on a no_vocab model raises relm_error_tokenize", {
  m <- llm(synthetic_model_path(), backend = "cpu")
  on.exit(close(m), add = TRUE)
  expect_error(llm_tokens(m, "hello"), class = "relm_error_tokenize")
  expect_error(llm_tokens(m, c(1L, 2L), decode = TRUE), class = "relm_error_tokenize")
})

# --- 3. real-model round-trips (env-gated) ---------------------------------

test_that("encode returns a named integer vector of 1-based ids", {
  m <- llm(qwen_model())
  on.exit(close(m), add = TRUE)

  ids <- llm_tokens(m, "The quick brown fox")
  expect_type(ids, "integer")
  expect_true(length(ids) >= 1L)
  expect_false(is.null(names(ids)))
  expect_true(all(ids >= 1L)) # 1-based: no id is 0 or negative
})

test_that("encode/decode is an exact round-trip (ASCII)", {
  m <- llm(qwen_model())
  on.exit(close(m), add = TRUE)

  txt <- "Hello, world! Numbers 123 and symbols #@%."
  expect_identical(llm_tokens(m, llm_tokens(m, txt), decode = TRUE), txt)
})

test_that("encode/decode round-trips Italian accented text (UTF-8)", {
  m <- llm(qwen_model())
  on.exit(close(m), add = TRUE)

  # Accented vowels, a truncation apostrophe, and a multi-byte euro sign.
  italian <- "Perché a Città di Castello si beve un caffè da 1€? Perché è così."
  ids <- llm_tokens(m, italian)
  expect_true(all(ids >= 1L))
  expect_identical(llm_tokens(m, ids, decode = TRUE), italian)
})

test_that("encode is vectorized: a list with names preserved", {
  m <- llm(qwen_model())
  on.exit(close(m), add = TRUE)

  x <- c(greeting = "buongiorno", farewell = "arrivederci")
  out <- llm_tokens(m, x)
  expect_type(out, "list")
  expect_length(out, 2L)
  expect_identical(names(out), c("greeting", "farewell"))
  expect_true(all(vapply(out, function(v) all(v >= 1L), logical(1))))
  # Each element round-trips.
  expect_identical(llm_tokens(m, out$greeting, decode = TRUE), "buongiorno")
})

test_that("decode rejects an id outside the vocabulary (classed, not a crash)", {
  m <- llm(qwen_model())
  on.exit(close(m), add = TRUE)

  huge <- m$.vocab_size + 100L
  expect_error(llm_tokens(m, huge, decode = TRUE), class = "relm_error_tokenize")
})
