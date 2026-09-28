# D-032 optional model acceptance. Runs manually on Mac Metal and in
# manual-spark.yaml on Linux CPU; ordinary CI never downloads this 4.38 GB model.
# Template bytes have independent author-template fixtures in the Rust suite.
test_that("Spark native generation and declared capabilities work [SPARK]", {
  path <- Sys.getenv("RELM_TEST_MODEL_SPARK")
  skip_if(!nzchar(path), "RELM_TEST_MODEL_SPARK not set (optional 4B acceptance)")
  expect_true(file.exists(path))
  m <- llm(path, context_length = 4096L,
    backend = Sys.getenv("RELM_TEST_SPARK_BACKEND", "auto"))
  on.exit(close(m), add = TRUE)
  expect_identical(m$architecture, "spark2_5")
  expect_identical(m$layers, 36L)
  expect_identical(m$hidden_size, 2560L)
  expect_identical(m$context_length, 4096L)

  text <- "Caf\u00e9: \u20ac7; Tokyo \u6771\u4eac."
  expect_identical(llm_tokens(m, llm_tokens(m, text), decode = TRUE), text)
  # The author's config pins engine BOS/EOS to 0/1; R exposes 1-based ids.
  expect_identical(unname(llm_tokens(m, "<\uff5cstart\u2581of\u2581sentence\uff5c>")), 1L)
  expect_identical(unname(llm_tokens(m, "<\uff5cend\u2581of\u2581sentence\uff5c>")), 2L)

  free <- llm_generate(m, "Reply with a short greeting.", max_tokens = 96L,
    temperature = 0, seed = 41L)
  expect_true(nzchar(free[[1L]]))
  expect_true(validUTF8(free[[1L]]))
  expect_identical(attr(free, "seed"), 41)

  schema <- paste0('{"type":"object","properties":',
    '{"answer":{"type":"string","enum":["ok"]},',
    '"count":{"type":"integer","minimum":7,"maximum":7}},',
    '"required":["answer","count"],"additionalProperties":false}')
  out <- llm_generate(m, c(first = "Return the requested JSON.", second = "Produce JSON."),
    schema = schema, max_tokens = 64L, temperature = 0, seed = 42L)
  expect_identical(names(out), c("first", "second"))
  expect_true(all(gsub("[[:space:]]", "", out) == '{"answer":"ok","count":7}'))
  expect_false(any(grepl("think", out, fixed = TRUE)))

  # Same prompt-ingest chokepoint beyond b10828's default n_batch=2048.
  long <- paste(rep("test", 2100L), collapse = " ")
  expect_gt(length(llm_tokens(m, long)), 2048L)
  empty_schema <- '{"type":"object","properties":{},"required":[],"additionalProperties":false}'
  bounded <- llm_generate(m, long, schema = empty_schema,
    max_tokens = 16L, temperature = 0, seed = 43L)
  expect_identical(gsub("[[:space:]]", "", bounded[[1L]]), "{}")
  expect_error(llm_generate(m, paste(rep("test", 4200L), collapse = " "),
    schema = empty_schema, max_tokens = 16L), class = "relm_error_context_overflow")

  # Spark component semantics have not passed an independent activation oracle.
  # In particular its upstream attn_out is pre-projection, unlike D-014.
  for (component in c("residual", "attn_out", "mlp_out")) {
    expect_error(llm_trace(m, "hello", layers = 1L, components = component),
      class = "relm_error_trace")
  }

  prompt <- "The capital of France is"
  baseline <- llm_logits(m, prompt, top = 4L)
  expect_true(all(is.finite(baseline$logit)))
  # Independent algebraic invariant: zeroing the entire final residual produces
  # zero logits through Spark's bias-free RMSNorm and tied output projection.
  a <- llm_ablate(m, layer = m$layers, neurons = seq_len(m$hidden_size), value = 0)
  ablated <- tryCatch(llm_logits(a, prompt, top = 4L), finally = close(a))
  expect_equal(ablated$logit, rep(0, 4L), tolerance = 0)
  expect_false(identical(baseline, ablated))
  s <- llm_steer(m, layer = 2L, direction = rep(1, m$hidden_size), coef = 3)
  steered <- tryCatch(llm_logits(s, prompt, top = 4L), finally = close(s))
  expect_false(identical(baseline, steered))
  expect_identical(llm_logits(m, prompt, top = 4L), baseline)
})
