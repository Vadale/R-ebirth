# API-GRAMMAR.md — Approved Signatures and Naming Rules

**Document 3 of 3.** The binding specification of the `relm` package's public surface. Per the spec-first rule (`SOLO-PHASE-PLAN.md` §5): **no function may be exported unless its entry appears here**; implementations must match these signatures exactly (names, arguments, defaults, return shapes, error classes).

- **Status:** v1.0 — **APPROVED by the founder on 2026-07-04 (`DECISIONS.md` D-003). BINDING.** This includes the three §8 choices. Changes to `[approved]` entries now require a superseding `DECISIONS.md` entry.
- **Date:** 2026-07-03
- **Change protocol:** any change to an entry marked `[approved]` after sign-off requires a `DECISIONS.md` entry approved by the founder. Additions for a new phase are drafted here with status `[proposed]`, then approved before implementation.

---

## 1. Global grammar rules

These apply to every function, present and future.

1. **Base-R idiom.** S3 classes and generics; returns are plain `data.frame` and base `matrix` (classed only for printing/method dispatch, never a required dependency); native `|>` composes everything; no tidyverse imports. The approved D-037 async transport (§9) returns a standard promise resolving to the same base-R value; later/promises are optional and scoped to that transport.
2. **`llm_` prefix** for all module functions (`base::embed()` collision makes short names unsafe; prefixed families are base-R idiom — `Sys.*`, `file.*`).
3. **All indices are 1-based** in the R API — tokens, layers, neurons, positions. `layer = 1` is the first transformer block. Conversion to 0-based happens at the FFI boundary and nowhere else. Off-by-one at this boundary is the project's canonical defect class: every function touching indices gets explicit 1-based tests.
4. **Plain-English argument names**, snake_case, no engine jargon: `context_length` (not `n_ctx`), `gpu_layers` (not `n_gpu_layers`), `max_tokens`, `temperature`, `top_p`, `seed`, `stop`, `pooling`, `normalize`, `layers`, `positions`, `components`, `spill`. The model handle is always the first argument, always named `m` (except S3 methods bound to a generic's argument names).
5. **Vectorization over prompts.** Every function taking prompt text accepts a character vector and processes all elements (sequentially in Phases 0–4); results carry `prompt_id` (integer, 1-based) or one row/element per prompt. Input names, when present, are preserved (rownames / a `prompt` name attribute).
6. **Memory-safe defaults** (the 16 GB rule): defaults never capture more than needed — `llm_trace()` defaults to `positions = "last"`, `components = "residual"`; expanding capture is always an explicit user choice. Any function that can exceed memory must support disk spill rather than crash.
7. **Determinism contract:** same model file + same parameters + same `seed` + same build + same backend ⇒ identical output, across runs and R sessions. Bitwise identity **across backends** (Metal vs CPU vs CUDA) is *not* promised — floating-point op order differs; cross-backend agreement is a documented tolerance (harness B).
8. **Errors are classed conditions** (hierarchy in §5): every error inherits `c("<specific>", "relm_error", "error", "condition")` with a message stating *what happened → likely cause → what to try*. A raw Rust panic reaching the console is a bug.
9. **Side effects are declared.** Only two functions write to disk: `llm_download()` (model files) and `llm_trace(spill = TRUE)` (managed session spill files are cleaned on exit; a custom `spill_dir` is caller-managed). D-038 additionally permits `llm_generate(on_token = con)` to write event CSV to a caller-owned, already-open binary regular-file connection (§10); it does not choose a path or open/close the connection. No other package-managed write is introduced.
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

Methods: `print.llm`, `summary.llm`, `close.llm`. A closed or GC-collected handle raises `relm_error_closed` on any use.

**Process boundary:** a live `llm` is process-local native state, not a durable
R object. Do not serialize it for later use, transfer it to another R worker or
inherit it through a fork. Recreate it inside the owning process from verified
model files and configuration; shared weights between intervention handles do
not imply sharing across processes or concurrent context access.

### `relm_trace` — captured activations
A plain `data.frame` (long format) with class `c("relm_trace", "data.frame")`. **Column schema (exact, in this order):**

| Column | Type | Meaning |
|---|---|---|
| `prompt_id` | int | 1-based index into the `prompts` argument |
| `token_pos` | int | 1-based position within that prompt's tokens |
| `token` | chr | the token piece at that position |
| `layer` | int | 1-based transformer block |
| `component` | chr | `"residual"`, `"attn_out"`, `"mlp_out"` |
| `neuron` | int | 1-based index within the component vector |
| `value` | dbl | activation (f32 upcast to double) |

Attributes: `model` (chr, path), `spilled` (lgl), `spill_files` (chr, if any), `prompts` (chr, the original texts). A spilled trace is a zero-row data.frame proxy with the same columns; its values remain on disk. Use `as.matrix()` for lazy slice access. Ordinary data.frame indexing and `nrow()` operate on the proxy, not the on-disk values (D-027 clarifies the shipped D-013 behavior).
Methods: `print.relm_trace` (dimensions + capture spec, never the data), `summary.relm_trace` (per layer/component: n, mean |value|, spill status), `as.matrix.relm_trace` (§4).

### `llm_probe` — fitted probe set
Classed list: per-layer development-only fits, selection CV metrics, separate
held-out metrics/predictions when supplied, split audit and uncertainty metadata
(D-033). Methods: `print`, `summary`, `plot`, `predict`. `summary()` exposes
counts, selection, preprocessing/solver provenance and interval status; intervals
are conditional on frozen fits and are withheld when unsupported.

---

## 3. Function entries — Phases 0–1 `[approved: D-003]`

### `llm(path, context_length = 4096, gpu_layers = NULL, backend = c("auto", "metal", "cuda", "cpu"), mmap = TRUE, projector = NULL)` — Phase 0 · `projector` approved 2026-07-14 (Phase 11, D-026)
Loads a GGUF model; returns an `llm` handle. `gpu_layers = NULL` = auto (all that fit); `backend = "auto"` picks the best available. `projector` = a path to an **mmproj GGUF** (or a registry alias resolved to a path) enabling image input; `NULL` (default) = text-only, unchanged. When set, `llm()` also initializes the vision encoder bound to the loaded model — the projector is a session property fixed at load (it shares the model pointer), exactly like the model file, so it belongs on `llm()`, not on each call. A projector whose input embedding size does not match the model raises `relm_error_image` naming both sizes (reject-not-clamp). New handle slots: `projector` (chr path or `NULL`), `vision` (lgl); `print.llm` shows the projector when present. Errors: `relm_error_argument` (invalid `context_length`/`gpu_layers`/`mmap`), `relm_error_model_load` (missing/corrupt/unsupported file — message names the failing check), `relm_error_backend` (requested backend unavailable), `relm_error_image` (projector load failure / mmproj–model mismatch).

### `close(con, ...)` method `close.llm` — Phase 0
Frees native memory deterministically when the native execution domain is idle
(finalizer remains the safety net). Under D-037, close during an active native job
marks the handle closed immediately and defers freeing until safe; closing the
submitting handle requests cancellation. Returns `invisible(NULL)` idempotently.
Subsequent use of the handle → `relm_error_closed`.

### `print.llm(x, ...)`, `summary.llm(object, ...)` — Phase 0
Print: one screen — file, architecture, parameters, quantization, layers × hidden size, context, backend, active interventions count. Summary object adds memory footprint, tokenizer info, full intervention list.

### `llm_tokens(m, x, decode = FALSE)` — Phase 1
`decode = FALSE`: `x` is character (vectorized) → **named integer vector** per prompt (names = token pieces); for `length(x) > 1`, a list of such vectors. `decode = TRUE`: `x` is an integer vector of token ids → single character string. UTF-8 correct (Italian text in the test suite). Errors: `relm_error_tokenize`.

### `llm_generate(m, prompt, max_tokens = 256, temperature = 0.8, top_p = 0.95, seed = NULL, chat = TRUE, stop = NULL, images = NULL, schema = NULL, async = FALSE, on_progress = NULL, on_token = NULL, on_state = NULL, layers = integer(), components = "residual", top = 20L, spill = TRUE, spill_dir = NULL)` — Phase 1 · `images` approved 2026-07-14 (Phase 11, D-026)
Vectorized over `prompt`; returns a character vector of the same length (names preserved). `chat = TRUE` applies the model's chat template (Gemma + Qwen verified); `chat = FALSE` = raw completion. `seed = NULL` draws and *records* a seed; the used seed is attached as `attr(result, "seed")` (reproducibility is always recoverable). `stop` = character vector of stop sequences. Active interventions on `m` apply. `images = NULL` (default) = text-only, unchanged. Otherwise a **list parallel to `prompt`**: `images[[i]]` is a character vector of image **file paths** for prompt `i` (`character(0)` for none); a bare character vector is treated as `list(images)` and requires `length(prompt) == 1` (else recycled with a warning if lengths differ — the `llm_trace(positions=)` recycling contract). Each prompt's images are inserted **before** its text (interleaved-marker control is a reserved later capability); one output per prompt (the `prompt_id` mapping is unchanged). Requires a handle loaded with `projector=`. Errors: `relm_error_generation`, `relm_error_context_overflow` (combined text+image tokens exceed `context_length` — message says by how much), `relm_error_image` (decode/parse failure, unsupported/oversized image, images on a non-vision handle), `relm_error_argument` (bad `images` type/length).

With `schema` supplied, text generation follows the approved D-030 bounded JSON
profile below. Successful results contain complete independently validated JSON;
nonempty stop/image input is rejected. Omitted schema preserves ordinary text
and vision behavior. The schema constrains format, not factual correctness.

### `llm_embed(m, x, pooling = c("mean", "last", "model"), normalize = TRUE, images = NULL)` — Phase 1 · `images` approved 2026-07-14 (Phase 11, D-026)
`x` character vector → base `matrix`, `length(x)` rows × embedding-dim columns; rownames = `names(x)` if set, else `seq_along(x)` as character. `pooling = "model"` uses the model's own pooling when the GGUF defines one. `images` pairs with `x` by the **same rule** as `llm_generate(images=)` (a list parallel to `x`; a bare character vector requires `length(x) == 1`, else recycled with a warning): one row per (text, image) input. Requires a handle loaded with `projector=`; images on a text-only handle raise `relm_error_image`. Errors: `relm_error_embed`, `relm_error_image`, `relm_error_argument`. Per the D-026 second addendum (approved 2026-07-14): with images present, `pooling` reduces over the **text-position** rows (image content conditions them through attention), and `x = ""` is allowed only for an input that carries an image (the image alone is embedded).

### `llm_download(model, dir = NULL, quiet = FALSE)` — Phase 3
`model` = a pinned alias from the package's model registry (e.g. `"qwen2.5-1.5b-instruct-q4_k_m"`) or a full URL. HTTPS only; SHA256 verified **fail-closed** (mismatch = file deleted + `relm_error_download`); returns the local path invisibly; `dir = NULL` = the user cache directory (`tools::R_user_dir("relm", "cache")`). Never executes downloaded content.

---

## 4. Function entries — Phase 2 `[approved: D-003]`

### `llm_trace(m, prompts, layers = NULL, positions = "last", components = "residual", spill = TRUE, spill_dir = NULL)`
Runs a **forward pass over the prompt tokens** (no sampling — tracing *during generation* is Phase 6, a separate entry) and captures activations per the filters. Returns a `relm_trace` (§2).
- `layers = NULL` = all blocks; else 1-based integer vector.
- `positions`: `"last"` (default — last token of each prompt), `"all"`, or a 1-based integer vector (recycled per prompt with a warning if lengths differ).
- `components`: subset of `c("residual", "attn_out", "mlp_out")`.
- `spill = TRUE`: if the in-memory estimate exceeds the budget, capture streams to Arrow IPC files in `spill_dir` (default: session spill directory) and the returned zero-row proxy exposes lazy slices through `as.matrix()` (§2). `spill = FALSE` + over-budget → `relm_error_oom` *before* allocation (predictive check, message states the estimate and the filters that would fix it).
Errors: `relm_error_trace`, `relm_error_context_overflow`.

### `as.matrix(x, layer, component = "residual", ...)` method `as.matrix.relm_trace`
Extracts one (layer, component) slice → base `matrix`: one row per captured (prompt_id, token_pos), columns = neurons (`hidden_size` wide). Rownames: `"<prompt_id>.<token_pos>"`. `layer` required, single value (slices are explicit; whole-trace reshaping is the user's `stats::reshape`/`ggplot2` territory).

### `llm_steer(m, layer, direction, coef = 1, positions = "all")`
Returns a **new `llm` handle** with a steering intervention added (adds `coef * direction` to the residual stream at `layer` for the given positions during any subsequent forward pass). `direction` = numeric vector of length `hidden_size` (checked). The original handle is untouched — removal = use the original object. Interventions compose: steering a steered handle stacks both (control vectors add per layer). **Scope (current release):** `positions` must be `"all"` — position-subset steering is a backlog capability that raises `relm_error_intervention`; and `layer = 1` (the first block) is not steerable, because llama.cpp's native control vector reserves that slot, so it raises `relm_error_intervention` (workaround: steer a later layer, or ablate layer 1). Errors: `relm_error_intervention` (dimension mismatch, invalid layer).

### `llm_ablate(m, layer, neurons, value = 0, component = "residual")`
Same pattern: new handle with the listed 1-based `neurons` of `component` at `layer` forced to `value` during forward passes (ablation is applied **after** steering, so a jointly steered-and-ablated neuron is pinned to exactly `value`; the result is derivation-order-independent). **Scope (current release):** `component` must be `"residual"` — `attn_out`/`mlp_out` ablation is a backlog capability that raises `relm_error_intervention`. Errors: `relm_error_intervention`.

### `llm_logits(m, prompt, top = 20)`
Vectorized over `prompt`; forward pass, next-token distribution. Returns a `data.frame`: `prompt_id <int>, rank <int>, token_id <int>, token <chr>, logit <dbl>, prob <dbl>` (`top` rows per prompt). Errors: `relm_error_generation`.

---

## 5. Function entries — Phase 4 `[approved: D-003; implementation pending]`

**D-033 approved (2026-09-28):** WP11a's grouping, selection, preprocessing,
uncertainty and controls contract is binding in
[`docs/probe-evaluation-contract.md`](docs/probe-evaluation-contract.md).
WP11a PR #48 is merged; WP11b implements this approved amendment.

### `llm_probe(formula, data, method = "glmnet", cv = 10, metric = c("auc", "accuracy"), seed = NULL, groups = NULL, test_groups = NULL)`
`formula`: `label ~ activations(layer = 10:20, component = "residual")`.
Labels come from a prompt-constant trace column or a vector in the formula
calling environment. `data` is a `relm_trace`, with one captured position per
prompt aligned across layers. Fits binary ridge logistic probes using the
already-approved optional `glmnet` dependency. `groups` maps captured prompts to
source-group IDs (named vectors match prompt IDs; unnamed vectors follow their
increasing order); `NULL` explicitly assumes independent prompts.
`test_groups` names entire groups reserved before analysis, or `NULL` for
exploratory development CV only. Group-disjoint CV chooses each layer's lambda
and the default layer on development data. Preprocessing and returned fits
never use held-out observations. The accepted contract defines the fixed grid,
selection ties, class/coordinate validation, RNG, memory and CI rules.
Returns an `llm_probe` (§2). Errors: `relm_error_probe` with actionable reason and
relevant counts/fold/layer; memory refusal is `relm_error_oom` before densification.

### `activations(layer, component = "residual")`
Formula-helper marker; calling it outside a probe formula raises `relm_error_probe`
with a pointer to correct usage.

### `plot.llm_probe(x, ...)`
The standardized decodability figure: held-out metric and available approximate
95% pointwise conditional group-bootstrap intervals versus layer, marking the
development-selected layer. Without held-out groups, show labelled exploratory
CV scores without inferential intervals. Base graphics; a documented ggplot2
recipe needs no package dependency. `predict.llm_probe(object, newdata,
layer = NULL, ...)` returns positive-class probabilities from saved development-only
fits, defaulting to the layer selected by development CV. It never refits on the
holdout. Predictions are named by increasing prompt ID; `newdata` must match the
trained component/neuron coordinates and single-position observation contract.

---

## 6. Condition classes

| Class | Raised by | Note |
|---|---|---|
| `relm_error` | all | base class; never raised bare |
| `relm_error_argument` | any exported function | invalid user argument (type/length/range); `argument` field names it |
| `relm_error_model_load` | `llm()` | file missing/corrupt/unsupported arch |
| `relm_error_backend` | `llm()` | requested backend unavailable |
| `relm_error_closed` | any use of a closed handle | |
| `relm_error_tokenize` | `llm_tokens()`; also `llm_generate`/`llm_embed`/`llm_logits` on a model that cannot tokenize (e.g. `no_vocab`) | |
| `relm_error_generation` | `llm_generate()`, `llm_logits()` | |
| `relm_error_schema` | `llm_generate(schema=)` | invalid/unsupported/over-budget schema; `reason`, JSON-pointer `schema_path` (D-030) |
| `relm_error_structured_output` | `llm_generate(schema=)` | incomplete/invalid constrained continuation; `reason`, 1-based `prompt_id`, `seed`, `generated_tokens`, bounded raw `partial_bytes` (D-030) |
| `relm_error_context_overflow` | generate/trace/logits | message includes overflow size |
| `relm_error_embed` | `llm_embed()` | |
| `relm_error_trace` | `llm_trace()` | |
| `relm_error_oom` | trace budget; async output budget (D-037) | checked before exceeding the applicable bound |
| `relm_error_busy` | competing native operation | `operation`, `reason`; one active native job |
| `relm_error_cancelled` | async generation | `reason`, `seed`, `prompt_id`, `generated_tokens`; no partial text |
| `relm_error_callback` | async progress callback | original condition in `parent` |
| `relm_error_internal` | caught native/internal failures | classed failure, no raw panic |
| `relm_error_intervention` | steer/ablate | dimension/layer validation |
| `relm_error_probe` | `llm_probe()`, `activations()` | |
| `relm_error_download` | `llm_download()` | checksum failures are fail-closed |
| `relm_error_image` | `llm()` (projector load/mismatch), `llm_generate()`, `llm_embed()` | image decode/parse failure, unsupported/oversized image, mmproj–model mismatch (`expected`/`actual` embd sizes), or images on a non-vision handle — a distinct, security-relevant surface (D-026) |

Every condition carries structured fields where useful (e.g. `estimate_bytes` on OOM, `expected`/`actual` on checksum) so code — and coding models — can handle them programmatically.

---

## 7. Reserved names — `[proposed]`, NOT approved, do not implement

Historical reservations keep names coherent; they are not scheduled features.
D-043 removes automatic implementation of `llm_serve()`/generic serving,
type-contract helpers/`reb_compile()`, `llm_finetune()`, preference optimization,
`sae_features()`, `relm.topics`, export/interop and general streaming-source verbs.
Each would require explicit product reactivation and its own approved entry.
T3 vision-tower interpretability remains unapproved research; the existing
`projector=`/`images=` T1/T2 surface remains approved and supported. Token
streaming and live state observation are already governed by sections 10–11,
not by these historical reservations. No approved signature changes here.

## 8. Structured output contract — `[approved: D-030]`

**D-030 approved on 2026-09-27:** append `schema = NULL` to the current
`llm_generate()` signature. A supplied value is one UTF-8 JSON string in the
restricted schema profile specified by [the S0 contract](docs/s0-output-contract.md).
Retain the named character-vector/seed return and no filesystem writes. With a
schema, return only complete validated JSON; reject nonempty stop sequences and
image-bearing requests initially. New approved classes are `relm_error_schema`
and `relm_error_structured_output`, with fields and limits in that contract.
The founder approved this amendment for S1 implementation on 2026-09-27.
The linked profile, errors and bounds are binding.

An application-level HTTP template may use existing approved functions without
creating `llm_serve()`. That name remains reserved and unapproved until its own
function entry is accepted. WP12a's application-only ticket protocol and
additional runtime packages are approved separately in D-034 and
[`docs/service-contract.md`](docs/service-contract.md); they add no relm export.

---

## 8. Founder attention — the three genuinely debatable choices

Flagged per the decision-preparation rule; everything else above is conventional. Approving the document approves these too:

1. **`positions = "last"` as the trace default** (memory-safe, matches Demo A) vs `"all"` (more intuitive, OOM-prone on 16 GB). Chosen: `"last"` — explicit expansion beats accidental spill.
2. **Interventions return new handles** (functional, R-idiomatic, trivially reversible) vs mutating the model in place (imperative, one object). Chosen: new handles — "removal = use the original object" is the cleanest possible contract for the acceptance test "outputs reproduce bit-for-bit after removal."
3. **Plain-English argument names** (`context_length`, `gpu_layers`) vs engine-standard jargon (`n_ctx`, `n_gpu_layers`). Chosen: plain English — researchers first; the jargon appears once, in the docs, as "(llama.cpp: `n_ctx`)".

## 9. Asynchronous generation — `[approved: D-037, 2026-10-01]`

Append `async = FALSE` and `on_progress = NULL` to `llm_generate()` and export
`llm_cancel(m)`. The exact input, promise, progress-schema, error, resource and
lifecycle contract is approved in [WP9 sections 3–6](docs/wp9-async-plan.md).
It is binding with this entry. Implementation, acceptance and integration are
complete in PR #54 at `b16e2c0` (2026-10-02); this is development beyond v0.3.0.

`async` is one nonmissing logical. Non-NULL `on_progress` is a function and
requires `async = TRUE`. Synchronous return/behavior stays unchanged. Async
returns a `promises` promise resolving to the same named character vector and
seed attribute. This pending object is an explicit exception to the base-return
rule; the completed result remains base R. R argument/dependency/closed/busy
checks fail before submission. Native failures reject with classed conditions.
No R object, callback or RNG use is allowed on the native worker.

Progress is a coalesced one-row data.frame: integer `prompt_id`,
`prompts_completed`, `prompts_total`, `generated_tokens`, `max_tokens`, then
character `phase` (`prefill`, `generate`, `complete`). Successful completion
emits one final snapshot before resolving. Callbacks run on R's thread outside
native locks. A failing callback requests cancellation and rejects with its
original condition in `relm_error_callback$parent`.

`llm_cancel(m)` returns invisible TRUE only for the first accepted cancellation
before terminal publication for that exact submitting handle; otherwise FALSE
when idle, already cancelling or native-terminal. Invalid/closed handles raise
their existing classes. Cancellation is cooperative; no thread killing, hard
interrupt deadline or successful partial result. Completion/error/cancellation
returns ownership before another job is admitted. Unexpected worker panic
closes the affected handle safely. Close/GC/unload behavior is specified in
WP9 section 5, including deferred frees and joining before DLL unloading.

Async limits: 128 prompts; 1 MiB UTF-8 per prompt; 16 MiB copied text arguments
in aggregate; 8,192 requested tokens per prompt; 8 MiB final UTF-8 output across
the call. Input refusal is `relm_error_argument`; output refusal is
`relm_error_oom`. Existing stricter schema/image bounds remain. No truncation or
implicit retry. Only one native job is active per process, with no queued jobs.
Optional later/promises dependency/version failures use `relm_error_generation`
with `reason = "async_dependency"`; native startup failure uses `async_start`.

## 10. Token streaming — `[approved: D-038, 2026-10-02]`

The founder approved the concrete contract on 2026-10-02.
Approved addition: append `on_token = NULL` to `llm_generate()`. Non-NULL requires
`async = TRUE` and accepts a function receiving plain data-frame batches or a
caller-owned, already-open writable binary regular-file connection. No new
export or dependency. The final promise/value/names/seed contract stays D-037.

The binding contract is [WP10 sections 2–5](docs/wp10-streaming-plan.md): ordered
`token`, `text`, `prompt_end` events with columns `event_id`, `event`,
`prompt_id`, `token_pos`, `token_id`, `text`, `elapsed`, `finish_reason`,
`validated`; R indices are 1-based. Stable UTF-8 text deltas reconstruct each
successful final string. Structured deltas are provisional until independent
validation. CSV has the same schema and explicit quoting/missing-value rules.

Approved limits: 256 queued rows / 256 KiB text; 16 KiB maximum text chunk;
64 rows / 64 KiB per R dispatch; all D-037 input/final-output bounds retained.
These payload bounds do not describe total resident memory. Completion waits
for delivery while retaining the execution reservation; final `on_progress`
runs after release. Native cancellation arbitration remains D-037. Explicit
model close during delivery (before release) or consumer failure abandons
undelivered data and rejects safely; close inside successful final progress
retains WP9's resolved result. The plan specifies failure precedence;
no partial successful result or consumer-side-effect rollback.

Approved new condition: `relm_error_stream` with `reason` in `closed`, `write`,
`encoding`, `invariant`, event/prompt metadata and original parent when present.
Callback failures retain `relm_error_callback` with callback identification.

Approved narrow exception to global rule 9: an explicitly supplied
`llm_generate(on_token = con)` file connection receives output. relm neither
chooses a path nor opens/closes that connection. This exception, the schemas and lifecycle amendment are binding.
Implementation and acceptance are in progress.


## 11. Live state observation — `[approved: D-041, 2026-10-03]`

The founder approved F6a with "ok. continua con F6a e F6b" after the concrete
proposal and approval question. Append `on_state = NULL, layers = integer(),
components = "residual", top = 20L, spill = TRUE, spill_dir = NULL` to
`llm_generate()`, retaining all earlier positional arguments and defaults.
The exact F6a contract in [Phase 6 sections 3–5](docs/phase6-live-introspection-plan.md)
is binding, including state/source positions, errors, resource limits and spill
side effects. No new export name or R/Rust dependency is approved or needed.
F6a acceptance passed at6877c4d, including all nine ordinary checks and the
independently verified scoped Linux sanitizer. F6b operational acceptance includes
focused native/installed-R/public-update evidence, all nine ordinary checks and
scoped sanitizer at490c7f4, and actual foreground steering on2026-10-04. Final
PR-head CI and PR59 integration remain separate. Approval itself is
not a numerical result.

A non-NULL on_state function requires async mode, one text prompt, no schema or
image input, and at most1024 requested tokens. Default layers capture no
activations; NULL explicitly selects all blocks. At least logits or activations
must be requested. The callback receives exactly `step`, `logits`, `trace`:
base-R tables and an existing bounded/spill-aware relm_trace. Indices are1-based;
source_pos=P+k-1 identifies the forward pass that selected generated token k,
not an invented activation for an undecoded token. Raw logits/full-vocabulary
softmax precede sampling. State delivery excludes EOG but includes non-EOG tokens
participating in a later removed stop suffix.

One outstanding state is acknowledged before token/text delivery for k and its
next decode. R callbacks run only on R's main thread, outside native locks.
The accepted F6a increment used NULL-only replies; the F6b amendment below
extends that response without changing ordering. Calling llm_cancel inside on_state requests
existing classed cancellation, not successful partial text. Existing on_token,
CSV, final promise/seed and busy/ownership rules remain intact. Delivered spill
proxies retain managed ownership; incomplete files are never published.

F6b continuation is authorized as the next increment under the same explicit
instruction. Its exact reply/audit amendment is finalized in
[Phase 6 section 6](docs/phase6-live-introspection-plan.md): NULL or exactly
`list(steer = data.frame(intervention, coef))`, addressing only existing steer
entries, atomically updating finite representable coefficients for the next
decode. Partial replies preserve other coefficients. Three integer audit columns
in step and a worker-produced steering attribute record actual applied state.
Original adapters are restored before model ownership returns, on every exit.
This preserves immutable R handles and the observation boundary. No new export,
dependency, direction, ablation or replay of historical KV is added. F6b acceptance is tracked separately and is not inferred from F6a evidence.

## 12. Reusable model and intervention graphics — `[approved: D-044, 2026-10-07]`

After reviewing the concrete proposal, the founder merged PR60 and instructed
"ho fatto il merge, puoi passare al prossimo step" on 2026-10-07, authorizing
F6c implementation. The exact approved types, context/alignment, side effects,
resource bounds and acceptance are in
[the F6c graphics contract](docs/f6c-graphics-contract.md).

```r
plot.llm(x, layers = NULL, ...)
llm_compare(reference, intervention, context, layer,
            component = "residual", neurons = NULL,
            max_bytes = 64 * 1024^2)
plot.relm_comparison(x, ...)
llm_timeline(state, history = NULL, max_states = 256L,
             max_bytes = 8 * 1024^2)
plot.relm_timeline(x, ...)
```

The model plot returns its metadata/site table invisibly. The constructors
return classed data frames from existing delivered live states; they perform no
generation and retain no native handle. Comparison uses recorded full input
prefixes, withholding numerical differences for divergent histories. Timeline
retains bounded worker-applied audit rows, not activation payloads. Plots use
base graphics on the caller's device; export remains caller-managed. Existing
condition classes are reused, with no dependency, native or vendor change.
