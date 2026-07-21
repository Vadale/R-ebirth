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

- An `llm` handle is an R external pointer to `Arc<ModelState>` (weights + tokenizer + backend context). **Interventions never mutate:** `llm_steer`/`llm_ablate` return a new handle = cheap `Arc` clone + an intervention list; weights are shared, never copied. This implements the API-GRAMMAR contract "removal = use the original object".
- **Two deallocation paths:** R GC finalizer (safety net) and `close.llm` (deterministic — on a 16 GB machine the user must be able to free 5 GB *now*). After close, the pointer is tagged; every FFI entry checks the tag → `relm_error_closed`.
- **Threading rules (non-negotiable):** R's C API is single-threaded. Rust may spawn threads (generation, spill writing), but (a) no Rust thread ever calls into R; (b) all SEXP construction happens on the R thread; (c) results cross threads as plain Rust data over channels; (d) Phase 5+ callbacks into R are marshalled to the main thread via the `later` event-loop queue (§10). Violation of these rules is the highest-severity review finding.
- Long operations hold no R allocations: inputs are copied to Rust-owned buffers at entry, results materialize as SEXPs only at exit.

## 4. Index discipline (the canonical defect class)

1-based (R) ↔ 0-based (engine) conversion happens **exactly once**, in `rebirth-ffi`, at named helpers (`to_engine_index`, `from_engine_index`). `rebirth-llm` and llama.cpp speak 0-based only; R speaks 1-based only. Property tests round-trip every index-bearing argument, and harness B's off-by-one mutation test (inject `layer+1` in a scratch branch) must fail loudly.

## 5. Activation taps and interventions (the WP4 core)

**Strategy A (preferred — minimal or zero vendored patching).** llama.cpp already exposes the observation hook we need: the **eval callback** (`cb_eval`, a `ggml_backend_sched_eval_callback` in the context params) — the same mechanism the upstream `llama-imatrix` tool uses to observe intermediate tensors during the forward pass. Graph tensors carry per-layer names (residual/attention/FFN outputs), so the tap = a callback that matches tensor names against the capture spec, copies matching tensors to host buffers (`ggml_backend_tensor_get`), and appends to the trace sink. Callback installed only while tracing → tap-off overhead ≈ 0 (the < 2% acceptance budget).

**Steering (generation-time residual addition):** llama.cpp has **native control-vector support** (per-layer additions to the residual stream via the adapter API). `llm_steer` maps onto it directly — no patch. Composition of stacked steers = summed vectors per layer, computed on our side.

**Ablation:** no native mechanism → the one place Strategy A may not reach. Options, in preference order: (1) implement as a modifying eval-callback if the callback contract permits tensor mutation at that point; (2) a **minimal vendored patch** adding a guarded mutation hook at the named tensors. Decision made by a **1-day spike at WP4 start** (its first step, before any implementation), recorded as an ADR.

**Patch budget rule:** whatever the spike finds, the vendored diff stays as small as upstream allows, lives in `vendor/patches/`, and every hunk is annotated with why it exists — this is what keeps the `vendor-bump` skill routine (risk #1 in the roadmap).

**Capture spec → memory estimate (D-017, supersedes the f32 basis):** the budget is measured against the **peak resident cost of the materialized R `data.frame` the caller receives**, not the engine's f32 host buffers. `bytes ≈ n_prompts × n_positions × n_layers × n_components × hidden_size × 4 × K`, where the f32 term (`… × 4`) is the engine activation size and `K` (`TRACE_MATERIALIZED_EXPANSION`, pinned to **11** in both `R/trace.R` and `rebirth-llm/src/trace.rs`, each side unit-tested) is the long-format expansion factor: each captured value becomes one 40-byte row (four i32 columns + one f64 `value` + two character-pointer columns), i.e. 10× the f32 bytes asymptotically; **11** upper-bounds this for every trace a *real* model can materialize (`hidden_size ≥ 896` → ≤ 10.65×) and for all budget-relevant large captures (ratio → 10.0×). (A tiny trace amortizes R's fixed per-vector overhead poorly — a sub-600-row capture on the `hidden=32` synthetic test model reaches ~27.75×, but is < ~22 KB and never approaches any budget.) Computed *before* running; drives the predictive OOM check and the spill decision (§6) symmetrically on both sides. An `object.size(result) ≤ K × f32_bytes` test pins `K` so it cannot silently drift. *Why the change:* the f32 basis under-counted the real object ~10× (transient peak ~30× before the FFI de-dup), so an "in-budget" capture could still OOM the 16 GB session (audit finding H-1). The estimate and the filter suggestion appear verbatim in `relm_error_oom`.

## 6. Spill design

