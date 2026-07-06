# API-GRAMMAR.md — Approved Signatures and Naming Rules

**Document 3 of 3.** The binding specification of the `rebirth` package's public surface. Per the spec-first rule (`SOLO-PHASE-PLAN.md` §5): **no function may be exported unless its entry appears here**; implementations must match these signatures exactly (names, arguments, defaults, return shapes, error classes).

- **Status:** v1.0 — **APPROVED by the founder on 2026-07-04 (`DECISIONS.md` D-003). BINDING.** This includes the three §8 choices. Changes to `[approved]` entries now require a superseding `DECISIONS.md` entry.
- **Date:** 2026-07-03
- **Change protocol:** any change to an entry marked `[approved]` after sign-off requires a `DECISIONS.md` entry approved by the founder. Additions for a new phase are drafted here with status `[proposed]`, then approved before implementation.

---

## 1. Global grammar rules

These apply to every function, present and future.

1. **Base-R idiom.** S3 classes and generics; returns are plain `data.frame` and base `matrix` (classed only for printing/method dispatch, never a required dependency); native `|>` composes everything; no tidyverse imports.
2. **`llm_` prefix** for all module functions (`base::embed()` collision makes short names unsafe; prefixed families are base-R idiom — `Sys.*`, `file.*`).
3. **All indices are 1-based** in the R API — tokens, layers, neurons, positions. `layer = 1` is the first transformer block. Conversion to 0-based happens at the FFI boundary and nowhere else. Off-by-one at this boundary is the project's canonical defect class: every function touching indices gets explicit 1-based tests.
4. **Plain-English argument names**, snake_case, no engine jargon: `context_length` (not `n_ctx`), `gpu_layers` (not `n_gpu_layers`), `max_tokens`, `temperature`, `top_p`, `seed`, `stop`, `pooling`, `normalize`, `layers`, `positions`, `components`, `spill`. The model handle is always the first argument, always named `m` (except S3 methods bound to a generic's argument names).
5. **Vectorization over prompts.** Every function taking prompt text accepts a character vector and processes all elements (sequentially in Phases 0–4); results carry `prompt_id` (integer, 1-based) or one row/element per prompt. Input names, when present, are preserved (rownames / a `prompt` name attribute).
6. **Memory-safe defaults** (the 16 GB rule): defaults never capture more than needed — `llm_trace()` defaults to `positions = "last"`, `components = "residual"`; expanding capture is always an explicit user choice. Any function that can exceed memory must support disk spill rather than crash.
7. **Determinism contract:** same model file + same parameters + same `seed` + same build + same backend ⇒ identical output, across runs and R sessions. Bitwise identity **across backends** (Metal vs CPU vs CUDA) is *not* promised — floating-point op order differs; cross-backend agreement is a documented tolerance (harness B).
8. **Errors are classed conditions** (hierarchy in §5): every error inherits `c("<specific>", "rebirth_error", "error", "condition")` with a message stating *what happened → likely cause → what to try*. A raw Rust panic reaching the console is a bug.
9. **Side effects are declared.** Only two functions write to disk: `llm_download()` (model files) and `llm_trace(spill = TRUE)` (spill files under a session spill directory, cleaned on session exit). Nothing else touches the filesystem.
10. **Printing:** `print` methods are one-screen summaries (no data dumps); `summary` methods return an object (classed list) whose own print is richer; wide/long data is left to the user's tools.
11. **English everywhere** — identifiers, arguments, messages, docs.

---

## 2. Classes

### `llm` — a loaded model handle
External pointer to native state + metadata. **Immutable from R's point of view:** interventions (`llm_steer`, `llm_ablate`) return a *new* handle sharing the underlying weights; they never mutate an existing handle. Copying the R object never copies model memory.

| Slot (attribute) | Type | Meaning |
|---|---|---|
| `path` | chr | source GGUF path |
| `architecture` | chr | e.g. `"qwen2"`, `"gemma3"` |
| `parameters` | dbl | parameter count |
| `quantization` | chr | e.g. `"Q4_K_M"` |
| `layers` | int | number of transformer blocks |
| `hidden_size` | int | residual-stream width |
| `context_length` | int | active context window |
| `backend` | chr | `"metal"`, `"cpu"`, `"cuda"` |
| `interventions` | list | active steering/ablation specs (empty for a fresh handle) |

Methods: `print.llm`, `summary.llm`, `close.llm`. A closed or GC-collected handle raises `rebirth_error_closed` on any use.

### `rebirth_trace` — captured activations
A plain `data.frame` (long format) with class `c("rebirth_trace", "data.frame")`. **Column schema (exact, in this order):**

| Column | Type | Meaning |
|---|---|---|
| `prompt_id` | int | 1-based index into the `prompts` argument |
| `token_pos` | int | 1-based position within that prompt's tokens |
| `token` | chr | the token piece at that position |
| `layer` | int | 1-based transformer block |
| `component` | chr | `"residual"`, `"attn_out"`, `"mlp_out"` |
| `neuron` | int | 1-based index within the component vector |
| `value` | dbl | activation (f32 upcast to double) |

Attributes: `model` (chr, path), `spilled` (lgl), `spill_files` (chr, if any), `prompts` (chr, the original texts). Spilled traces present the same data.frame interface, loading lazily.
Methods: `print.rebirth_trace` (dimensions + capture spec, never the data), `summary.rebirth_trace` (per layer/component: n, mean |value|, spill status), `as.matrix.rebirth_trace` (§4).

### `llm_probe` — fitted probe set
Classed list: per-layer fitted probes + CV metrics. Methods: `print`, `summary`, `plot` (the decodability-by-layer figure: metric with CI vs layer), `predict`.

---

## 3. Function entries — Phases 0–1 `[approved pending sign-off]`

### `llm(path, context_length = 4096, gpu_layers = NULL, backend = c("auto", "metal", "cuda", "cpu"), mmap = TRUE)` — Phase 0
Loads a GGUF model; returns an `llm` handle. `gpu_layers = NULL` = auto (all that fit); `backend = "auto"` picks the best available. Errors: `rebirth_error_argument` (invalid `context_length`/`gpu_layers`/`mmap`), `rebirth_error_model_load` (missing/corrupt/unsupported file — message names the failing check), `rebirth_error_backend` (requested backend unavailable).

### `close(con, ...)` method `close.llm` — Phase 0
Frees native memory deterministically (finalizer remains the safety net). Returns `invisible(NULL)`. Subsequent use of the handle → `rebirth_error_closed`.

### `print.llm(x, ...)`, `summary.llm(object, ...)` — Phase 0
Print: one screen — file, architecture, parameters, quantization, layers × hidden size, context, backend, active interventions count. Summary object adds memory footprint, tokenizer info, full intervention list.

### `llm_tokens(m, x, decode = FALSE)` — Phase 1
`decode = FALSE`: `x` is character (vectorized) → **named integer vector** per prompt (names = token pieces); for `length(x) > 1`, a list of such vectors. `decode = TRUE`: `x` is an integer vector of token ids → single character string. UTF-8 correct (Italian text in the test suite). Errors: `rebirth_error_tokenize`.

### `llm_generate(m, prompt, max_tokens = 256, temperature = 0.8, top_p = 0.95, seed = NULL, chat = TRUE, stop = NULL)` — Phase 1
Vectorized over `prompt`; returns a character vector of the same length (names preserved). `chat = TRUE` applies the model's chat template (Gemma + Qwen verified); `chat = FALSE` = raw completion. `seed = NULL` draws and *records* a seed; the used seed is attached as `attr(result, "seed")` (reproducibility is always recoverable). `stop` = character vector of stop sequences. Active interventions on `m` apply. Errors: `rebirth_error_generation`, `rebirth_error_context_overflow` (prompt exceeds `context_length` — message says by how much).

### `llm_embed(m, x, pooling = c("mean", "last", "model"), normalize = TRUE)` — Phase 1
`x` character vector → base `matrix`, `length(x)` rows × embedding-dim columns; rownames = `names(x)` if set, else `seq_along(x)` as character. `pooling = "model"` uses the model's own pooling when the GGUF defines one. Errors: `rebirth_error_embed`.

### `llm_download(model, dir = NULL, quiet = FALSE)` — Phase 3
`model` = a pinned alias from the package's model registry (e.g. `"qwen2.5-1.5b-instruct-q4_k_m"`) or a full URL. HTTPS only; SHA256 verified **fail-closed** (mismatch = file deleted + `rebirth_error_download`); returns the local path invisibly; `dir = NULL` = the user cache directory (`tools::R_user_dir("rebirth", "cache")`). Never executes downloaded content.

---

## 4. Function entries — Phase 2 `[approved pending sign-off]`

### `llm_trace(m, prompts, layers = NULL, positions = "last", components = "residual", spill = TRUE, spill_dir = NULL)`
Runs a **forward pass over the prompt tokens** (no sampling — tracing *during generation* is Phase 6, a separate entry) and captures activations per the filters. Returns a `rebirth_trace` (§2).
- `layers = NULL` = all blocks; else 1-based integer vector.
- `positions`: `"last"` (default — last token of each prompt), `"all"`, or a 1-based integer vector (recycled per prompt with a warning if lengths differ).
- `components`: subset of `c("residual", "attn_out", "mlp_out")`.
- `spill = TRUE`: if the in-memory estimate exceeds the budget, capture streams to Arrow IPC files in `spill_dir` (default: session spill directory) and the returned object loads lazily. `spill = FALSE` + over-budget → `rebirth_error_oom` *before* allocation (predictive check, message states the estimate and the filters that would fix it).
Errors: `rebirth_error_trace`, `rebirth_error_context_overflow`.

### `as.matrix(x, layer, component = "residual", ...)` method `as.matrix.rebirth_trace`
Extracts one (layer, component) slice → base `matrix`: one row per captured (prompt_id, token_pos), columns = neurons (`hidden_size` wide). Rownames: `"<prompt_id>.<token_pos>"`. `layer` required, single value (slices are explicit; whole-trace reshaping is the user's `stats::reshape`/`ggplot2` territory).

### `llm_steer(m, layer, direction, coef = 1, positions = "all")`
Returns a **new `llm` handle** with a steering intervention added (adds `coef * direction` to the residual stream at `layer` for the given positions during any subsequent forward pass). `direction` = numeric vector of length `hidden_size` (checked). The original handle is untouched — removal = use the original object. Interventions compose: steering a steered handle stacks both (control vectors add per layer). **Scope (current release):** `positions` must be `"all"` — position-subset steering is a backlog capability that raises `rebirth_error_intervention`; and `layer = 1` (the first block) is not steerable, because llama.cpp's native control vector reserves that slot, so it raises `rebirth_error_intervention` (workaround: steer a later layer, or ablate layer 1). Errors: `rebirth_error_intervention` (dimension mismatch, invalid layer).

### `llm_ablate(m, layer, neurons, value = 0, component = "residual")`
Same pattern: new handle with the listed 1-based `neurons` of `component` at `layer` forced to `value` during forward passes (ablation is applied **after** steering, so a jointly steered-and-ablated neuron is pinned to exactly `value`; the result is derivation-order-independent). **Scope (current release):** `component` must be `"residual"` — `attn_out`/`mlp_out` ablation is a backlog capability that raises `rebirth_error_intervention`. Errors: `rebirth_error_intervention`.

### `llm_logits(m, prompt, top = 20)`
Vectorized over `prompt`; forward pass, next-token distribution. Returns a `data.frame`: `prompt_id <int>, rank <int>, token_id <int>, token <chr>, logit <dbl>, prob <dbl>` (`top` rows per prompt). Errors: `rebirth_error_generation`.

---

## 5. Function entries — Phase 4 `[approved pending sign-off]`

### `llm_probe(formula, data, method = "glmnet", cv = 10, metric = c("auc", "accuracy"), seed = NULL)`
`formula`: `label ~ activations(layer = 10:20, component = "residual")` — `label` is a column the user has attached to the trace (or a vector in the calling scope, standard R formula semantics); `activations()` is a formula helper resolved only inside `llm_probe`. `data` = a `rebirth_trace`. Fits one cross-validated probe per layer in the requested range. Returns `llm_probe` (§2). Errors: `rebirth_error_probe` (label/trace mismatch, single-class labels — message states counts).

### `activations(layer, component = "residual")`
Formula-helper marker; calling it outside a probe formula raises `rebirth_error_probe` with a pointer to correct usage.

### `plot.llm_probe(x, ...)`
The standardized decodability figure: metric with CI (y) vs layer (x), base graphics implementation with a documented ggplot2 recipe in the vignette. `predict.llm_probe(object, newdata, layer = NULL, ...)` scores new traces (default: best CV layer).

---

## 6. Condition classes

| Class | Raised by | Note |
|---|---|---|
| `rebirth_error` | all | base class; never raised bare |
| `rebirth_error_argument` | any exported function | invalid user argument (type/length/range); `argument` field names it |
| `rebirth_error_model_load` | `llm()` | file missing/corrupt/unsupported arch |
| `rebirth_error_backend` | `llm()` | requested backend unavailable |
| `rebirth_error_closed` | any use of a closed handle | |
| `rebirth_error_tokenize` | `llm_tokens()` | |
| `rebirth_error_generation` | `llm_generate()`, `llm_logits()` | |
| `rebirth_error_context_overflow` | generate/trace | message includes overflow size |
| `rebirth_error_embed` | `llm_embed()` | |
| `rebirth_error_trace` | `llm_trace()` | |
| `rebirth_error_oom` | trace with `spill = FALSE` | predictive, pre-allocation |
| `rebirth_error_intervention` | steer/ablate | dimension/layer validation |
| `rebirth_error_probe` | `llm_probe()`, `activations()` | |
| `rebirth_error_download` | `llm_download()` | checksum failures are fail-closed |

Every condition carries structured fields where useful (e.g. `estimate_bytes` on OOM, `expected`/`actual` on checksum) so code — and coding models — can handle them programmatically.

---

## 7. Reserved names — `[proposed]`, NOT approved, do not implement

Reserved to keep the namespace coherent; each needs its own approved entry when its phase arrives: `llm_generate(..., on_token = )` and streaming forms (Phase 5–6); `llm_serve()` / serve module surface (Phase 7); type-contract helpers and `reb_compile()` (Phase 7); multimodal arguments to `llm()` / `llm_generate(images = )` (Phase 11); `llm_finetune()` (Phase 12); preference-optimization surface (Phase 13); `sae_features()` and `rebirth.topics` exports (Phase 14); export/interop surface (Phase 15); streaming-source verbs (Phase 16).

---

## 8. Founder attention — the three genuinely debatable choices

Flagged per the decision-preparation rule; everything else above is conventional. Approving the document approves these too:

1. **`positions = "last"` as the trace default** (memory-safe, matches Demo A) vs `"all"` (more intuitive, OOM-prone on 16 GB). Chosen: `"last"` — explicit expansion beats accidental spill.
2. **Interventions return new handles** (functional, R-idiomatic, trivially reversible) vs mutating the model in place (imperative, one object). Chosen: new handles — "removal = use the original object" is the cleanest possible contract for the acceptance test "outputs reproduce bit-for-bit after removal."
3. **Plain-English argument names** (`context_length`, `gpu_layers`) vs engine-standard jargon (`n_ctx`, `n_gpu_layers`). Chosen: plain English — researchers first; the jargon appears once, in the docs, as "(llama.cpp: `n_ctx`)".
