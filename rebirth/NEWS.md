# relm (development version)

Development toward the vision/multimodal release (v0.2.0, Phase 11, D-026).

* **Image input (T1).** `llm()` gains `projector =`: point it at a
  vision-language model's companion **mmproj GGUF** to enable image input
  (the projector is bound to the loaded model at load time; a projector whose
  embedding width does not match the model is refused with `relm_error_image`
  naming both sizes). `llm_generate()` gains `images =`: a list parallel to
  `prompt` (or a bare character vector for a single prompt) of image **file
  paths**, inserted before each prompt's text. Exactly three formats are
  accepted — **JPEG, PNG, BMP** — enforced on the file bytes in Rust before
  any decode; anything else (GIF and audio included) raises `relm_error_image`.
  Pre-decode limits: 64 MB per file by default
  (`options(relm.image_max_bytes = )` to change, hard ceiling 2147483647
  bytes), dimensions 1–16384 px per side, at most 33554432 total pixels.
  `print()` shows the projector on a vision handle; steered/ablated handles
  derived from a vision handle keep accepting images. Dev-verified with
  Qwen2-VL-2B-Instruct (Apache-2.0); the pinned registry aliases arrive with
  the v0.2.0 release work. Text-only calls are byte-identical to before.

# relm 0.1.0

First public release. Local large language models as base-R objects: model
loading and tokenization, text generation, next-token distributions, text
embeddings, and a mechanistic-interpretability toolkit -- activation tracing,
steering, and ablation -- all returning plain `data.frame`s and `matrix`es on
stock R over a vendored, patched llama.cpp. Text-only; vision is planned for a
later release.

* `llm_download()` fetches a pinned model over HTTPS and verifies it by SHA256
  (WP8a). `model` is either a registry alias
  (`"qwen2.5-0.5b-instruct-q8_0"`, `"qwen2.5-1.5b-instruct-q4_k_m"` — both
  Apache-2.0, pinned to an immutable revision in `inst/models.csv`) or a full
  `https://` URL; only HTTPS is accepted. Verification is **fail-closed**: a
  registry download whose checksum does not match the pinned value is deleted and
  raises `relm_error_download` (carrying `expected`/`actual`/`url`), so the
  destination path never holds unverified bytes. `dir = NULL` caches under
  `tools::R_user_dir("relm", "cache")`; an already-present, checksum-matching
  model is returned without re-downloading (idempotent, offline-friendly), and a
  corrupt cached file is re-fetched. A bare URL has no pinned checksum, so the file
  is downloaded and its computed SHA256 reported (never presented as verified).
  Nothing downloaded is ever executed. The path is returned invisibly. Zero new
  dependencies — `utils::download.file(method = "libcurl")` and
  `tools::sha256sum()` only.

* Steering and ablation now work on **any standard-residual decoder**, not a fixed
  architecture list (WP7.5a part-2, D-021). The old hard allow-list
  (`{llama, qwen2, gemma3}`) is replaced by a **runtime sentinel intervention
  probe**: before `llm_steer()`/`llm_ablate()` return a handle, the engine decodes
  one throwaway token and checks, at each requested layer, that a sentinel ablation
  pins the residual and a sentinel control vector shifts it by exactly the expected
  amount — proving the mechanism actually takes effect on *this* model. A model where
  interventions would silently do nothing is refused with `relm_error_intervention`
  naming what did not respond (never a silent no-op); the verdict is cached per model,
  so the cost is paid once. This enables interventions on Gemma 4 / Qwen 3 / Qwen 3.5
  (their graphs carry the same residual choke point) with no vendored change. The
  `llm_steer()`/`llm_ablate()` signatures are unchanged. `llama` and `qwen2` remain
  the *behaviorally validated* tier (they pass the valence / KL acceptance fixtures);
  the tier is documentation only and no longer gates.

