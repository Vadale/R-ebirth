# WP1 Step 5: print/summary formatting against a stubbed handle (metadata set by
# hand). Verifying the values against real model cards is Step 8 ([MODEL]).

test_that("print.llm renders one screen of metadata and returns invisibly", {
  m <- stub_llm()
  out <- capture.output(res <- print(m))
  expect_identical(res, m)

  expect_match(out[1], "Qwen2.5-0.5B-Instruct-Q8_0.gguf", fixed = TRUE)
  expect_true(any(grepl("architecture:\\s+qwen2", out)))
  expect_true(any(grepl("parameters:\\s+494 M", out)))
  expect_true(any(grepl("quantization:\\s+Q8_0", out)))
  expect_true(any(grepl("24 x 896", out)))
  expect_true(any(grepl("4096 tokens", out)))
  expect_true(any(grepl("backend:\\s+metal", out)))
  expect_true(any(grepl("interventions:\\s+0 active", out)))
})

test_that("print.llm reports the active-intervention count", {
  m <- stub_llm(interventions = list(a = 1, b = 2))
  out <- capture.output(print(m))
  expect_true(any(grepl("interventions:\\s+2 active", out)))
})

test_that("summary.llm returns a classed list with footprint and tokenizer info", {
  m <- stub_llm()
  s <- summary(m)
  expect_s3_class(s, "summary.llm")
  expect_type(s, "list")
  expect_identical(s$memory_footprint, m$.size_bytes)
  expect_identical(s$vocab_size, m$.vocab_size)
  expect_identical(s$context_train, m$.context_train)
  expect_identical(s$interventions, list())
})

test_that("print.summary.llm renders the richer view", {
  m <- stub_llm()
  s <- summary(m)
  out <- capture.output(res <- print(s))
  expect_identical(res, s)
  expect_match(out[1], "llm summary", fixed = TRUE)
  expect_true(any(grepl("memory:\\s+506\\.4 MB", out)))
  expect_true(any(grepl("vocabulary:\\s+151,936 tokens", out)))
  expect_true(any(grepl("trained: 32768", out)))
})

test_that("format helpers render human-readable magnitudes", {
  expect_identical(relm:::format_params(494032768), "494 M")
  expect_identical(relm:::format_params(1.5e9), "1.5 B")
  expect_identical(relm:::format_params(151936), "152 K")
  expect_match(relm:::format_bytes(531000000), "MB")
  expect_match(relm:::format_bytes(4.7e9), "GB")
  expect_identical(relm:::format_bytes(512), "512 B")
})

# Twin-pin (Hard rule 8f): format_bytes() (R) and human_bytes() (Rust) format the
# two halves of the OOM story -- the R-side predictive pre-check (trace.R) vs the
# engine's own message. The Rust twin asserts these exact same sentinels in
# rebirth-llm/src/error.rs (`human_bytes_twin_pins_the_r_format_bytes`); keeping the
# expected strings identical here means neither formula can drift without a failure.
test_that("format_bytes twin-pins the Rust human_bytes formula", {
  expect_identical(relm:::format_bytes(0), "0 B")
  expect_identical(relm:::format_bytes(512), "512 B")
  expect_identical(relm:::format_bytes(1023), "1023 B")
  expect_identical(relm:::format_bytes(1024), "1.0 KB")
  expect_identical(relm:::format_bytes(531000000), "506.4 MB")
  expect_identical(relm:::format_bytes(4400000000), "4.1 GB")
  expect_identical(relm:::format_bytes(5e12), "4.5 TB")
})
