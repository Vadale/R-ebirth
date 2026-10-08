# relm (development)

## Component projection steering (F6e)

* `llm_apply_direction(operator = "project")` applies a recorded unit component
  direction as `h - coef * v * sum(v * h)`. Schema-2 artifacts distinguish MLP
  and attention outputs; existing residual artifacts and additive calls retain
  their schema and default behavior.
* Native admission checks the actual producer and supported CPU/Metal storage.
  Initial sites are dense Llama MLP/post-output-projection attention and Qwen2
  MLP. A combined R/native materialization budget covers accumulated projection
  and residual owners; model weights and context storage remain outside it.
* Projection is static for the derived handle and precedes live observation.
  Live replies still change only additive steering coefficients. Images,
  ordinary trace and embeddings on projected handles are refused. Model maps
  mark configured projection sites; these marks do not imply measured effects.
  Recorded artifact provenance does not authenticate loaded weights.
* Handle state uses a bounded native factory and the R 4.6 binding API when
  available. The additional weak provenance reference is charged explicitly;
  state names are locked while close/synchronization values remain mutable.

## Recorded contrast directions (F6d)

* `llm_direction()` constructs one full-width, unit residual direction from
  explicit paired activations, with optional pair normalization and control-mean
  orthogonalization. It records bounded provenance and numerical diagnostics;
  unstable pairs/means are refused without dropping observations.
* Trusted RDS artifacts preserve exact values and canonical checksums. Printing
  and `llm_apply_direction()` validate integrity and compatibility before existing
  additive steering; recorded provenance does not authenticate loaded weights.
* Row-wise computation and bounded temporary checksum files respect an explicit
  materialization budget. New documentation covers separated construction,
  coefficient selection and held-out evaluation, including a zero-effect result.
  No native change or new package dependency.

## Reusable model and intervention graphics (F6c)

* `plot()` on an open model shows selected blocks, supported observation sites
  and configured steering/ablation entries. It describes metadata, not measured
  activity or causal connections; unknown architectures remain generic.
* `llm_compare()` pairs bounded live-state captures under caller-recorded model,
  settings and complete generated-token history. Divergent input prefixes withhold
  differences; truncated top-k gaps remain unknown rather than zero.
* `llm_timeline()` retains bounded, whole-state applied coefficient history.
  Its plot separates sampled-token IDs and actual steering timing, including
  dropped-history disclosure. All three plots use base R and return their data
  invisibly for caller-owned PDF/PNG and CSV/RDS workflows. No new dependency.
* Live captures using the default managed spill directory now create filenames
  accepted by the existing lifetime lease. An actual graphics comparison found
  that their missing `trace-` prefix previously rejected the first spilled
  state. The lease and native writer are unchanged; caller-managed directories
  remain supported.

## Live state observation and coefficient steering (F6a/F6b)

* `llm_generate(async = TRUE, on_state = ...)` observes the raw distribution and
  selected activations that produced each sampled token. Plain state/logit
  tables and `relm_trace` chunks distinguish generated positions from model
  context source positions. The callback can continue with NULL or update coefficients of existing steering
  entries, and can cancel before
  another token is sampled; this is an observation/control mechanism, not a
  validated detector or safety guarantee.
* One state waits for acknowledgement, with existing token events ordered
  around that boundary. Explicit materialized/native/serialized limits,
  completed Arrow streams and managed leases bound retained transport.
  Callbacks run on R's thread; model/KV storage and user-retained objects are
  outside the transport estimate. No dependency or exported function is added.


* Coefficient replies are partial and atomic, affect only the next decode and
  preserve prior KV history. Worker-produced coefficient/revision/source metadata
  identifies what was applied; zero clears an entry's contribution. Original
  adapters are restored on completion, cancellation and failure, preserving
  immutable R handles. Live direction/layer/ablation changes are excluded.


## Native graph storage

* Graph-storage sizing now uses integer offsets instead of arithmetic on a null
  pointer, correcting an upstream undefined-behavior finding. The embedded
  b10828 version, allocated graph layout and numerical operations are unchanged.
  Source-derived layout regressions retain active ASan/UBSan controls.