* Modern model families are usable **as text** (WP7.5a part-1, D-021): Gemma 4,
  Qwen 3, and Qwen 3.5 GGUFs already load and generate at the pinned engine, and
  two gaps are closed. (1) `llm_generate(chat = TRUE)` now works on models whose
  embedded chat template the engine cannot detect: when the embedded template is
  present but unrecognized, the resolver falls back to the architecture's builtin
  template (`gemma`/`chatml`/`llama3`) — this fixes Gemma 4, whose Jinja template
  was undetected and previously failed with `llama_chat_apply_template failed
  (-1)`. Models whose embedded template already applies (e.g. Qwen's chatml) are
  unchanged. (2) `llm_trace()` now supports the `qwen3`, `qwen35`, and `gemma4`
  architectures, with source-derived per-architecture component tables. On
  `gemma4`, `residual` traces every layer; `mlp_out` and `attn_out` raise
  `relm_error_trace` rather than return a partial or mislabeled capture (its
  FFN output is named only on dense layers, and its same-named `attn_out` tensor is
  a different quantity than the post-projection output the component defines). The
  support matrix is recorded in `docs/wp7.5-model-matrix.md`. (Steering/ablation on
  the new families arrives in part-2, above.)

* Two reference demos and Quarto vignettes land (WP7). **Demo A -- "the anatomy
  lab"** traces a fixed sentiment contrast set with `llm_trace()`, fits one
  cross-validated `glmnet` ridge-logistic probe per layer, and plots out-of-fold
  decodability (AUC with a bootstrap CI) against depth -- "where sentiment becomes
  readable" -- then `llm_steer()`s along a `prcomp()` direction and verifies the
  effect on held-out prompts. **Demo B -- "topic modelling without Python"**
  embeds public abstracts with `llm_embed()`, lays them out with `uwot::umap()`,
  clusters with `dbscan::hdbscan()`, names each cluster with `llm_generate()`, and
  draws one labelled map -- a BERTopic-class pipeline, fully local. Both money
  plots are base graphics. The demos live in `tests/demos/` (Demo A also runs
  nightly on the CI model) and are documented in the `anatomy-lab` and
  `topics-without-python` vignettes, which render with or without a local model.
  `glmnet`, `uwot`, and `dbscan` join `Suggests` (used only by the demos); the
  package's sole hard dependency stays `nanoarrow`.

* `llm_logits()` reads the model's next-token distribution: a forward pass over
  each `prompt` returning the `top` most likely next tokens as a long-format base
  `data.frame` (`prompt_id`, `rank`, `token_id`, `token`, `logit`, `prob`), ranked
  most- to least-likely (`rank == 1` is the token greedy generation would pick).
  Probabilities are the softmax over the **full** vocabulary (computed before the
  top-`top` are selected, so each `prob` is the token's true share and the head
  sums to less than 1); token ids are 1-based like [`llm_tokens()`]. Vectorized
  over `prompt`, deterministic, and intervention-aware — active `llm_steer()`/
  `llm_ablate()` effects on the handle reshape the distribution. The top-k +
  softmax extraction is validated against an independent numpy reference on the
  synthetic model.

* `llm_steer()` and `llm_ablate()` add the intervention core (WP5). Each returns a
  **new** `llm` handle -- a fresh context on the source model's shared, read-only
  weights, with the intervention applied -- and never mutates the source; removing
  an intervention is simply using the original handle (reversibility is exact).
  `llm_steer(m, layer, direction, coef, positions = "all")` adds `coef * direction`
  to the residual stream at `layer` (llama.cpp's native control vector);
  `llm_ablate(m, layer, neurons, value, component = "residual")` forces the listed
  neurons to `value`. Interventions **compose** and are derivation-order-independent
  (`ablate |> steer` behaves like `steer |> ablate`): steering stacks by summation,
  ablation is a union (last-write-wins per neuron), and a steer never moves an
  ablated neuron. Each derivation allocates a fresh context (a sub-second pause and
  real memory, not a free copy). Invalid requests -- an architecture whose
  intervention mechanism the runtime probe cannot verify, an out-of-range layer, steering layer 1
  (unreachable by the native control vector -- ablate it instead), a wrong-length
  `direction`, out-of-range `neurons`, or the not-yet-supported `positions`/
  `component` values -- raise `relm_error_intervention` rather than silently
  doing nothing. Interventions apply to generation and logits only for now:
  `llm_embed()` and `llm_trace()` on an intervened handle raise
  `relm_error_embed` / `relm_error_trace` rather than returning base vectors
  mislabeled as intervened. The exact numerical effect and bit-for-bit
  reversibility are validated against an independent numpy reference on a synthetic
  model.

* `llm_trace()` captures a model's internal activations over the prompt tokens
  (WP4, observation core): a long-format `relm_trace` `data.frame` with columns
  `prompt_id`, `token_pos`, `token`, `layer`, `component`, `neuron`, `value`. The
  filters `layers`, `positions` (`"last"`/`"all"`/explicit), and `components`
  (`"residual"`, `"attn_out"`, `"mlp_out"`) select what is captured; the
  memory-safe defaults capture little (`positions = "last"`,
  `components = "residual"`). Tracing uses a dedicated, transient context tapped via
  llama.cpp's scheduler eval callback, so normal generation carries no overhead
  (zero vendored patch, D-012). A capture whose estimated size exceeds the budget
  (`min(2 GB, 20% RAM)`, `options(relm.trace_budget=)`) either streams to disk
  when `spill = TRUE` (the default) or, with `spill = FALSE`, raises
  `relm_error_oom` — carrying `estimate_bytes` — *before* any allocation. A
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
  raises `relm_error_embed` asking for `"mean"`/`"last"`). `normalize = TRUE`
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
  string; an over-long prompt raises `relm_error_context_overflow`. Greedy
  decoding is validated token-for-token against an independent numpy reference on
  a synthetic model.
* `llm_tokens()` converts between text and the model's tokens (WP2): encoding
  returns a named integer vector of 1-based token ids (names are the token
  pieces), decoding reconstructs the string. UTF-8 correct, including accented
  text that spans token boundaries. Vectorized over inputs; a model without a
  tokenizer or an out-of-range id raises `relm_error_tokenize`.
* `llm()` loads a local GGUF model and returns an `llm` handle, with
  `print()`, `summary()`, and `close()` methods (WP1). Bad requests (missing,
  unreadable, or corrupt files; an unavailable backend) are reported as classed
  conditions (`relm_error_model_load`, `relm_error_backend`,
  `relm_error_closed`, `relm_error_internal`) with actionable messages,
  never a crash. `close()` frees native memory deterministically; a
  garbage-collection finalizer is the safety net. Loading real models and the
  metadata shown by `summary()` are validated on local hardware (no model ships
  in the package yet).
* Repository bootstrap (WP0): the R package scaffold (extendr toolchain, no
  exported functions yet), the `rust/` Cargo workspace with empty-but-compiling
  `rebirth-ffi` and `rebirth-llm` crates, dual MIT/Apache-2.0 licensing, a
  trademark policy, and continuous-integration workflows (`R CMD check`; cargo
  test/clippy/fmt). No user-facing functionality yet.
