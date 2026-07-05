# rebirth (development version)

## rebirth 0.0.0.9000

* `llm_generate()` continues one or more prompts (WP2). `chat = TRUE` applies the
  model's own chat template; `temperature = 0` decodes greedily (deterministic),
  otherwise it uses temperature + nucleus (top-p) sampling drawn on the CPU from
  a seeded generator, so a run is reproducible. `seed = NULL` draws and records a
  seed, always returned as `attr(result, "seed")`. `stop` ends generation at a
  string; an over-long prompt raises `rebirth_error_context_overflow`. Greedy
  decoding is validated token-for-token against an independent numpy reference on
  a synthetic model.
* `llm_tokens()` converts between text and the model's tokens (WP2): encoding
  returns a named integer vector of 1-based token ids (names are the token
  pieces), decoding reconstructs the string. UTF-8 correct, including accented
  text that spans token boundaries. Vectorized over inputs; a model without a
  tokenizer or an out-of-range id raises `rebirth_error_tokenize`.
* `llm()` loads a local GGUF model and returns an `llm` handle, with
  `print()`, `summary()`, and `close()` methods (WP1). Bad requests (missing,
  unreadable, or corrupt files; an unavailable backend) are reported as classed
  conditions (`rebirth_error_model_load`, `rebirth_error_backend`,
  `rebirth_error_closed`, `rebirth_error_internal`) with actionable messages,
  never a crash. `close()` frees native memory deterministically; a
  garbage-collection finalizer is the safety net. Loading real models and the
  metadata shown by `summary()` are validated on local hardware (no model ships
  in the package yet).
* Repository bootstrap (WP0): the R package scaffold (extendr toolchain, no
  exported functions yet), the `rust/` Cargo workspace with empty-but-compiling
  `rebirth-ffi` and `rebirth-llm` crates, dual MIT/Apache-2.0 licensing, a
  trademark policy, and continuous-integration workflows (`R CMD check`; cargo
  test/clippy/fmt). No user-facing functionality yet.
