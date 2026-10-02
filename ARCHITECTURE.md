# ARCHITECTURE.md — Package Internals

**Document 2 of 3.** How `relm` is built inside: the crate layout, the R↔Rust boundary, the activation-tap strategy, memory and spill design, the build pipeline, and the mechanics reserved for later phases. `SOLO-PHASE-PLAN.md` holds the decisions, `API-GRAMMAR.md` holds the surface; this document holds the *how*.

- **Status:** v1.0
- **Date:** 2026-07-04
- **Audience:** whoever implements Phases 0–4, and anyone reviewing that work.

---

## 1. System overview

```
R session (single-threaded)
│
├── rebirth (R package: R/ code — validation, S3 classes, conditions, docs)
│     │  .Call via extendr
│     ▼
├── rebirth-ffi (Rust crate: R↔SEXP boundary via extendr — panic catching,
│     1-based→0-based conversion, condition mapping; any R-side unsafe lives
│     here, but extendr's safe ExternalPtr/Robj API means none is needed)
│     ▼
├── rebirth-llm (Rust crate: engine wrapper — model/context lifecycle,
│     generation, embeddings, tap orchestration, spill writer; owns the
│     minimal, SAFETY-commented C-FFI unsafe into vendored llama.cpp; R-free)
│     ▼
└── vendored llama.cpp (pinned tag; Metal / CPU / CUDA backends)

Side channels:
  spill files (Arrow IPC)  ←→  read lazily from R via nanoarrow
  tests/llm-golden/        ←   Python venv (torch/transformers) generates goldens
  reference llama.cpp      ←   unpatched build, same tag (harness B comparator)
```

## 2. The three-layer code design

1. **`relm` (R package).** All argument validation, defaulting, and condition raising happens in R *before* crossing the boundary — the Rust side receives only well-formed requests. S3 classes, printing, formula handling (`llm_probe`) are pure R. R code never contains "business logic" that numerics depend on.
2. **`rebirth-ffi`.** The R↔native boundary. Any *R-side* (SEXP) `unsafe` lives here — in practice **none** is needed in WP1, because extendr's safe `ExternalPtr`/`Robj` API abstracts the SEXP handling. Every entry point: (a) catches panics (`catch_unwind`) and converts them to `relm_error_internal` with a bug-report message — a panic reaching R is a defect by definition; (b) performs index conversion (see §4); (c) maps `Result<T, RebirthError>` to classed R conditions with structured fields (§8). No engine logic here.
3. **`rebirth-llm`.** The engine wrapper. It owns the crate suite's *C-side* `unsafe` — the hand-written `extern "C"` calls into vendored llama.cpp — kept minimal and individually SAFETY-commented, with the raw handles confined behind safe `Drop`-managed wrappers. It has **no R types in its API** — it takes/returns plain Rust types — which keeps it independently testable (`cargo test` without R) and independently reusable (dual MIT/Apache-2.0 — the "engine components reusable anywhere" licensing goal depends on this separation).

Bridge: **extendr** (scaffolded by `rextendr`). Fallback if CRAN friction ever demands it: **savvy** — the three-layer split means only `rebirth-ffi` would change (this is why the split exists). Switching is an ADR.

## 3. Object lifecycle and threading model

- An `llm` handle is an R external pointer to an `Rc`-owned, main-thread-only
  state containing the closed flag and `RefCell<Option<LoadedModel>>`. The weak
  registry supports orderly unload without keeping unused wrappers alive.
  `LoadedModel` owns a mutable context and shared weights through `Arc<Model>`.
  Interventions retain those weights and create a fresh context (D-016).
- R GC and `close.llm` mark a wrapper closed immediately. During async execution,
  native destruction is deferred until ownership returns. This applies to the
  submitting model and to unrelated or weight-sharing handles. Shared weights
  remain until their final native owner is released.
- **D-037 ownership:** one process-wide native permit authorizes one bound thread
  at a time, including queries, load, context access and destruction. Raw pointer
  gateways enforce this in release builds. An async worker temporarily owns the
  submitting `LoadedModel`; all R external-pointer wrappers remain !Send/!Sync.
  Other native work fails busy without waiting. The completion retains its permit
  until the FFI restores or destroys the model and drains deferred destruction.
