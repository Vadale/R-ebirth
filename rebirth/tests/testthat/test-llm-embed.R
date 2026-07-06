# WP3: llm_embed(). Argument validation happens in R before the engine, so it runs
# in CI on the in-repo synthetic model (a valid open handle even though it has no
# tokenizer). Actual text embedding needs a real tokenizer, so the value/shape
# checks are [MODEL]-gated on REBIRTH_TEST_MODEL_QWEN (Step 6 / local hardware).

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

test_that("llm_embed() rejects a non-llm handle", {
  expect_error(llm_embed(42, "hi"), class = "rebirth_error_argument")
})

test_that("llm_embed() validates its arguments", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  expect_error(llm_embed(m, character(0)), class = "rebirth_error_argument")
  expect_error(llm_embed(m, NA_character_), class = "rebirth_error_argument")
  expect_error(llm_embed(m, 42), class = "rebirth_error_argument")
  expect_error(llm_embed(m, c("a", NA)), class = "rebirth_error_argument")
  expect_error(llm_embed(m, "hi", normalize = NA), class = "rebirth_error_argument")
  expect_error(llm_embed(m, "hi", normalize = "yes"), class = "rebirth_error_argument")
  expect_error(
    llm_embed(m, "hi", normalize = c(TRUE, FALSE)),
    class = "rebirth_error_argument"
  )

  # A bad `pooling` is a programming error caught by match.arg (a base error, the
  # established idiom for a closed enum in this package), not a data condition.
  expect_error(llm_embed(m, "hi", pooling = "cls"))

  # The offending argument is named in a structured field.
  cnd <- tryCatch(llm_embed(m, 42), condition = function(c) c)
  expect_identical(cnd$argument, "x")
})

test_that("llm_embed() on a tokenizer-less model raises rebirth_error_tokenize", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  # Arguments are valid; the synthetic model simply has no tokenizer, so the text
  # embedding path reports it as a classed condition rather than crashing.
  expect_error(llm_embed(m, "hello"), class = "rebirth_error_tokenize")
})

test_that("llm_embed() rejects a closed handle", {
  m <- llm(synthetic_model_path())
  close(m)
  expect_error(llm_embed(m, "hi"), class = "rebirth_error_closed")
})

# --- semantic-similarity fixture integrity (no model; runs in CI) ------------

# The committed embed-similarity.csv drives the [MODEL] ranking acceptance test.
# This guard runs in CI (no model) so a corrupted or mis-edited fixture is caught
# early: the ranking property needs >= 2 topics, >= 2 sentences per topic, and no
# empty/duplicate sentences (a duplicate would force a within-pair cosine of ~1
# and silently rig the ranking).
test_that("the semantic-similarity fixture is well-formed and topic-separated", {
  fx <- read.csv(
    testthat::test_path("fixtures", "embed-similarity.csv"),
    stringsAsFactors = FALSE
  )
  expect_named(fx, c("group", "sentence"))
  expect_false(anyNA(fx))
  expect_true(all(nzchar(trimws(fx$sentence))))
  expect_identical(anyDuplicated(fx$sentence), 0L)
  per_topic <- table(fx$group)
  expect_gte(length(per_topic), 2L) # at least two topics to contrast
  expect_true(all(per_topic >= 2L)) # each topic needs at least one within-pair
})

# --- [MODEL] real-model embedding (Qwen: tokenizer + n_embd = 896) -----------

test_that("embedding dimensions match the model card", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  e <- llm_embed(m, "hello")
  expect_true(is.matrix(e))
  expect_identical(nrow(e), 1L)
  expect_identical(ncol(e), m$hidden_size)
  expect_identical(m$hidden_size, 896L) # Qwen2.5-0.5B model card
})

test_that("embedding is vectorized and preserves names as row names", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  x <- c(a = "cats and dogs", b = "domestic pets", c = "quantum chromodynamics")
  e <- llm_embed(m, x)
  expect_identical(nrow(e), 3L)
  expect_identical(rownames(e), c("a", "b", "c"))
  # Unnamed input falls back to the input positions as characters.
  u <- llm_embed(m, unname(x))
  expect_identical(rownames(u), c("1", "2", "3"))
})

test_that("normalize = TRUE yields unit rows; FALSE does not (no silent change)", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  x <- c("The cat slept on the sofa.", "Quarks feel the strong force.")
  normed <- llm_embed(m, x, pooling = "mean", normalize = TRUE)
  raw <- llm_embed(m, x, pooling = "mean", normalize = FALSE)
  expect_equal(sqrt(rowSums(normed^2)), c(1, 1), tolerance = 1e-5)
  # The unnormalized rows are (in general) not unit vectors.
  expect_false(isTRUE(all.equal(sqrt(rowSums(raw^2)), c(1, 1), tolerance = 1e-3)))
})

test_that("pooling = \"model\" on a generative model is a clean embed error", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  # Qwen2.5 defines no pooling, so \"model\" must ask for mean/last, not crash.
  expect_error(llm_embed(m, "hello", pooling = "model"), class = "rebirth_error_embed")
})

test_that("related sentence pairs rank above unrelated ones (semantic similarity)", {
  # ROADMAP Section 5 WP3 acceptance criterion. On a real model, mean-pooled unit
  # embeddings of topically-related sentences must be more cosine-similar to each
  # other than to sentences from a different topic. The fixture is committed and
  # separated by construction (pets / space / cooking, no shared salient words
  # across groups), and the assertion is a *ranking*, not a tuned threshold -- so
  # it catches an embedding path that returns constant / near-constant rows, pools
  # the wrong axis, scrambles row order, or ignores the input text: defects the
  # synthetic golden (exact values, one model) cannot reveal about topic geometry.
  # Mean pooling is used because it is steadier than last-token pooling on a
  # generative decoder like Qwen2.5-0.5B.
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)

  fx <- read.csv(
    testthat::test_path("fixtures", "embed-similarity.csv"),
    stringsAsFactors = FALSE
  )
  e <- llm_embed(m, fx$sentence, pooling = "mean", normalize = TRUE)
  expect_identical(nrow(e), nrow(fx))

  # Rows are L2-normalized, so a row dot product IS cosine similarity. Assert that
  # precondition before reading the Gram matrix as cosines (guards against a row
  # dot product silently not being a cosine).
  expect_true(all(abs(sqrt(rowSums(e^2)) - 1) < 1e-5))

  cos <- e %*% t(e) # cos[i, j] = cosine(row i, row j)
  same_topic <- outer(fx$group, fx$group, "==")
  pair <- upper.tri(cos) # each unordered pair once, diagonal excluded

  within <- cos[pair & same_topic] # related pairs
  cross <- cos[pair & !same_topic] # unrelated pairs
  # The split must cover every pair exactly once and leave neither side empty.
  expect_gt(length(within), 0L)
  expect_gt(length(cross), 0L)
  expect_identical(length(within) + length(cross), sum(pair))

  # Diagnostic floor (robust): topics separate on average. An embedding that
  # ignored the text or returned near-constant rows fails here first, telling the
  # strict check below apart from a genuinely broken embedding path.
  expect_gt(mean(within), mean(cross))

  # Acceptance property (strict): the weakest related pair still beats the
  # strongest unrelated pair. expect_gt prints both operands on failure, so a
  # borderline run shows its margin.
  expect_gt(min(within), max(cross))
})
