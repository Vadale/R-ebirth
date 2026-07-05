# A hand-built `llm` object with metadata set by hand and no real native
# pointer, so print/summary/close *logic* can be tested without a model file
# (the real-model value checks are WP1 Step 8, env-gated). Mirrors new_llm()'s
# shape but skips the boundary and the finalizer.
stub_llm <- function(closed = FALSE, interventions = list()) {
  state <- new.env(parent = emptyenv())
  state$closed <- closed
  state$ptr <- NULL
  structure(
    list(
      ptr = NULL,
      state = state,
      path = "/models/Qwen2.5-0.5B-Instruct-Q8_0.gguf",
      architecture = "qwen2",
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