## Managed trace storage

* On macOS/Linux, managed spill directories hold a native lifetime lease from
  the first disk write through session cleanup. Age alone no longer permits
  another session to remove a live trace. Cleanup rejects changed paths,
  symlink redirection and unrecognized contents.
* Old directories without verifiable ownership metadata are retained, including
  files left by earlier package versions. Caller-supplied `spill_dir` directories
  remain caller-managed. This conservative policy can leave files for manual
  cleanup; normal cleanup remains best-effort.

## WP10: token streaming

* `llm_generate(async = TRUE, on_token = ...)` delivers ordered batches of
  token identities, committed UTF-8 text and prompt-end events as plain data
  frames. Text fragments reconstruct the successful final result; structured
  fragments remain provisional until independent schema validation.
* A caller-owned empty binary file connection can receive the same events as
  UTF-8 CSV. Native queue and per-callback limits bound transport payload;
  slow consumers apply backpressure. Consumer failures cancel/wake native work
  and reject safely. Callbacks and file writes run on R's thread and should be
  short. No new package dependency or exported function is added.
* The token-streaming vignette and repository demo show rolling token counts,
  throughput and growing data-frame collection. Live activations and intervention
  changes remain outside this interface.

## WP9: background generation

* `llm_generate(async = TRUE)` returns a promise while a native worker uses the
  existing model. Optional `later` and `promises` packages deliver coalesced
  progress callbacks on R's event loop. Synchronous generation is unchanged.
* `llm_cancel()` requests cooperative cancellation. Only one native job is
  admitted per process, with bounded input/output, classed failures, deferred
  close while busy, and worker cleanup on namespace shutdown. The native library
  stays mapped for retained external-pointer finalizers; forced `dyn.unload()`
  with live external pointers is unsupported.

# relm 0.3.0

## New features

* `llm_generate()` accepts `schema` as JSON text for bounded structured output:
  closed objects, bounded strings and integers, string enums, booleans and null.
  Successful calls return complete validated JSON strings with prompt names and
  the existing seed attribute. Unsupported schemas and incomplete generation
  raise classed conditions; nonempty stop/image inputs are rejected in this mode.
  Schema enforcement does not establish factual correctness.

* `llm_probe()` fits binary ridge probes from an `activations()` formula, with
  explicit source groups, group-disjoint development cross-validation and
  optional held-out groups. Preprocessing and layer/regularization selection use
  development data only. S3 summaries, plots and probability predictions
  distinguish exploratory scores from conditional held-out intervals. Trace
  alignment and materialized memory are checked, including spilled traces.
  Shuffled-label and simple-feature controls accompany the anatomy-lab workflow.
  The optional `glmnet` dependency remains in Suggests; decodability does not
  establish causal use.

* The embedded llama.cpp engine moves from b9726 to b10828 for native
  Spark-X2.5-4B support. The optional `spark-x2.5-4b-q8_0` download alias pins
  the official 4.38 GB GGUF. Ollama is not required. The author's single-turn
  chat template is supported: ordinary chat uses its thinking opener, while
  schema-constrained chat uses its official non-thinking opener. Spark activation
  tracing remains explicitly unsupported pending an independent numerical reference.

## Application examples

* The repository's funding-extraction example provides explicit environment
  setup, offline batch execution and verified restart/resume. Immutable results
  retain raw outputs, evidence and failure details; changed inputs/configuration
  refuse stale reuse. Application-only `jsonlite` 2.0.0 stays outside the package.

* The local funding service template adds setup/start/status/stop commands, one
  loopback HTTP frontend, a persistent model worker, one active request with no
  job queue, and durable request tickets. The approved HTTP/process dependencies
  are isolated from relm Imports/Suggests; no new package export is introduced.
  Mac/Linux operational acceptance includes recovery and 1,000 same-worker
  requests, with source provenance recorded in `docs/service-implementation.md`.

