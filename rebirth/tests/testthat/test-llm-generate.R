# WP2: llm_generate(). Argument validation happens in R before the engine, so it
# runs in CI on the in-repo synthetic model (which is a valid open handle even
# though it has no tokenizer). Actual text generation needs a real tokenizer and
# chat template, so it is [MODEL]-gated on REBIRTH_TEST_MODEL_QWEN.

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

test_that("llm_generate() rejects a non-llm handle", {
  expect_error(llm_generate(42, "hi"), class = "rebirth_error_argument")
})

test_that("llm_generate() validates its arguments", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  expect_error(llm_generate(m, character(0)), class = "rebirth_error_argument")
  expect_error(llm_generate(m, NA_character_), class = "rebirth_error_argument")
  expect_error(llm_generate(m, 42), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", max_tokens = 0), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", max_tokens = 1.5), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", max_tokens = c(1L, 2L)), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", temperature = -1), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", temperature = NA_real_), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", top_p = 0), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", top_p = 1.5), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", chat = NA), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", chat = "yes"), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", stop = 42), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", stop = NA_character_), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", seed = -1), class = "rebirth_error_argument")
  expect_error(llm_generate(m, "hi", seed = 1.5), class = "rebirth_error_argument")

  # the offending argument is named in a structured field
  cnd <- tryCatch(llm_generate(m, "hi", max_tokens = 0), condition = function(c) c)
  expect_identical(cnd$argument, "max_tokens")
})

test_that("llm_generate() on a tokenizer-less model raises rebirth_error_tokenize", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  # Arguments are valid; the synthetic model simply has no tokenizer, so the
  # engine reports it as a classed condition rather than crashing.
  expect_error(
    llm_generate(m, "hello", max_tokens = 4, chat = FALSE),
    class = "rebirth_error_tokenize"
  )
})

test_that("llm_generate() rejects a closed handle", {
  m <- llm(synthetic_model_path())
  close(m)
  expect_error(llm_generate(m, "hi"), class = "rebirth_error_closed")
})

# --- [MODEL] real-model generation (Qwen: tokenizer + chatml template) -------

test_that("greedy generation is deterministic", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  a <- llm_generate(m, "The capital of France is", max_tokens = 8, temperature = 0, chat = FALSE)
  b <- llm_generate(m, "The capital of France is", max_tokens = 8, temperature = 0, chat = FALSE)
  expect_type(a, "character")
  expect_length(a, 1L)
  expect_identical(a[[1]], b[[1]])
  expect_true(nzchar(a[[1]]))
})

test_that("a seed reproduces a sampled run and is attached to the result", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  r1 <- llm_generate(m, "Give me a word:", max_tokens = 6, temperature = 0.8, seed = 123)
  expect_identical(attr(r1, "seed"), 123)
  r2 <- llm_generate(m, "Give me a word:", max_tokens = 6, temperature = 0.8, seed = 123)
  expect_identical(r1[[1]], r2[[1]])
  # seed = NULL still records a drawn seed
  r3 <- llm_generate(m, "Give me a word:", max_tokens = 6, temperature = 0.8)
  expect_true(is.numeric(attr(r3, "seed")))
})

test_that("generation is vectorized over prompt and preserves names", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  prompts <- c(a = "One plus one is", b = "The sky is")
  out <- llm_generate(m, prompts, max_tokens = 4, temperature = 0)
  expect_length(out, 2L)
  expect_identical(names(out), c("a", "b"))
})

test_that("chat = TRUE differs from raw completion", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  chatted <- llm_generate(m, "Say hello.", max_tokens = 16, temperature = 0, chat = TRUE)
  raw <- llm_generate(m, "Say hello.", max_tokens = 16, temperature = 0, chat = FALSE)
  expect_false(identical(chatted[[1]], raw[[1]]))
})

test_that("a stop string truncates the output before it", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  prompt <- "Recipe: mix flour and"
  full <- llm_generate(m, prompt, max_tokens = 20, temperature = 0, chat = FALSE)[[1]]
  skip_if(nchar(full) < 6, "greedy output too short to exercise a stop string")
  # A fragment guaranteed to appear (greedy is deterministic) stops generation.
  frag <- substr(full, 3L, 5L)
  stopped <- llm_generate(
    m, prompt,
    max_tokens = 20, temperature = 0, chat = FALSE, stop = frag
  )[[1]]
  expect_false(grepl(frag, stopped, fixed = TRUE))
  expect_lt(nchar(stopped), nchar(full))
})

test_that("a prompt longer than the batch size still generates (chunked decode)", {
  m <- llm(qwen_model_path(), context_length = 64L)
  on.exit(close(m), add = TRUE)
  # llama enlarges n_ctx but keeps n_batch small, so a mid-size prompt exceeds one
  # batch yet fits the window: it must be decoded in chunks, not crash.
  mid <- paste(rep("data", 120L), collapse = " ")
  out <- llm_generate(m, mid, max_tokens = 3, temperature = 0, chat = FALSE)
  expect_type(out, "character")
  expect_true(nzchar(out[[1]]))
})

test_that("an over-long prompt raises rebirth_error_context_overflow", {
  m <- llm(qwen_model_path(), context_length = 64L)
  on.exit(close(m), add = TRUE)
  # llama may enlarge a tiny requested context, so size the prompt against the
  # actual window (each "word" is at least one token) to guarantee an overflow.
  long <- paste(rep("word", m$context_length + 50L), collapse = " ")
  expect_error(
    llm_generate(m, long, max_tokens = 4, chat = FALSE),
    class = "rebirth_error_context_overflow"
  )
})

# --- [MODEL] Gemma 4 chat-template fallback (WP7.5a / D-021) -----------------

test_that("chat = TRUE works on a Gemma 4 model via the arch template fallback [MODEL]", {
  # D-021: Gemma 4's embedded Jinja chat template is not detected by b9726's
  # applier (its string lacks the `<start_of_turn>` literal the detector keys on),
  # so chat = TRUE used to fail with `llama_chat_apply_template failed (-1)`. The
  # resolver now falls back to the "gemma" builtin for a gemma-arch model. Runs
  # only on the founder's Mac with a text-only Gemma 4 GGUF (REBIRTH_TEST_MODEL_GEMMA4).
  m <- llm(gemma4_model_path())
  on.exit(close(m), add = TRUE)
  skip_if_not(identical(m$architecture, "gemma4"), "model is not a gemma4 GGUF")

  out <- llm_generate(m, "The capital of France is", max_tokens = 8, temperature = 0, chat = TRUE)
  expect_type(out, "character")
  expect_length(out, 1L)
  # A coherent, non-empty answer: chat no longer errors, and the fallback template
  # produced a real continuation.
  expect_true(nzchar(out[[1]]))

  # Chat formatting differs from a raw completion (evidence the template applied).
  raw <- llm_generate(m, "The capital of France is", max_tokens = 8, temperature = 0, chat = FALSE)
  expect_false(identical(out[[1]], raw[[1]]))
})