- No worker calls R, runs callbacks, uses R RNG or constructs SEXPs. Inputs are
  owned Rust data; results become R objects only on main-thread collection.
  Polling never joins a live worker. Controlled unload cancels and joins before
  removing native resources; it does not force DLL unmapping while R external
  pointer finalizers may still reference the library. Spill writers still receive
  owned plain data and are joined within the native operation.

**Process boundaries (D-028):** a live handle is neither a serialized job artifact
nor an object to transfer/fork into another worker. Pass verified model paths,
configuration and ordinary R data; initialize and close each model inside its
owning process. In-process `Arc` sharing is not a cross-process memory contract.
The initial production template serializes inference within one worker and tests
request-state isolation after errors as well as successful calls.

## 4. Index discipline (the canonical defect class)

1-based (R) ↔ 0-based (engine) conversion happens **exactly once**, in `rebirth-ffi`, at named helpers (`to_engine_index`, `from_engine_index`). `rebirth-llm` and llama.cpp speak 0-based only; R speaks 1-based only. Property tests round-trip every index-bearing argument, and harness B's off-by-one mutation test (inject `layer+1` in a scratch branch) must fail loudly.

## 5. Activation taps and interventions (the WP4 core)

**Strategy A (preferred — minimal or zero vendored patching).** llama.cpp already exposes the observation hook we need: the **eval callback** (`cb_eval`, a `ggml_backend_sched_eval_callback` in the context params) — the same mechanism the upstream `llama-imatrix` tool uses to observe intermediate tensors during the forward pass. Graph tensors carry per-layer names (residual/attention/FFN outputs), so the tap = a callback that matches tensor names against the capture spec, copies matching tensors to host buffers (`ggml_backend_tensor_get`), and appends to the trace sink. Callback installed only while tracing → tap-off overhead ≈ 0 (the < 2% acceptance budget).

**Steering (generation-time residual addition):** llama.cpp has **native control-vector support** (per-layer additions to the residual stream via the adapter API). `llm_steer` maps onto it directly — no patch. Composition of stacked steers = summed vectors per layer, computed on our side.

**Ablation (implemented, D-016):** a minimal `build_cvec` patch applies ablation after steering. A runtime sentinel checks intervention capability (D-021); an architecture name alone does not establish support. Observation remains unpatched through the eval callback (D-012).

**Patch budget rule:** whatever the spike finds, the vendored diff stays as small as upstream allows, lives in `rebirth/src/llama.cpp/patches/`, and every hunk is annotated with why it exists — this is what keeps the `vendor-bump` skill routine (risk #1 in the roadmap).

**Capture spec → memory estimate (D-017, supersedes the f32 basis):** the budget is measured against the **peak resident cost of the materialized R `data.frame` the caller receives**, not the engine's f32 host buffers. `bytes ≈ n_prompts × n_positions × n_layers × n_components × hidden_size × 4 × K`, where the f32 term (`… × 4`) is the engine activation size and `K` (`TRACE_MATERIALIZED_EXPANSION`, pinned to **11** in both `R/trace.R` and `rebirth-llm/src/trace.rs`, each side unit-tested) is the long-format expansion factor: each captured value becomes one 40-byte row (four i32 columns + one f64 `value` + two character-pointer columns), i.e. 10× the f32 bytes asymptotically; **11** upper-bounds this for every trace a *real* model can materialize (`hidden_size ≥ 896` → ≤ 10.65×) and for all budget-relevant large captures (ratio → 10.0×). (A tiny trace amortizes R's fixed per-vector overhead poorly — a sub-600-row capture on the `hidden=32` synthetic test model reaches ~27.75×, but is < ~22 KB and never approaches any budget.) Computed *before* running; drives the predictive OOM check and the spill decision (§6) symmetrically on both sides. An `object.size(result) ≤ K × f32_bytes` test pins `K` so it cannot silently drift. *Why the change:* the f32 basis under-counted the real object ~10× (transient peak ~30× before the FFI de-dup), so an "in-budget" capture could still OOM the 16 GB session (audit finding H-1). The estimate and the filter suggestion appear verbatim in `relm_error_oom`.

