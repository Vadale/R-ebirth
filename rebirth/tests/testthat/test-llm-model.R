# WP1 Step 8: real-model acceptance. [MODEL]-gated on REBIRTH_TEST_MODEL_QWEN
# pointing at a Qwen2.5-0.5B-Instruct Q8_0 GGUF. Skipped in CI (no model file on
# the runners) and on CRAN. Values below are that model's published card.

qwen_model_path <- function() {
  p <- path.expand(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "REBIRTH_TEST_MODEL_QWEN is not set to an existing GGUF file"
  )
  p
}

test_that("llm() loads a real Qwen2.5-0.5B and reports card-accurate metadata", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)

  expect_s3_class(m, "llm")
  expect_identical(m$architecture, "qwen2")
  expect_identical(m$layers, 24L)
  expect_identical(m$hidden_size, 896L)
  expect_identical(m$quantization, "Q8_0")
  expect_identical(m$context_length, 4096L) # the requested default window
  expect_identical(m[[".context_train"]], 32768L) # Qwen2.5 native window
  expect_identical(m[[".vocab_size"]], 151936L)
  expect_true(nzchar(m$backend) && m$backend %in% c("metal", "cuda", "cpu"))
  # 0.5B model: ~0.63e9 total parameters, ~0.6-0.7 GB on disk in Q8_0.
  expect_gt(m$parameters, 5e8)
  expect_lt(m$parameters, 8e8)
  expect_gt(m[[".size_bytes"]], 5e8)
})

test_that("llm() honours a non-default context_length on a real model", {
  m <- llm(qwen_model_path(), context_length = 2048L)
  on.exit(close(m), add = TRUE)
  expect_identical(m$context_length, 2048L)
})

test_that("summary() on a real model carries tokenizer and memory information", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  s <- summary(m)
  expect_s3_class(s, "summary.llm")
  expect_identical(s$vocab_size, 151936L)
  expect_gt(s$memory_footprint, 5e8)
})

test_that("repeated load/unload of a real model does not leak native memory", {
  skip_on_cran()
  path <- qwen_model_path()

  rss_kb <- function() {
    out <- suppressWarnings(
      system2("ps", c("-o", "rss=", "-p", Sys.getpid()), stdout = TRUE, stderr = FALSE)
    )
    as.numeric(trimws(paste(out, collapse = "")))
  }

  # Warm up: the first load maps the file and initializes the backend, so the
  # baseline is taken after native one-time costs are already resident.
  close(llm(path))
  invisible(gc())
  before <- rss_kb()
  skip_if(is.na(before), "RSS is unavailable on this platform")

  for (i in seq_len(30L)) {
    close(llm(path))
  }
  invisible(gc())
  after <- rss_kb()

  # A genuine per-load leak of a ~0.6 GB model over 30 cycles would be many
  # gigabytes; the bound leaves generous slack for allocator retention.
  expect_lt(after - before, 300L * 1024L) # < 300 MB growth
})
