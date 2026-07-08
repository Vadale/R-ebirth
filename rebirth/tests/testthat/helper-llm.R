# A hand-built `llm` object with metadata set by hand and no real native
# pointer, so print/summary/close *logic* can be tested without a model file
# (the real-model value checks are WP1 Step 8, env-gated). Mirrors new_llm()'s
# shape but skips the boundary and the finalizer.
stub_llm <- function(closed = FALSE, interventions = list(), architecture = "qwen2") {
  state <- new.env(parent = emptyenv())
  state$closed <- closed
  state$ptr <- NULL
  structure(
    list(
      ptr = NULL,
      state = state,
      path = "/models/Qwen2.5-0.5B-Instruct-Q8_0.gguf",
      architecture = architecture,
      parameters = 494032768,
      quantization = "Q8_0",
      layers = 24L,
      hidden_size = 896L,
      context_length = 4096L,
      backend = "metal",
      interventions = interventions,
      .context_train = 32768L,
      .size_bytes = 531000000,
      .vocab_size = 151936L,
      .description = "qwen2 0.5B Q8_0"
    ),
    class = "llm"
  )
}

# [MODEL] model-path helpers for the WP7.5a modern-model families. Each is gated
# on its own environment variable pointing at a local text-only instruct GGUF, so
# these tests run only on the founder's Mac (Metal) and skip in CI/CRAN, which have
# no such model. (`qwen_model_path()`/`synthetic_model_path()` live in
# test-llm-generate.R; defining these here keeps them available to every test file.)
gemma4_model_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MODEL_GEMMA4"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "RELM_TEST_MODEL_GEMMA4 is not set to an existing GGUF file"
  )
  p
}

qwen3_model_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MODEL_QWEN3"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "RELM_TEST_MODEL_QWEN3 is not set to an existing GGUF file"
  )
  p
}

qwen35_model_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MODEL_QWEN35"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "RELM_TEST_MODEL_QWEN35 is not set to an existing GGUF file"
  )
  p
}

# An open `llm` backed by a real but already-empty native handle
# (rebirth_selftest_new_handle): it drives new_llm()/close()/the closed tag with
# no model file, so the native free is a safe no-op. The metadata values are
# placeholders — the close tests assert on lifecycle, not on metadata.
empty_handle_llm <- function() {
  ptr <- relm:::rebirth_selftest_new_handle()
  payload <- list(
    ok = TRUE, ptr = ptr, architecture = "x", parameters = 1,
    quantization = "q", layers = 1L, hidden_size = 1L, context_length = 1L,
    backend = "cpu", context_train = 1L, size_bytes = 1, vocab_size = 1L,
    description = ""
  )
  relm:::new_llm(payload, "x.gguf")
}
