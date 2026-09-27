# S1 / D-030. Argument gates run in every R CMD check without native inference.
# Schema compilation uses the in-repo tokenizer-less model: a schema condition
# proves rejection before tokenizer/decode, while a tokenize condition proves
# a supported request reached the engine. Generation tests use the existing
# [MODEL] RELM_TEST_MODEL_QWEN gate (local acceptance and model-enabled CI).

structured_test_schema <- paste0(
  '{"type":"object","properties":{"answer":',
  '{"type":"string","enum":["yes","no"]}},',
  '"required":["answer"],"additionalProperties":false}'
)

test_that("structured schema scalar errors identify the public argument", {
  m <- stub_llm()
  for (schema in list(1, list(type = "object"), character(), NA_character_, c("{}", "{}"))) {
    cnd <- tryCatch(llm_generate(m, "hi", schema = schema), error = identity)
    expect_s3_class(cnd, "relm_error_argument")
    expect_identical(cnd$argument, "schema")
  }
})

test_that("structured schema byte and Unicode gates produce schema conditions", {
  m <- stub_llm()
  bad_utf8 <- rawToChar(as.raw(c(0xc3, 0x28)))
  Encoding(bad_utf8) <- "UTF-8"
  for (schema in list(strrep(" ", 65537), bad_utf8)) {
    cnd <- tryCatch(llm_generate(m, "hi", schema = schema), error = identity)
    expect_s3_class(cnd, "relm_error_schema")
    expect_true(nzchar(cnd$reason))
    expect_identical(cnd$schema_path, "")
  }
  # Measure UTF-8 bytes, not decoded characters.
  cnd <- tryCatch(llm_generate(m, "hi", schema = strrep("\u00e9", 32769)), error = identity)
  expect_s3_class(cnd, "relm_error_schema")
})

test_that("structured prompt and token budgets fail before native copies", {
  m <- stub_llm()
  for (prompt in list(rep("hi", 129), strrep("a", 1048577),
                      rep(strrep("a", 1048576), 17), strrep("\u00e9", 524289))) {
    cnd <- tryCatch(llm_generate(m, prompt, schema = structured_test_schema), error = identity)
    expect_s3_class(cnd, "relm_error_argument")
    expect_identical(cnd$argument, "prompt")
  }
  cnd <- tryCatch(llm_generate(m, "hi", schema = structured_test_schema, max_tokens = 8193),
    error = identity)
  expect_s3_class(cnd, "relm_error_argument")
  expect_identical(cnd$argument, "max_tokens")
})

test_that("structured sampling rejects non-finite values and overflowing casts", {
  m <- stub_llm()
  for (argument in c("max_tokens", "temperature", "top_p", "seed")) {
    args <- list(m = m, prompt = "hi", schema = structured_test_schema)
    args[[argument]] <- 1 + 1i
    cnd <- tryCatch(do.call(llm_generate, args), error = identity)
    expect_s3_class(cnd, "relm_error_argument")
    expect_identical(cnd$argument, argument)
  }
  for (temperature in c(Inf, 2^128)) {
    cnd <- tryCatch(llm_generate(m, "hi", schema = structured_test_schema,
      temperature = temperature), error = identity)
    expect_s3_class(cnd, "relm_error_argument")
    expect_identical(cnd$argument, "temperature")
  }
  for (seed in c(Inf, 2^64)) {
    cnd <- tryCatch(llm_generate(m, "hi", schema = structured_test_schema, seed = seed),
      error = identity)
    expect_s3_class(cnd, "relm_error_argument")
    expect_identical(cnd$argument, "seed")
  }
})

test_that("structured requests reject stop strings and images before file or model checks", {
  m <- stub_llm()
  for (stop in list("END", "")) {
    cnd <- tryCatch(llm_generate(m, "hi", schema = structured_test_schema, stop = stop),
      error = identity)
    expect_s3_class(cnd, "relm_error_argument")
    expect_identical(cnd$argument, "stop")
  }
  # A nonexistent file and a text-only handle must still name the incompatible
  # public argument, rather than attempt image loading or report a projector error.
  cnd <- tryCatch(llm_generate(m, "<__media__>", schema = structured_test_schema,
    images = "not-an-image.png"), error = identity)
  expect_s3_class(cnd, "relm_error_argument")
  expect_identical(cnd$argument, "images")
})