- **Format:** Arrow IPC (Feather v2) files, schema = the `relm_trace` columns exactly (`API-GRAMMAR.md` §2). Written incrementally by `rebirth-llm`'s sink thread during capture (bounded channel → backpressure, never unbounded buffering).
- **Location:** `tools::R_user_dir("relm", "cache")/spill/<session-id>/trace-<n>.arrow`. Session directory registered for cleanup at R exit (`reg.finalizer` on a session sentinel + startup sweep of orphaned directories older than 7 days).
- **R side:** a spilled `relm_trace` holds file paths in attributes; `nanoarrow` reads lazily on first data access; `as.matrix()` reads only the requested (layer, component) slice. Print/summary never force a full load.
- **Budget:** default in-memory threshold = `min(2 GB, 20% of system RAM)` of the **materialized `data.frame`** (D-017; ~180 MB of f32 activations resident), overridable via `options(relm.trace_budget = <bytes>)`. Above it, `spill = TRUE` streams to disk; `spill = FALSE` raises the predictive `relm_error_oom`.
- **Integrity:** each file footer carries the capture spec + model SHA; reopening a file whose spec doesn't match the object's attributes → `relm_error_trace` (tamper/staleness fail-safe).

## 7. Determinism implementation

Greedy decoding: deterministic per backend by construction. Sampling: the sampler chain runs on CPU from the returned logits with a dedicated seeded RNG per `llm_generate` call — GPU backend nondeterminism therefore cannot enter token selection; same seed ⇒ same tokens on the same backend/build. The drawn-or-supplied seed is always returned (`attr(result, "seed")`). Cross-backend identity is *not* promised (documented tolerance in harness B) — floating-point op order differs between Metal/CPU/CUDA.

## 8. Error mapping

`rebirth-llm` returns `Result<T, RebirthError>` (an enum mirroring the condition table in `API-GRAMMAR.md` §6, with structured fields: `estimate_bytes`, `expected`/`actual` checksums, overflow sizes). `rebirth-ffi` converts each variant to the corresponding classed R condition; unknown/panic → `relm_error_internal`. Rule: **the R user can always distinguish "you asked wrong" (input conditions) from "we broke" (internal) from "the machine can't" (oom/backend)** — three families, three different "what to try" messages.

## 9. Build pipeline

- `rebirth/src/Makevars` drives `cargo build` (release profile, `--offline`), links `librebirth_ffi.a` + llama.cpp objects statically; macOS adds Metal/Accelerate framework flags; feature flags select backends (`metal` default on macOS arm64, `cuda` opt-in from Phase 8).
- `configure` detects cargo/rustc and fails with an actionable message if missing (binary users via r-universe never hit this).
- **CRAN Rust checklist (applies at Phase 9, prepared from day 1):** `SystemRequirements: Cargo (Rust)` with minimum rustc declared; all crates vendored (`cargo vendor` → `src/rust/vendor.tar.xz`), no network at build time; build respects `~/.R/Makevars` and ≤ 2 threads during checks; authors/licenses of vendored crates listed in `inst/AUTHORS`; verified on the CRAN platform matrix before submission.
- Reproducibility: `rust-toolchain.toml` pins the toolchain; `Cargo.lock` committed; vendored llama.cpp tag + SHA in `vendor/README`.

## 10. Async and live-callback design (Phase 5–6, designed now so Phase 0–4 code doesn't preclude it)

Generation moves to a Rust worker thread; tokens flow over a bounded channel; the R side drains it via the `later` event loop (likely dependency — ADR when Phase 5 starts), resolving a `promises` promise on completion. `on_token` callbacks (Phase 6) are queued to the main R thread — never called from the worker. The Phase 0–4 obligation is only: keep `rebirth-llm`'s generation API channel-friendly (iterator/callback-based internally, not one blocking call that returns a final string).

## 11. Golden pipeline and the synthetic model

- `tests/llm-golden/generate/` holds pinned Python scripts (venv lockfile committed) that produce: logit goldens (reference llama.cpp, same tag, unpatched) and activation goldens (HF transformers fp32).
- **Synthetic model:** an in-repo script writes a seeded 2-layer, tiny-vocab GGUF (~1–2 MB, committed as binary + regeneration script). Purpose: exact-value tests with zero downloads, and a model whose every activation can be recomputed independently in numpy — the harness's bedrock. Regeneration governed by the `golden-update` skill.

## 12. Model registry (`llm_download`)

`inst/models.csv`: `alias, url, sha256, size_bytes, license, notes` — the pinned models from `SOLO-PHASE-PLAN.md` §3. `llm_download()` resolves aliases only from this file (or takes an explicit URL); verification is fail-closed; gated models (MedGemma) get a `notes` entry telling the user to accept terms on HF first — the error message repeats it.

## 13. Ladder mechanics (later rungs, so nothing today blocks them)

- **Rung 2 (distribution, Phase 19):** a bundle = official R installer + `relm` suite preinstalled + a site profile (auto-attach, pinned r-universe snapshot). Nothing in the package may depend on being "the only R" — no global state outside `tools::R_user_dir` paths and documented options.
- **Rung 3 (fork, Phase 21):** playbook archived in `DECISIONS.md`; triggers documented in `DECISIONS.md`. The package's only obligation today: keep `rebirth-llm` R-free (§2) so the future fork can link the same engine.

## 14. Open items (each becomes an ADR when its phase starts)

`later`/`promises` dependency (Phase 5); ablation strategy A-vs-B (WP4 spike, day 1); serve stack choice (Phase 7); fine-tuning backend candle vs libtorch (Phase 12); MLX binding scope (Phase 10); `nanoarrow` vs `arrow` if lazy-read needs grow (revisit at Phase 2 exit).
