# WP (Phase 2): llm_logits(). Argument validation happens in R before the engine,
# so it runs in CI on the in-repo synthetic model (a valid open handle even though
# it has no tokenizer). The actual next-token distribution needs a real tokenizer,
# so the shape/value checks are [MODEL]-gated on REBIRTH_TEST_MODEL_QWEN. The
# numeric top-k + softmax extraction is gated exactly against the numpy oracle in
# the Rust suite (tests/synthetic_logits.rs), where the synthetic logits are exact.

synthetic_model_path <- function() {
  p <- testthat::test_path("fixtures", "synthetic-llama-2l.gguf")
  skip_if_not(file.exists(p), "synthetic GGUF fixture is missing")
  p
}

qwen_model_path <- function() {
  p <- path.expand(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "REBIRTH_TEST_MODEL_QWEN is not set to an existing GGUF file"
  )
  p
}

# --- argument validation (before the engine; runs in CI) --------------------

test_that("llm_logits() rejects a non-llm handle", {
  expect_error(llm_logits(42, "hi"), class = "rebirth_error_argument")
  cnd <- tryCatch(llm_logits(42, "hi"), condition = function(c) c)
  expect_identical(cnd$argument, "m")
})

test_that("llm_logits() validates prompt and top before the engine", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  # prompt: non-empty character vector without NA.
  expect_error(llm_logits(m, character(0)), class = "rebirth_error_argument")
  expect_error(llm_logits(m, NA_character_), class = "rebirth_error_argument")
  expect_error(llm_logits(m, 42), class = "rebirth_error_argument")
  expect_error(llm_logits(m, c("a", NA)), class = "rebirth_error_argument")

  # top: a single positive integer.
  expect_error(llm_logits(m, "hi", top = 0), class = "rebirth_error_argument")
  expect_error(llm_logits(m, "hi", top = -1), class = "rebirth_error_argument")
  expect_error(llm_logits(m, "hi", top = 2.5), class = "rebirth_error_argument")
  expect_error(llm_logits(m, "hi", top = c(1L, 2L)), class = "rebirth_error_argument")
  expect_error(llm_logits(m, "hi", top = NA_integer_), class = "rebirth_error_argument")
  expect_error(llm_logits(m, "hi", top = "5"), class = "rebirth_error_argument")

  # The offending argument is named in a structured field.
  cnd <- tryCatch(llm_logits(m, "hi", top = 0), condition = function(c) c)
  expect_identical(cnd$argument, "top")
})

test_that("llm_logits() on a tokenizer-less model raises rebirth_error_tokenize", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  # Arguments are valid; the synthetic model simply has no tokenizer, so the text
  # path reports it as a classed condition rather than crashing.
  expect_error(llm_logits(m, "hello"), class = "rebirth_error_tokenize")
})

test_that("llm_logits() rejects a closed handle", {
  m <- llm(synthetic_model_path())
  close(m)
  expect_error(llm_logits(m, "hi"), class = "rebirth_error_closed")
})

# --- [MODEL] real-model distribution (Qwen: tokenizer + real logits) ---------

test_that("llm_logits() returns the documented schema, top rows per prompt", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)

  top <- 12L
  df <- llm_logits(m, "The capital of France is", top = top)

  expect_s3_class(df, "data.frame")
  expect_identical(
    names(df),
    c("prompt_id", "rank", "token_id", "token", "logit", "prob")
  )
  expect_identical(nrow(df), top)
  # Column types per API-GRAMMAR section 4.
  expect_type(df$prompt_id, "integer")
  expect_type(df$rank, "integer")
  expect_type(df$token_id, "integer")
  expect_type(df$token, "character")
  expect_type(df$logit, "double")
  expect_type(df$prob, "double")

  # A single prompt: prompt_id all 1, ranks exactly 1..top.
  expect_true(all(df$prompt_id == 1L))
  expect_identical(df$rank, seq_len(top))
  # Token ids are 1-based (like llm_tokens); pieces are present.
  expect_true(all(df$token_id >= 1L))
  expect_false(anyNA(df$token))
})

test_that("llm_logits() ranks by descending logit with a valid probability head", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)

  df <- llm_logits(m, "Water boils at a temperature of", top = 20L)

  # rank 1 = highest logit: logit and prob are non-increasing down the ranks.
  expect_false(is.unsorted(rev(df$logit)))
  expect_false(is.unsorted(rev(df$prob)))
  # Probabilities are a valid distribution head: each in (0, 1], summing to <= 1
  # (softmax over the FULL vocabulary, so the top-k head excludes the tail mass).
  expect_true(all(df$prob > 0 & df$prob <= 1))
  expect_lte(sum(df$prob), 1 + 1e-8)
  # rank-1 prob is the largest, and strictly positive.
  expect_identical(which.max(df$prob), 1L)
})

test_that("llm_logits() is deterministic for a fixed prompt", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  a <- llm_logits(m, "Once upon a time", top = 10L)
  b <- llm_logits(m, "Once upon a time", top = 10L)
  expect_identical(a, b)
})

test_that("llm_logits() vectorizes over prompt with per-prompt ranks", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)

  top <- 8L
  prompts <- c("The sky is", "Two plus two equals")
  df <- llm_logits(m, prompts, top = top)

  expect_identical(nrow(df), top * length(prompts))
  # prompt_id blocks the input in order; ranks reset to 1..top within each.
  expect_identical(df$prompt_id, rep(seq_along(prompts), each = top))
  expect_identical(df$rank, rep(seq_len(top), times = length(prompts)))

  # Each prompt's slice is independently ranked (logit non-increasing per block).
  for (i in seq_along(prompts)) {
    block <- df[df$prompt_id == i, ]
    expect_identical(block$rank, seq_len(top))
    expect_false(is.unsorted(rev(block$logit)))
  }
  # A length-1 prompt and the corresponding block of a vectorized call agree
  # (vectorization is per-prompt independent, not context-carrying).
  single <- llm_logits(m, prompts[[1]], top = top)
  expect_equal(single$token_id, df$token_id[df$prompt_id == 1L])
  expect_equal(single$logit, df$logit[df$prompt_id == 1L])
})