## 6. Spill design

- **Format:** Arrow IPC streams (D-013), supported by nanoarrow. The seven columns correspond to `relm_trace`; on disk indices are 0-based, `value` is float32, and text is plain UTF-8. The R reader converts indices to 1-based and values to double. A bounded channel feeds the writer thread during capture.
- **Location:** a managed session directory under `tools::R_user_dir("relm", "cache")/spill/`, or the caller's `spill_dir`. Filenames carry a per-trace nonce and the writer creates files exclusively, refusing existing paths. Only managed directories receive exit cleanup and the existing seven-day age-based sweep; custom directories remain caller-managed.
- **R side:** a spilled `relm_trace` is a zero-row data.frame proxy with file paths in attributes. `as.matrix()` scans stream batches and retains the requested (layer, component) slice. Ordinary data.frame operations act on the empty proxy. Print/summary use capture metadata without materializing the file.
- **Budget:** default in-memory threshold = `min(2 GB, 20% of system RAM)` of the **materialized `data.frame`** (D-017; ~180 MB of f32 activations resident), overridable via `options(relm.trace_budget = <bytes>)`. Above it, `spill = TRUE` streams to disk; `spill = FALSE` raises the predictive `relm_error_oom`.
- **Integrity:** stream schema metadata records format version, a per-trace nonce, model path, and capture-spec key. The reader checks format, trace identity, spec, and schema before consuming batches and maps corruption to `relm_error_trace`. This is staleness/schema detection, not a cryptographic digest of the model or activation payload.

## 7. Determinism implementation

Greedy decoding: deterministic per backend by construction. Sampling: the sampler chain runs on CPU from the returned logits with a dedicated seeded RNG per `llm_generate` call — GPU backend nondeterminism therefore cannot enter token selection; same seed ⇒ same tokens on the same backend/build. The drawn-or-supplied seed is always returned (`attr(result, "seed")`). Cross-backend identity is *not* promised (documented tolerance in harness B) — floating-point op order differs between Metal/CPU/CUDA.

## 8. Error mapping

`rebirth-llm` returns `Result<T, RebirthError>` (an enum mirroring the condition table in `API-GRAMMAR.md` §6, with structured fields: `estimate_bytes`, `expected`/`actual` checksums, overflow sizes). `rebirth-ffi` converts each variant to the corresponding classed R condition; unknown/panic → `relm_error_internal`. Rule: **the R user can always distinguish "you asked wrong" (input conditions) from "we broke" (internal) from "the machine can't" (oom/backend)** — three families, three different "what to try" messages.

## 9. Build pipeline

- `rebirth/src/Makevars` drives `cargo build` (release profile by default; `--offline` for CRAN-mode builds when crates are vendored), links `librelm.a` + llama.cpp objects statically; macOS adds Metal/Accelerate framework flags; feature flags select backends (`metal` default on macOS arm64, `cuda` opt-in from Phase 8).
- `configure` detects cargo/rustc and fails with an actionable message if missing (binary users via r-universe never hit this).
- **CRAN Rust checklist (applies at Phase 9, prepared from day 1):** `SystemRequirements: Cargo (Rust)` with minimum rustc declared; all crates vendored (`cargo vendor` → `src/rust/vendor.tar.xz`), no network at build time; build respects `~/.R/Makevars` and ≤ 2 threads during checks; authors/licenses of vendored crates listed in `inst/AUTHORS`; verified on the CRAN platform matrix before submission.
- Toolchain: Rust >= 1.85.0 for the locked default dependency graph on supported macOS/Linux targets (D-027). CI builds at the floor as well as on stable. `rust-toolchain.toml` selects the moving stable channel, not an exact compiler version; `Cargo.lock` pins dependencies and `vendor/README.md` records engine provenance.

