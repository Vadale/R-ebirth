# rebirth (development version)

## rebirth 0.0.0.9000

* `llm_trace()` captures a model's internal activations over the prompt tokens
  (WP4, observation core): a long-format `rebirth_trace` `data.frame` with columns
  `prompt_id`, `token_pos`, `token`, `layer`, `component`, `neuron`, `value`. The
  filters `layers`, `positions` (`"last"`/`"all"`/explicit), and `components`
  (`"residual"`, `"attn_out"`, `"mlp_out"`) select what is captured; the
  memory-safe defaults capture little (`positions = "last"`,
  `components = "residual"`). Tracing uses a dedicated, transient context tapped via
  llama.cpp's scheduler eval callback, so normal generation carries no overhead
  (zero vendored patch, D-012). A capture whose estimated size exceeds the budget
  (`min(2 GB, 20% RAM)`, `options(rebirth.trace_budget=)`) either streams to disk
  when `spill = TRUE` (the default) or, with `spill = FALSE`, raises
  `rebirth_error_oom` — carrying `estimate_bytes` — *before* any allocation. A
  spilled trace writes an Arrow-IPC file under a per-session cache directory
  (removed when the session ends) and loads lazily: `print()`/`summary()` never
  read it, and `as.matrix(tr, layer, component)` reads only the requested slice; a
  reopened file that no longer matches the trace is rejected (D-013, `nanoarrow`).
  `print()`/`summary()` digest the trace without dumping it;
  `as.matrix(tr, layer, component)` extracts one slice as a neuron-wide numeric
  matrix. Per-layer activations are validated value-for-value against an
  independent numpy reference on a synthetic model, and a spilled capture is
  checked to read back identically to the in-memory one.

* `llm_embed()` encodes a character vector into a base numeric `matrix`, one row
  per input by the model's embedding size (WP3). `pooling` chooses how per-token
  vectors are reduced — `"mean"`, `"last"`, or `"model"` (the model's own pooling
  when the GGUF defines one; a generative model such as Qwen2.5 defines none and
  raises `rebirth_error_embed` asking for `"mean"`/`"last"`). `normalize = TRUE`
  (default) L2-normalizes each row to a unit vector so dot products are cosine
  similarities — validated and explicit, never silent. Row names follow `names(x)`
  (else the input positions). The per-token hidden states, each pooling mode, and
  the normalize path are validated value-for-value against an independent numpy
  reference on a synthetic model.

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