test_that("malformed and unsupported schemas fail before tokenization", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  schemas <- c(
    "{", "{}", "schema.json",
    sub('"type":"object"', '"type":"object","type":"object"', structured_test_schema, fixed = TRUE),
    sub('"type":"object"', '"type":"object","description":"ignored?"', structured_test_schema, fixed = TRUE),
    sub('"enum":["yes","no"]', '"enum":["\\ud800"]', structured_test_schema, fixed = TRUE),
    sub('"type":"string"', '"type":["string","null"]', structured_test_schema, fixed = TRUE)
  )
  for (schema in schemas) {
    cnd <- tryCatch(llm_generate(m, "hello", chat = FALSE, schema = schema), error = identity)
    expect_s3_class(cnd, "relm_error_schema")
    expect_true(is.character(cnd$reason) && length(cnd$reason) == 1L && nzchar(cnd$reason))
    expect_true(is.character(cnd$schema_path) && length(cnd$schema_path) == 1L)
    expect_match(cnd$schema_path, "^(/|$)")
  }
})

test_that("valid structured bounds and empty collections reach tokenization", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  for (images in list(NULL, character(), list(), list(character()))) {
    expect_error(llm_generate(m, "hello", chat = FALSE, schema = structured_test_schema,
      stop = character(), images = images), class = "relm_error_tokenize")
  }
  expect_error(llm_generate(m, c("one", "two"), chat = FALSE, schema = structured_test_schema,
    images = list(character(), character())), class = "relm_error_tokenize")

  # Inclusive schema, prompt-count, per-prompt, total-input and token bounds.
  padded_schema <- paste0(structured_test_schema,
    strrep(" ", 65536 - nchar(structured_test_schema, "bytes")))
  prompts <- c(rep(strrep("a", 1048576), 16), rep("", 112))
  expect_error(llm_generate(m, prompts, chat = FALSE, max_tokens = 8192,
    schema = padded_schema), class = "relm_error_tokenize")
})

test_that("structured generation preserves names, scalar seeds and complete JSON [MODEL]", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  prompt <- 'Is R a programming language? Return an object with "answer" as yes or no.'
  prompts <- c(first = prompt, second = prompt)
  out <- llm_generate(m, prompts, schema = structured_test_schema,
    temperature = 0.8, max_tokens = 64, seed = 1729)
  expect_type(out, "character")
  expect_identical(names(out), names(prompts))
  expect_identical(attr(out, "seed"), 1729)
  # Independent fixed-record oracle: accepts arbitrary JSON whitespace but no
  # prose, duplicate/extra keys or partial object. No R JSON dependency needed.
  expect_true(all(grepl('^[[:space:]]*\\{[[:space:]]*"answer"[[:space:]]*:[[:space:]]*"(yes|no)"[[:space:]]*\\}[[:space:]]*$', out)))
  expect_identical(out[[1]], out[[2]])
  replay <- llm_generate(m, prompt, schema = structured_test_schema,
    temperature = 0.8, max_tokens = 64, seed = 1729)
  expect_identical(out[[1]], replay[[1]])
})

test_that("structured exhaustion carries bounded diagnostics and leaves the handle usable [MODEL]", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  prompt <- 'Return an object with "answer" as yes or no.'
  before <- llm_generate(m, "R is", chat = FALSE, temperature = 0, max_tokens = 6, seed = 7)
  cnd <- tryCatch(llm_generate(m, c(first = prompt, second = prompt),
    schema = structured_test_schema, max_tokens = 1, temperature = 0, seed = 42),
    error = identity)
  expect_s3_class(cnd, "relm_error_structured_output")
  expect_true(nzchar(cnd$reason))
  expect_equal(cnd$prompt_id, 1L)
  expect_equal(cnd$seed, 42)
  expect_equal(cnd$generated_tokens, 1L)
  expect_type(cnd$partial_bytes, "raw")
  expect_lte(length(cnd$partial_bytes), 65536)

  after <- llm_generate(m, "R is", chat = FALSE, temperature = 0, max_tokens = 6,
    seed = 7, schema = NULL)
  expect_identical(before, after)
  recovered <- llm_generate(m, prompt, schema = structured_test_schema,
    temperature = 0, max_tokens = 64, seed = 42)
  expect_true(grepl('"answer"', recovered[[1]], fixed = TRUE))
})

test_that("structured prompt ingestion retains chunked decoding [MODEL]", {
  m <- llm(qwen_model_path(), context_length = 64L)
  on.exit(close(m), add = TRUE)
  # As in the unconstrained regression, the engine enlarges this tiny n_ctx but
  # retains n_batch = 64. The prompt crosses a batch while fitting the context.
  prompt <- paste('Return a JSON object with "answer" as yes or no. Ignore this filler:',
    paste(rep("data", 120L), collapse = " "))
  out <- llm_generate(m, prompt, chat = TRUE, schema = structured_test_schema,
    max_tokens = 64, temperature = 0, seed = 1)
  expect_true(grepl('"answer"', out[[1]], fixed = TRUE))
  long <- paste(rep("word", m$context_length + 50L), collapse = " ")
  expect_error(llm_generate(m, long, chat = FALSE, schema = structured_test_schema,
    max_tokens = 64, seed = 1), class = "relm_error_context_overflow")
})