## 10. Async and live-callback design (Phase 5–6, designed now so Phase 0–4 code doesn't preclude it)

**Approved D-037; implementation in progress:** native generation moves to a
single exclusive worker through a checked execution permit and explicit owned
model/context handoff. All native access and destruction participate in the
process-wide domain; R external-pointer wrappers remain !Send/!Sync. R callbacks,
conditions and allocations stay on the R thread, with optional later/promises
integration. Close/GC defers native destruction while another job owns the domain;
unload cancels/joins before code is unmapped. See the approved
[WP9 ownership/lifecycle and acceptance contract](docs/wp9-async-plan.md).
Coalesced progress and bounded result storage precede WP10's separately specified
lossless token channel. No changes to the process-isolated D-034 service.


## 11. Golden pipeline and the synthetic model

- `tests/llm-golden/synthetic/` contains the numpy oracle; `qwen/` contains the HF fp32 activation reference; `vision/` contains upstream vision goldens and tools. The unpatched text-logit comparator remains deferred in `reference/`. See `docs/validation-status.md` for where each check runs.
- **Synthetic model:** an in-repo script writes a seeded 2-layer, tiny-vocab GGUF (~1–2 MB, committed as binary + regeneration script). Purpose: exact-value tests with zero downloads, and a model whose every activation can be recomputed independently in numpy — the harness's bedrock. Regeneration governed by the `golden-update` skill.

## 12. Model registry (`llm_download`)

`inst/models.csv`: `alias, url, sha256, size_bytes, license, notes` — the pinned models from `SOLO-PHASE-PLAN.md` §3. `llm_download()` resolves aliases only from this file (or takes an explicit URL); verification is fail-closed; gated models (MedGemma) get a `notes` entry telling the user to accept terms on HF first — the error message repeats it.

## 13. Ladder mechanics (later rungs, so nothing today blocks them)

- **Rung 2 (distribution, Phase 19):** a bundle = official R installer + `relm` suite preinstalled + a site profile (auto-attach, pinned r-universe snapshot). Nothing in the package may depend on being "the only R" — no global state outside `tools::R_user_dir` paths and documented options.
- **Rung 3 (fork, Phase 21):** playbook archived in `DECISIONS.md`; triggers documented in `DECISIONS.md`. The package's only obligation today: keep `rebirth-llm` R-free (§2) so the future fork can link the same engine.

## 14. Open items (each becomes an ADR when its phase starts)

`later`/`promises` dependency (Phase 5); serve stack choice (Phase 7); fine-tuning backend candle vs libtorch (Phase 12); MLX binding scope (Phase 10); richer data-frame access to spilled traces if required by a future approved API. Ablation and the nanoarrow stream format are settled in D-013/D-016.

## 15. Planned application and service boundaries (D-028)

[The near-term plan](docs/structured-production-plan.md) separates engine work
from the reference application and its operation. None of the new deployment
templates or constrained-output paths is implemented by this planning change.

- **Constraints:** use the existing continuation path, with explicit validation
  of a documented schema subset and bounded grammar resources. Preserve the
  unconstrained sampling path. Conversion, return/error semantics and any new
  dependencies are S0 decisions, not inferred from upstream sampler availability.
- **Batch:** one model-owning process and one writer; persistent per-document
  results, verified configuration identities and restart tests. The application
  owns logs/manifests. Managed spill directories are not durable storage.
- **Service:** an existing HTTP/worker/supervision stack around the same
  application. Start with one persistent model-owning worker; keep admission,
  readiness and deadlines responsive outside a blocking inference call. Forced
  worker exit marks unfinished work interrupted; replacement reloads the model.
  Numeric request/queue/memory limits are set before implementation.
- **Integrations:** optional adapters exchange ordinary data and recreate native
  state from configuration in a fresh process. A serialized retrieval callback
  must not capture a live model pointer. No new generic protocol or storage layer.
- **Later generalization:** the tested template can inform R-ebirth's wider
  analysis-deployment pattern. It neither requires nor completes the generic
  Phase-7 type-contract/compiler or typed endpoint/OpenAPI work.