* Operational acceptance does not establish extraction accuracy. The frozen D1
  pilot produced 10/10 schema-valid outputs, 2/10 task-valid and 0/10 fully
  grounded records; all four quality promotion gates failed. Predictions and
  source review remain in `docs/d1-extraction-evaluation.md`. Human correction
  time is unmeasured, and extraction usefulness is not accepted.

## Fixes

* Spill files have unique names across R sessions, including caller-supplied
  directories. Existing files and symlinks are refused without overwriting them.
* Trace slice layers and token positions reject fractional, non-finite, and
  out-of-range indices before conversion. Disk and memory slices follow the same
  validation rules.
* CPU handles explicitly exclude GPU devices and disable GPU offloading for
  generation, embeddings, traces, and derived intervention contexts. CPU loading
  therefore does not depend on Metal being available to the process.
* Invalid `backend` and `pooling` choices raise `relm_error_argument`;
  documented defaults and unambiguous abbreviations remain supported.
* Disk-trace access and the exploratory interpretation of historical Demo A
  probe estimates are clarified.

## Compatibility and installation

* The default `schema = NULL` retains ordinary text and image generation.
  Existing numerical goldens are unchanged.
* Source installation requires Rust >= 1.85.0, matching the locked default
  dependencies. CI covers R release and oldrel, including the Rust minimum.
* The batch and service recipes require relm 0.3.0 and a freshly prepared
  application environment. Existing 0.2.0.9000 snapshots and their receipts keep
  their original identity; do not edit or reuse them as 0.3.0 environments.
* The core package gains no R dependency. The application templates remain
  outside the package API. Windows/CUDA support and vision-encoder
  interpretability are not added by this release.

# relm 0.2.0

Vision. A handle loaded with a model's **mmproj projector** takes image input
across generation and embeddings, on the same vendored engine (no version
bump) and with the text-only paths byte-identical to 0.1.0 (Phase 11,
D-026 + addenda).

* **Vision vignette.** `vignette("vision", "relm")` — "Seeing machines" —
  walks the whole path: download the pinned pair, load with the projector,
  ask about an image, and run an image-vs-text similarity check with
  multimodal embeddings. Fully self-contained (it draws its own test images
  with base graphics) and renders with or without a local model.

* **Vision model registry.** Two new `llm_download()` aliases pin the
  Apache-2.0 default pair (license verified on the artifact repo's model
  card): `"qwen2-vl-2b-instruct-q4_k_m"` (the model) and
  `"qwen2-vl-2b-instruct-mmproj-f16"` (its projector), both SHA256-pinned to
  an immutable revision and verified fail-closed. Load with
  `llm(llm_download("qwen2-vl-2b-instruct-q4_k_m"),
  projector = llm_download("qwen2-vl-2b-instruct-mmproj-f16"))`.

* **Projector trust note.** The `projector` file is engine-trusted input,
  exactly like the model GGUF itself — a corrupt or hostile file is parsed by
  native code. Prefer the SHA256-verified registry aliases; treat any other
  source with the same care as a model file.

* **Known limitation (documented, upstream).** A projector that FAILS to load
  (for example an mmproj built for a different model) is refused with a
  classed `relm_error_image`, but the failed attempt leaks a bounded amount
  of CPU memory once per attempt (the projector weights; an upstream
  llama.cpp constructor issue at the pinned engine version). The session
  stays healthy; fix the argument and reload.

* **Image embeddings (T2).** `llm_embed()` gains `images =`: pair image files
  with each input (the same pairing contract, formats — **JPEG, PNG, BMP** —
  and pre-decode limits as `llm_generate(images = )`) and get one matrix row
  per (text, image) input. An input with an image may have empty text
  (`x = ""`), embedding the image alone. Pooling with images reduces over the
  **text positions** (including the model's image-delimiter tokens), which
  the image conditions through attention — matching the reference llama.cpp
  behavior at the pinned engine version; text-only inputs are byte-identical
  to before. Requires a handle loaded with `llm(projector = )`.

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
  derived from a vision handle keep accepting images. Verified against
  Qwen2-VL-2B-Instruct (Apache-2.0; the pinned registry aliases above).
  Text-only calls are byte-identical to before.

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
