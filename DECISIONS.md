# DECISIONS.md — Architecture Decision Records

Append-only log of decisions that would be expensive to reverse. Format: `ID / date / status / decision / why / alternatives rejected`. New entries start as `proposed`; only the founder moves them to `accepted`. Nothing here is relitigated in code sessions — a superseding ADR is the only way to change an accepted decision.

---

## D-001 — API grammar is base-R idiom
- **Date:** 2026-07-03 · **Status:** accepted
- **Decision:** the public surface follows base R: S3 classes and generics (`print`/`summary`/`plot`/`predict`), plain `data.frame`/`matrix` returns, native `|>`, `llm_*` prefix, formula interfaces where natural, no tidyverse dependencies in the package.
- **Why:** the target user is a researcher who knows `lm()` and `summary()`; they must feel at home (founder guideline). Tidyverse interop comes free because returns are standard structures.
- **Alternatives rejected:** tidyverse-style API (dependency footprint, wrong idiom for the audience); OOP-style R6 interface (exactly the style the project exists to avoid).

## D-002 — Delivery is the three-rung ladder; rung 1 = package on stock R
- **Date:** 2026-07-03 · **Status:** accepted
- **Decision:** ship as the `rebirth` package suite on unmodified R ≥ 4.5 (rung 1); a curated distribution later (rung 2); a fork of GNU R only in the community era (rung 3, team-gated — see Appendix A and `ROADMAP.md` Phase 21).
- **Why:** adoption (`install.packages` vs replace-your-R), zero compatibility risk, no permanent upstream-merge tax, Windows drastically cheaper, and permissive licensing becomes possible (D-002 side effect: everything original is dual MIT OR Apache-2.0).
- **Alternatives rejected:** day-1 deep fork of GNU R (GPL inheritance, merge tax, hardest-platform costs, adoption friction); from-scratch language (the FastR/Renjin graveyard: the C-API/ecosystem bridge is the product, and a new language starts with zero ecosystem).

## D-003 — API-GRAMMAR.md v1.0 approved and binding
- **Date:** 2026-07-04 · **Status:** accepted
- **Decision:** the founder approved `API-GRAMMAR.md` v1.0 in full, explicitly including the three flagged choices: (1) `llm_trace()` defaults to `positions = "last"`, `components = "residual"` (memory-safe defaults); (2) `llm_steer()`/`llm_ablate()` return a **new** handle and never mutate (removal = use the original object); (3) plain-English argument names (`context_length`, `gpu_layers`), engine jargon only as a doc annotation.
- **Why:** spec-first rule — the public surface is the one thing that cannot be refactored later without breaking users' scripts.
- **Alternatives rejected:** capture-everything trace default (OOM-prone on the 16 GB primary machine); in-place model mutation (hidden state, breaks the bit-for-bit reversal acceptance test); `n_ctx`-style jargon (researchers first).

## D-004 — Thesis case study parked
- **Date:** 2026-07-04 · **Status:** accepted
- **Decision:** WP-T (the MedGemma audit, `THESIS-PLAN.md`) is parked until the founder's thesis is assigned (~6–8 months, ≈ Q1–Q2 2027). `llm_probe()` (Phase 4) proceeds as a core capability regardless. WP-T gates nothing.
- **Why:** the assignment date is outside the founder's control; the software will be ahead of the thesis's needs (Phases 1–2 + `llm_probe`) by resumption time.

## D-005 — Rust crate layout: one package-embedded workspace
- **Date:** 2026-07-04 · **Status:** accepted
- **Decision:** consolidate both native crates into a single cargo workspace embedded in the package at `rebirth/src/rust/` (members `rebirth-ffi`, `rebirth-llm`); delete the orphaned top-level `rust/`. `rebirth-ffi` is the extendr boundary crate but keeps `[lib] name = "rebirth"` and the `mod rebirth;` module name, so `entrypoint.c`, `rebirth-win.def`, `NAMESPACE`, `document.rs`, and `-lrebirth` are unchanged (≈ zero churn); `rebirth-llm` is a workspace sibling and path dependency, R-free and independently testable. Full analysis in `docs/wp1-plan.md`.
- **Why:** the top-level `rust/` (the `SOLO-PHASE-PLAN.md` §4 sketch) escapes the package directory, so it is absent in the `R CMD check` tempdir and forbidden by CRAN (ARCHITECTURE §9); embedding under `src/` is self-contained by construction while preserving the three-layer FFI/engine separation (§2/§13). This supersedes the §4 top-level-`rust/` layout sketch (a plan sketch, not a prior ADR).
- **Alternatives rejected:** path-depend on `../../../rust` (escapes the package → check/CRAN build fails — this was the WP0 orphaning bug); copy or symlink crates in at configure time (tarball/reproducibility fragility); collapse into one flat crate (breaks the R-free engine and unsafe-isolation invariants, §2/§13).
- **Note:** accepted by Claude under the founder's 2026-07-04 autonomy grant — an internal structural decision with no external impact; recorded here for the founder's standing review.

## D-006 — llama.cpp vendoring and native build
- **Date:** 2026-07-04 · **Status:** accepted
- **Decision:** vendor a pinned, pruned llama.cpp source snapshot inside the package at `rebirth/src/llama.cpp/` (upstream tag + tree SHA256 recorded in `src/llama.cpp/VENDORING.md`, mirrored as a provenance record in `vendor/README.md`/`NOTICE`); build it from `rebirth-llm/build.rs` via the newly authorized `cmake` build-dependency crate — Metal + embedded shaders on macOS arm64, CPU elsewhere, CUDA behind a default-off `cuda` feature until Phase 8; declare the small FFI surface as hand-written `extern "C"` (no bindgen); apply no source patches in WP1 (taps are WP4). `SystemRequirements` gains `cmake (>= 3.28)` with a `configure` presence check. Full analysis in `docs/wp1-plan.md`.
- **Why:** self-containment (D-005 / §9 — a git submodule or a configure-time download breaks the check tempdir and CRAN's no-network rule); cmake is upstream's supported build path (hand-rolling ggml backend registration and Metal-shader embedding would drift on every bump, defeating the `vendor-bump` skill); a tiny hand-written FFI surface stays auditable without a `libclang`/bindgen toolchain dependency.
- **Alternatives rejected:** git submodule or configure-time download (absent in the tarball / violate CRAN no-network); `cc`-crate hand-compile (brittle vs upstream cmake); dynamic-link a system `libllama` (no stable ABI across `bNNNN` tags); bindgen (adds libclang for a handful of symbols and enlarges the audited unsafe surface).
- **Dependency authorization:** this ADR authorizes the Rust build-dependency `cmake` and the `cmake (>= 3.28)` SystemRequirement — the only new dependencies WP1 introduces. Accepted by Claude under the founder's 2026-07-04 autonomy grant; **flagged for the founder** as the one WP1 decision that touches the "no new dependency without an approved entry" rule.
- **Pinned tag:** selection criteria in `docs/wp1-plan.md` (immutable `bNNNN` release with gemma3 + qwen2 support, settled C API, mature Apple-silicon Metal, ~2–4 weeks old); the exact tag is finalized at vendoring time (WP1 Step 1) and recorded with its tree SHA256.

---

## D-007 — Argument-validation errors are classed conditions
- **Date:** 2026-07-05 · **Status:** accepted (founder-approved 2026-07-05)
- **Decision:** add `rebirth_error_argument` to `API-GRAMMAR.md` §6 as the package-wide class for invalid user arguments (wrong type/length/range) caught by R-side validation before the native boundary. `llm()`'s `context_length`/`gpu_layers`/`mmap` checks raise it (via `rebirth_abort()`), carrying an `argument` field that names the offending parameter. `path` → `rebirth_error_model_load` and `backend` → `rebirth_error_backend` are unchanged (their §6 semantics predate this).
- **Why:** grammar rule §1.8 requires *every* error to be a classed condition; before this, those three checks raised bare base-R `stop()`, an internal inconsistency in the approved grammar. One cross-cutting class (rather than per-function argument classes) keeps the hierarchy small while making input errors programmatically catchable.
- **Alternatives rejected:** leave them as base-R errors (violates §1.8); reuse `rebirth_error_model_load` (wrong semantics — these are not load failures); a distinct argument class per function (needless proliferation for identical validation failures).

---

## D-008 — WP1 security audit: accepted; ship, with tracked gates
- **Date:** 2026-07-05 · **Status:** accepted
- **Decision:** the WP1 FFI/`unsafe` boundary passed a security audit and ships. Verified sound for WP1's threat model (local, trusted-ish model files, single-threaded R): the two by-value `#[repr(C)]` param structs match `llama.h` at b9726 field-for-field; `meta_str` two-call sizing is correct; the model lifecycle is take-once (no double-free/UAF across `close.llm` + the GC finalizer + extendr's finalizer); panics are caught (manual + extendr's outer `catch_unwind`); C++ exceptions never cross `extern "C"`. Two cheap fixes were applied now: widen the boundary `catch_unwind` to cover the metadata snapshot + payload construction, and drop the `description()` trailing NUL.
- **Tracked gates (required predecessors, logged so they are not rediscovered under deadline):**
  - **G1 (Phase 3, downloads):** a malformed-but-magic-valid GGUF can trip a `GGML_ASSERT`/`GGML_ABORT` → `abort()`, killing the R session uncatchably. Before model files become untrusted internet downloads: load untrusted models in a subprocess (isolation) and make checksum/provenance verification fail-closed; add a valid-magic-malformed GGUF corpus/fuzz test.
  - **G2 (WP4 / Phase 5, threads):** `unsafe impl Send + Sync for Model/Context` is asserted, not enforced. Before any background Rust thread exists, enforce the R-main-thread invariant (thread-id `debug_assert!` in the getters/Drop, or keep the R-facing handle `!Send`).
  - **G3 (when any handle-taking FFI entry is exported):** foreign `EXTPTRSXP` type confusion — `try_from::<&ExternalPtr<LlmHandle>>` reads the payload before the downcast. The close/is-closed entries are internal now; add an `R_ExternalPtrTag` check if ever exported.
  - **G4 (CI hardening):** wire `cargo audit` + `cargo deny`, and have CI recompute and assert the vendored pruned-tree SHA256 (from `VENDORING.md`) so a silent change to the vendored engine is caught.
- **Why:** none of the findings is exploitable under WP1's model, so WP1 is not blocked; but G1–G4 are genuine predecessors for later phases and are far cheaper to honor now than to rediscover under a deadline.

---

## D-009 — `unsafe` is partitioned by boundary (corrects the "all unsafe in rebirth-ffi" statement)
- **Date:** 2026-07-05 · **Status:** accepted (flagged for the founder)
- **Decision:** the WP1 review found the implemented `unsafe` split inverts the earlier statement (`ARCHITECTURE.md` §2.2, this log, `docs/wp1-plan.md`) that "`rebirth-ffi` is the only crate allowed `unsafe`." The correct, implemented design partitions `unsafe` by *boundary*: `rebirth-ffi` owns any **R-side (SEXP)** `unsafe` — of which WP1 needs **none**, because extendr's safe `ExternalPtr`/`Robj` API abstracts SEXP handling — and `rebirth-llm` owns the **C-side (llama.cpp FFI)** `unsafe`, kept minimal and individually SAFETY-commented, while staying R-free. `ARCHITECTURE.md` §2.2/§2.3 and the layer diagram are updated to state this; the crate split and the R-free-engine invariant are unchanged.
- **Why:** the C-FFI `unsafe` necessarily lives with the engine wrapper that calls llama.cpp (`rebirth-llm`); forcing it into `rebirth-ffi` would drag R-free engine code across the boundary. The original wording predated the "extendr's safe API abstracts SEXP" realization. Leaving the docs contradicting the sound, audited code would mislead the next contributor and the security-auditor, which gates on this invariant.
- **Alternatives rejected:** move the llama FFI into `rebirth-ffi` (breaks the R-free engine / independent reusability — D-005 / §2.3); leave the docs as-is (a "non-negotiable" rule silently contradicting the code).

---

## D-010 — `v1.0` scope stays lean; fine-tuning, RL, and `rebirth.bio` follow post-`v1.0`
- **Date:** 2026-07-06 · **Status:** accepted (founder delegated the choice to Claude, 2026-07-06)
- **Decision:** `v1.0` (roadmap Phase 9) freezes the *interpretability + embeddings + topics + probe + serving* core and nothing heavier. Fine-tuning (Phase 12), alignment/RL (Phase 13), topics + SAE productization (Phase 14), and `rebirth.bio` (Phase 18) stay in the solo track but are sequenced **after** `v1.0`, each shippable on its own. One concession pulled earlier: an *optional* protein-LM proof-of-concept ("Demo C", ROADMAP WP7) that rides the existing embed/trace machinery and does **not** gate Phase 3.
- **Why:** `v1.0` freezes the `llm_*` API forever, so it must be the small, rock-solid core — not a construction site. Fine-tuning/RL need a training-backend ADR (candle vs libtorch/R-torch) and a real GPU story; folding them into pre-`v1.0` would balloon the solo lift and push the first CRAN release out ~a year. Every phase already ships, so nothing is lost by sequencing. The founder's full vision is preserved: all of it is solo, none team-gated.
- **Alternatives rejected:** a "complete" `v1.0` bundling training/RL/bio (much later, riskier first release, a heavier API surface locked prematurely); cancelling any of them (they stay — only their order is fixed).

---

## D-011 — WP3 embedding-context strategy
- **Date:** 2026-07-06 · **Status:** accepted (founder-approved 2026-07-06)
- **Decision:** serve `llm_embed()` from a **dedicated, transient embeddings-mode llama context created once per call** (not cached on the handle, not the generation context), configured `embeddings = true`, `pooling_type = NONE`, `attention_type = UNSPECIFIED` (llama auto-selects causal for generative models, non-causal for encoders), and sized to the batch's longest input (`n_ctx = n_batch = n_ubatch = min(longest input, handle context_length)`, so every sequence fits one `llama_decode` — required for non-causal encoders and avoiding the `GGML_ASSERT(n_tokens_all <= n_batch)` abort). **All pooling is done in Rust** over the per-token post-final-norm hidden states from `llama_get_embeddings_ith`: `"mean"` = average of the token rows, `"last"` = the final token row, `"model"` = the reduction named by the GGUF `<arch>.pooling_type` metadata (MEAN→average, CLS→first token, LAST→last token). `normalize = TRUE` = L2 per row, in Rust. `"model"` when the model defines no pooling (NONE / key absent, e.g. Qwen2.5) → `rebirth_error_embed` telling the user to pass `"mean"`/`"last"`; RANK (reranker) pooling → `rebirth_error_embed` (RANK is not an embedding); any unknown pooling enum → `rebirth_error_embed`. The only new FFI symbol is `llama_get_embeddings_ith`; the model's pooling is read via the existing `llama_model_meta_val_str`. Full analysis in `docs/wp3-embed-plan.md`.
- **Why:** the generation context (`engine.rs::load()`) is causal and created with `embeddings = false` and model-default (UNSPECIFIED) pooling, so it can neither serve the per-call `pooling` choice nor compute correct vectors for the dedicated encoder GGUFs WP3 must support (ROADMAP §5 WP3). A NONE-pooling context yields per-token `result_norm` states — the exact tensor the numpy oracle already computes (`reference_forward.py:174`, before the LM head) — so `mean`/`last`/`model` collapse to one Rust reduction that is exactly golden-testable against the synthetic model, and MEAN/CLS/LAST reductions are bit-identical to llama's own internal pooling (llama runs no trained pooler for embeddings), so nothing is lost by pooling in Rust. Leaving `attention_type` UNSPECIFIED is the only setting correct for both decoders (causal) and encoders (non-causal) without a per-model branch. A per-call transient context needs no interior mutability on the `Arc`-shared, `unsafe impl Send + Sync` handle (keeps D-008 gate G2 simple) and respects the 16 GB rule (compute buffers sized to the batch, freed at call end). This adds exactly one hand-written FFI symbol, honoring D-006's minimal surface, and writes only `pooling_type`/`attention_type`/`embeddings` on the by-value `llama_context_params`, whose offsets were re-verified against `llama.h` b9726 and are guarded by an executable default-value ABI test (D-008 checkpoint).
- **Alternatives rejected:** reuse the generation context via `llama_set_embeddings(ctx, true)` + per-token reads (works only for generative models whose default pooling is NONE; gives no per-call pooling otherwise, perturbs the generation KV state, and has no path to encoder GGUFs); two contexts — a NONE context for `mean`/`last` plus a model-pooling context using `llama_get_embeddings_seq` for `"model"` (doubles KV/compute buffers, splits `"model"` onto a second numeric path harder to golden, and buys nothing because MEAN/CLS/LAST are exact Rust reductions and RANK is an error either way); a per-handle cached embedding context (saves context allocation across calls but forces interior mutability into the `Send + Sync` handle — reopening D-008 G2 — for negligible gain, since `llm_embed` already batches the whole input through one context; recorded as a future optimization); forcing `attention_type = CAUSAL` (breaks encoders) or `NON_CAUSAL` (corrupts decoder embeddings).

---

## D-012 — activation-tap strategy (observation zero-patch; ablation via a guarded `build_cvec` patch)
- **Date:** 2026-07-06 · **Status:** accepted (founder delegated the call to Fable 5, 2026-07-06; the Opus architect and Fable 5 independently concurred)
- **Decision:** the WP4 day-1 spike, run against the vendored engine at b9726, decides:
  **(A) Observation (`llm_trace`, WP4): Strategy A, zero vendored patch.** Tap the forward pass via llama.cpp's scheduler eval callback (`ggml_backend_sched_eval_callback`; the `cb_eval`/`cb_eval_user_data` context params are already mirrored at `ffi.rs:118-119`, currently null). A dedicated, transient **trace context** is created per `llm_trace` call (the D-011 pattern) with `cb_eval` set to a Rust `extern "C"` trampoline whose body is wrapped in `catch_unwind` (a panic must never unwind across the C ABI into the scheduler); the generation context never gets a callback, so tap-off overhead is structurally zero. At `ask=false` (fired after `ggml_backend_synchronize`, so data is ready) the matched tensor is copied host-side via `ggml_backend_tensor_get`. Tensors are matched by name — `l_out-<il>`=residual, `ffn_out-<il>`=mlp_out, `attn_out-<il>`(llama, post-projection) or `kqv_out-<il>`(qwen2 and gemma3, pre-projection)=attn_out, `<il>` the 0-based engine layer — via a small per-architecture matcher (NOT a `{attn_out,kqv_out}` union: a llama graph carries both, and the union would capture the wrong tensor); an unmatched component → `rebirth_error_trace` (never a silent empty capture). **Corrected from source (2026-07-06):** the pre-review claim "gemma→`attn_out`" was wrong — gemma3 builds attention through the shared `build_attn` (like qwen2) and names only `kqv_out-<il>` (pre-projection), no `attn_out-<il>`; matching `attn_out` there would silently capture nothing. **Open item (→ WP6b):** because only llama names the post-projection output, the `attn_out` component is post-projection on llama-family but pre-projection (kqv) on qwen2/gemma3 — a cross-architecture semantic inconsistency to reconcile when WP6b wires the HF qwen2 activation golden (standardize on pre-projection everywhere, or `rebirth_error_trace` where post-projection is unavailable). WP4 tests only llama's post-projection `attn_out` (the synthetic golden), so this does not affect WP4 correctness. New FFI = an opaque `ggml_tensor` type + accessors `ggml_get_name`/`ggml_nbytes`/`ggml_nelements`/`ggml_backend_tensor_get` (no struct mirror), honoring D-006's minimal surface; the size-160 ABI test gains a `cb_eval`/`cb_eval_user_data` null-default assertion.
  **(B) Ablation (`llm_ablate`, WP5): a minimal, guarded vendored patch** at the residual choke point `llm_graph_context::build_cvec` (`src/llama-graph.cpp`), extended (or a sibling `build_intervene`) to apply a registered per-layer ablation mask, **byte-identical to the unpatched build when no ablation is registered** (preserving the harness-B baseline and the WP5 bit-for-bit reversal). It is native (Metal computes it as a graph op — no host-mutation-visibility question), generation-hot-path efficient, and reversible by construction. **Architecture coverage:** `build_cvec` is present in all pinned/CI/demo architectures (llama, qwen2, gemma3) — exactly the coverage of llama.cpp's native control vectors — but NOT universal (verified: 106 of 134 model graphs at b9726 call it; BERT-class encoders, SSMs, and some MoEs lack the choke point), so `llm_ablate`/`llm_steer` share one support matrix and WP5 must **detect an unsupported architecture and raise `rebirth_error_intervention`, never silently no-op.** Patch size, honestly: the application point is single-site, but threading the ablation spec through `llm_graph_context` mirrors the existing control-vector plumbing (~5 files, ~100–200 lines) — small and mechanical, inside the D-006 patch budget, annotated per hunk in `rebirth/src/llama.cpp/patches/`, re-applied by `vendor-bump`. The modifying eval-callback (ARCHITECTURE §5 option 1) is retained ONLY as a named zero-patch fallback that, if chosen, requires an empirical CPU+Metal mutation probe before WP5. Steering (WP5) needs zero patch (native control-vector path). Full analysis in `docs/wp4-trace-plan.md`.
- **Why:** the scheduler's own invocation code (`ggml-backend.cpp` L1677-1714) + the documented `ask` contract prove observation works with no patch. For ablation the callback is rejected as the primary mechanism on three grounds Fable 5 sharpened: (1) **contract** — the callback is documented as observation-only (`ggml-backend.h` L311), and an in-line upstream TODO at the exact synchronize point (`ggml-backend.cpp` L1705) reserves the right to remove the unconditional sync that makes host mutation even plausible, so a probe would certify only today's build and must be re-run every vendor-bump anyway; (2) **failure mode** — the patch fails LOUD (a vendor-bump merge conflict or a red harness-B byte-identity check), whereas callback mutation fails SILENT (a write not visible downstream → the model generates *unablated* outputs *labeled* ablated, poisoning the WP5 honesty fixture and any published `llm_ablate` result — the worst failure class for an interpretability tool); (3) **Metal correctness is runtime-variable** (shared buffers are conditional on unified memory and toggleable via `GGML_METAL_SHARED_BUFFERS_DISABLE`), while the graph op is correct on every backend by construction and adds no per-token scheduler de-batching for an always-on intervention. ARCHITECTURE §5 charters the spike to make exactly this call and conditions its option (1) on "if the callback contract permits tensor mutation" — the finding is that it does not certifiably permit it.
- **Alternatives rejected:** modifying eval-callback as the PRIMARY ablation mechanism (off-contract; silent-failure risk; unproven on Metal; per-token scheduler de-batching for an always-on path); per-model patches at each `cb(...,"l_out"/...)` naming site (many sites per arch → high vendor-bump cost); mirroring the full `ggml_tensor` struct to write `t->data` directly (fragile ABI, larger unsafe surface than accessors); installing `cb_eval` on the generation context (non-zero tap-off overhead); reusing the control-vector API for ablation (a fixed additive vector cannot express `x[k]:=value`, which depends on the computed activation).
- **Backlog (flagged now):** Phase 18 `rebirth.bio` targets ESM-2/DNABERT-class encoders, which are BERT-class and therefore have NEITHER native steering NOR this ablation choke point — the intervention path for encoders is an open Phase-18 question, surfaced here so `rebirth.bio` planning does not discover it late.

---

## D-013 — spill dependencies (Arrow IPC writer + reader)
- **Date:** 2026-07-06 · **Status:** accepted (founder delegated the call to Fable 5, 2026-07-06; the Opus architect and Fable 5 independently concurred)
- **Decision:** authorize two NEW dependencies for the WP4 `llm_trace(spill=)` path — the R package **`nanoarrow`** (lazy Arrow-IPC reader) and the Rust **`arrow-ipc`** writer with its minimal subcrates (`arrow-array`, `arrow-buffer`, `arrow-data`, `arrow-schema`, `flatbuffers`), `default-features = false` (no compression codecs, chrono, parquet, csv, json), behind a `spill` **cargo feature** (default on) so a no-spill build carries none of it. Spill writes **Arrow IPC — file or stream format, fixed at implementation after verifying the pinned `nanoarrow` reader's random-access support (a Step-5 day-1 check; the stream format with sequential message-skipping over the `(prompt, layer)` batching is the fallback if file-format random access is unavailable at the pinned version)** — with the 7-column `rebirth_trace` schema, record-batched by `(prompt, layer)` so `as.matrix()` reads only a slice. **`value` is stored as float32 on disk** (the engine truth; widened to R double at read, exact) and `token`/`component` are dictionary-encoded, ~halving spill size at zero information cost. The file footer carries the capture spec + model SHA (staleness fail-safe, ARCHITECTURE §6). Exact versions pinned at implementation; `Cargo.lock` + `src/rust/vendor.tar.xz` committed. Full analysis in `docs/wp4-trace-plan.md`.
- **Why:** the dependency question is not open, only its timing — Arrow IPC written by Rust + read lazily via `nanoarrow` is settled architecture (ARCHITECTURE §6, the stack table). The decisive ground (Fable 5): **API-GRAMMAR §1 rule 6 is binding (D-003)** — "any function that can exceed memory must support disk spill rather than crash" — so shipping `llm_trace` with `spill = TRUE` in its approved signature but nothing behind it would violate an approved grammar rule at any release boundary; a spill implementation is mandatory before Phase 3 regardless. `nanoarrow` is the purpose-built lightweight Apache-maintained CRAN reader (ARCHITECTURE §14 pre-flags it as the Phase-2 choice); `arrow-ipc` is the mainstream maintained writer, and `default-features = false` strips the codec/parquet/chrono weight. Session-safety itself is delivered by the predictive `rebirth_error_oom` (before allocation); spill adds *capability* (completing an over-budget capture), whose real customers are the WP4 full-capture acceptance, Phase 6 streaming traces, and Phase 14 SAE datasets.
- **Alternatives rejected:** the full **`arrow` R package** (heavy bundled C++ Arrow, slow install, no benefit for the lazy slice reads `nanoarrow` does natively); the full **`arrow` Rust crate** with default features (codecs/parquet/csv/json/chrono — dead vendor-tarball weight); **hand-written Arrow IPC** (correctness risk, off the critical path); **deferring spill to a WP4b** (buys ~2–3 weeks but re-opens an ADR/review cycle and leaves an approved default — §1.6 — unimplemented; if WP4's schedule overflows, split at **Step 5** as the pre-agreed point without a second decision round-trip, since dependency approval is already granted here).
- **CRAN implication:** the arrow-rs subtree enlarges `src/rust/vendor.tar.xz` (an installed-size NOTE at worst, prepared for at Phase 9); `nanoarrow` is a normal `Imports:`. Both are Apache-2.0, compatible with the package's MIT OR Apache-2.0.
- **Dependency authorization (the no-new-dependency rule):** this ADR is the required approval for `nanoarrow` (R) and `arrow-ipc` + its minimal subcrates (Rust); no other new dependency is authorized.
- **Implementation outcome (2026-07-06, WP4 Step 5):** the pinned reader is `nanoarrow` 0.8, whose day-1 check settled the two "fixed at implementation" points of this ADR: it reads Arrow IPC **streams** only (no file-format/footer random access) and **rejects dictionary-encoded** streams (`read_nanoarrow()` → "Schema message field with DictionaryEncoding not supported"). So the writer emits the **IPC stream format** (the fallback this ADR anticipated — a `(layer, component)` slice is reached by pulling record batches sequentially over the `(prompt, layer)` batching) with **plain UTF-8** `token`/`component` (the addendum-#5 dictionary-encoding is dropped — reader compatibility, the binding acceptance, wins over the encoding optimization); `value` remains **float32** on disk (the dominant column, so most of the size saving is kept). `vendor.tar.xz` is not committed (a Phase-9/CRAN artifact, ARCHITECTURE §9; CI builds online via the standard r-lib workflow); for the record, the arrow + flatbuffers crates add ~0.52 MB compressed (~10.2 MB uncompressed source) to a full vendor tarball.

---

## D-014 — `attn_out` component semantics: post-projection everywhere, honest error where unobservable
- **Date:** 2026-07-06 · **Status:** accepted (founder delegated the call to Fable 5, 2026-07-06; resolves D-012's open item)
- **Decision:** the `attn_out` component of `llm_trace()` is permanently defined as the attention sub-layer output **AFTER the output projection `Wo`** (pre any post-attention norm) — the TransformerLens `hook_attn_out` object, `hidden_size` wide, on every architecture. At b9726 this tensor is named only by llama-family graphs (`attn_out-<il>`, `models/llama.cpp` L172); qwen2 and gemma3 build attention through the shared `build_attn` and name only the pre-projection `kqv_out-<il>` (`llama-graph.cpp` L2261 ff., before the `wo` matmul), so on those architectures `llm_trace(components = "attn_out")` raises `rebirth_error_trace` listing the available components (`residual`, `mlp_out`) — never a silent substitute, never a silent empty capture. The D-012/WP4 matcher arms mapping qwen2/gemma3 → `kqv_out` are removed; **no golden changes** (WP4's only `attn_out` consumer is the llama synthetic golden). Follow-ups chartered, NOT authorized here: (1) a **naming-only** vendored patch (a `ggml_format_name`/`cb` at the shared `build_attn` tail, or one `cb(cur,"attn_out",il)` line each in `qwen2.cpp`/`gemma3.cpp`) to expose post-projection `attn_out` on the pinned non-llama archs — **byte-identical computation** (harness-B logit equality untouched), lighter than the pre-authorized `build_cvec` patch, but it needs its own ADR at WP5 (riding the D-012 patch PR) or WP6b at latest, so the qwen2 HF activation golden (HF side: hook `o_proj` output) can cover `attn_out`; (2) a distinct **pre-projection component** (e.g. `attn_heads`, the `z` object) for head-level analysis — an `API-GRAMMAR.md` addition requiring founder sign-off, natural pairing with the WP5 head-ablation stretch. Full analysis in the Fable-5 review captured under `docs/wp4-trace-plan.md`.
- **Why:** (1) **honesty limits** — one name over two different tensors silently invalidates cross-architecture comparisons, the exact failure class the tool exists to prevent; D-012's fails-loud-over-fails-silent principle governs. (2) **The binding grammar already encodes post-projection:** API-GRAMMAR §4 documents `as.matrix.rebirth_trace` slices as `hidden_size` wide, and the pre-projection width (`n_head × head_dim`) ≠ `hidden_size` on every gemma3 size — Gemma-3 4B / **MedGemma-1.5-4B** (the pinned thesis model): 8×256 = 2048 vs `hidden_size` 2560 — so pre-projection-as-`attn_out` would breach an approved return-shape promise on the pinned thesis model. (3) **Mech-interp convention:** `attn_out` = the post-`Wo` residual-space contribution (TransformerLens `hook_attn_out`); the pre-`Wo` concat-heads tensor is the distinct `z` object and deserves a distinct name. (4) **Cost is contained:** WP4's only `attn_out` consumer is the llama synthetic golden; Demo A and the default capture path use `residual`; the fix-forward naming patch changes no math; the thesis is parked until ≈ Q1–Q2 2027, after the WP5/WP6b patch window. This decision needs **no API-GRAMMAR change** — the `components` vocabulary is unchanged, `rebirth_error_trace` is already the approved error class (§6), and the §4 shape promise is upheld, not amended.
- **Alternatives rejected:** standardize on pre-projection (`kqv_out`) everywhere (redefines the standard object, breaks the §4 `hidden_size`-wide shape promise on gemma3, forces a llama golden regeneration — worst of all worlds); per-architecture split semantics documented only in roxygen (silent mislabeling — docs do not fire at comparison time, and the data frames look identical; on MedGemma even the column count would contradict `summary(m)`); mapping gemma3 `attn_out` → the named `attn_post_norm-<il>` (a third semantics under one label — post-norm on gemma3, raw post-`Wo` on llama); adding an `attn_heads` component now (an API-vocabulary change the implementer cannot self-approve, and not needed to unblock WP4/WP6b).

---

## D-015 — vendored-patch application: commit the patched tree
- **Date:** 2026-07-06 · **Status:** accepted (founder delegated the call to Fable 5, 2026-07-06; Fable 5 concurred with the plan and added the strengthenings below)
- **Decision:** vendored llama.cpp patches (starting with the WP5 ablation hook at `build_cvec`, D-012) are APPLIED to the committed `src/llama.cpp/` tree, not applied at build time. `build.rs` compiles the tree as-is — no build-time patch tool, no new dependency, CRAN/`R CMD INSTALL`-robust (the standard way R packages ship patched vendored C). The annotated unified diff for each patch stays in `src/llama.cpp/patches/` as the vendor-bump-reappliable delta. **`VENDORING.md` records THREE SHA256 values:** the upstream b9726 tarball SHA (provenance), the **pre-patch** pruned-tree SHA (the current value, kept as a row), and the **post-patch** pruned-tree SHA (the value D-008 gate **G4** asserts). **G4's CI assertion does not exist yet, and WP5 Step 2 wires it** (a CI step computing the documented digest and asserting it matches `VENDORING.md` — verified absent at decision time). `vendor-bump` gains a **patch-coherence check** (reverse-apply `patches/*.diff` to the committed tree, recompute the digest, assert it equals the recorded pre-patch SHA — catches the tree and the diff silently diverging) and re-runs harness B. Full analysis + exact hunks in `docs/wp5-intervention-plan.md`.
- **Why:** WP5 is the project's first vendored patch, so the mechanism is fixed once. Committing the patched tree needs no fragile external `patch`/`git apply` (unreliable on the eventual Windows/CRAN matrix) and no diff-applier dependency; it *strengthens* G4 (the gate hashes exactly what compiles, whereas a build-time mutation step is unhashed surface between the asserted SHA and the compiled bytes), and a documented patch that updates `VENDORING.md` + lands an annotated diff is not the "silent drift" G4 exists to catch. The `build_cvec` hunk is a no-op on the un-intervened path (D-012), so the patched tree's default behaviour and every existing golden are byte-identical (WP2/WP3/WP4 synthetic goldens pass unchanged).
- **Alternatives rejected:** apply patches at build time from `build.rs` (needs a fragile external tool or a new diff-applier dependency, and mutating package sources during `R CMD build` trips "files modified during build" unless the tree is first copied to `OUT_DIR` — doubling build complexity/disk); commit the patched tree recording only the base or only the patched SHA (loses provenance, or loses the G4 anchor / makes vendor-bump re-apply unauditable).
- **Scope note:** authorizes the application MECHANISM only; each patch's CONTENT is governed by its own ADR (the ablation hook by D-012; the D-014-chartered `attn_out` naming patch by its own — note that patch will move the post-patch SHA a second time, so sequence the two patch PRs).

---

## D-016 — WP5 intervention semantics (`llm_steer` / `llm_ablate`)
- **Date:** 2026-07-06 · **Status:** accepted (founder delegated the WP5 calls to Fable 5, 2026-07-06)
- **Decision:** steering = llama.cpp's **native control-vector** path (zero patch); ablation (`x[k] := value`) = a **native ggml graph op** `(x + steer) ⊙ mask + add` via a sibling `llama_adapter_intervene` adapter added by the D-012/D-015 `build_cvec` patch. Semantics settled here:
  - **Compose order — ablation wins:** `intervene->apply_to` runs AFTER `cvec->apply_to`, so a jointly steered+ablated neuron emits exactly `value` (API-GRAMMAR §4 "forced to value"). The result is **derivation-order-independent** (`ablate |> steer` == `steer |> ablate`); documented in both roxygen.
  - **Composition:** steering **stacks by summation** (control vectors are additive; accumulated in R); ablation is a **union, last-write-wins** per `(layer, neuron)`.
  - **Layer-1 steering is unreachable** by the native control vector (it reserves engine index 0), so a `layer = 1` **steer** raises `rebirth_error_intervention` naming the reason + workarounds (steer 2..N; ablate layer 1). Ablation covers all layers (the adapter allocates `il = 0..n_layer-1`). Routing steering through the patch for symmetry (Fable's Option B) is rejected for now — it would supersede D-012 for a layer steering rarely targets, and the adapter's full coverage makes it cheap to adopt later.
  - **Interventions apply to generation/logits only in WP5.** `llm_embed`/`llm_trace` on an intervened handle raise `rebirth_error_embed`/`rebirth_error_trace` (they build fresh contexts that do NOT inherit the adapters, so returning base vectors labeled as intervened would be silent mislabeling — the D-012/D-014 failure class). Position-subset steering and `attn_out`/`mlp_out` ablation likewise raise the classed error (only `positions = "all"` steering and `component = "residual"` ablation are in scope). All are backlog capabilities.
  - **Reversibility (acceptance) is structural:** derived handles are fresh contexts on a cloned `Arc<Model>` (read-only weights); the source context never receives a setter, so the original handle reproduces original outputs bit-for-bit (verified exactly in Rust on the synthetic model).
  - **Architecture support** = the `build_cvec` archs, seeded `{llama, qwen2, gemma3}`, checked before decode → `rebirth_error_intervention` on an unlisted arch (never a silent no-op). Coverage tiering, stated honestly: **llama + qwen2 fixture-covered in WP5; gemma3 source-verified at b9726**, runtime fixture chartered for WP6b/thesis-era.
  - **Fixtures:** the ablation honesty fixture (next-token KL) is an env-gated **Rust** integration test (`llm_logits` is out of WP5 scope, so R has no token distribution); the valence steering fixture is R `testthat` with a small **original committed lexicon** + provenance script (no third-party lexicon — licensing + the no-new-dependency rule).
- **Why:** each choice keeps an approved contract (grammar §4 "forced to value" mandates the compose order; the honesty limits forbid a silent base-pass on an intervened `llm_embed`/`llm_trace`), respects a settled decision (D-012 steering = native), or matches what a golden can actually defend (arch tiering; the Rust KL fixture). Full analysis + source citations in `docs/wp5-intervention-plan.md` (§1–§7 + the Fable-5 addendum).
- **Alternatives rejected:** steering through the patch for layer-1 symmetry (supersedes D-012 for negligible gain; deferred, cheap later); a `testthat` KL fixture (not computable without `llm_logits`); silently returning base activations for an intervened `llm_embed`/`llm_trace` (mislabeling); a third-party sentiment lexicon (licensing + no-new-dependency).

---

## D-017 — trace memory budget measured on materialized bytes
- **Date:** 2026-07-07 · **Status:** ACCEPTED — founder ratified 2026-07-07 (supersedes the ARCH §5 estimate basis; flagged by the 2026-07-07 full-codebase audit as its only settled-decision change; the full fix — accurate materialized-bytes budget (K=11, twin-pinned) + FFI payload de-dup — is implemented and merged (PR #11); the interim 256 MB is superseded by the restored `min(2 GB, 20% RAM)` default)
- **Decision (proposed):** `llm_trace()`'s memory budget is computed against the **peak resident bytes of the materialized R `data.frame` the caller receives**, not the engine's f32 activation bytes (ARCH §5's basis). The estimate multiplies the f32 activation size by a **measured expansion factor** (audit: the long `data.frame` is ~10× the f32 bytes; the transient FFI payload — currently a per-neuron `String` clone — pushes the peak ~30×), and the FFI payload **de-duplicates the token/component strings** (one interned copy, not one per neuron). An `object.size(result) ≤ K × estimate` test pins the factor so it cannot silently drift. Spill triggers on the corrected estimate.
- **Why:** the f32 basis under-counts the real cost 10–30×, so a capture estimating in `[~300 MB, 2 GB]` stayed "in budget", never spilled, and materialized 3–20 GB → the 16 GB session died with no error (audit finding H-1). Budgeting on what the user actually receives is the only basis that makes the fail-safe honest. **The interim already shipped** (PR #10): the default budget was cut `2 GB → 256 MB` so large captures spill via the proven path; D-017 is the proper fix that restores an accurate, larger usable in-memory budget without the OOM.
- **Alternatives rejected:** keep the f32 basis and only lower the default (the interim — safe but leaves the budget inaccurate and the usable in-memory size needlessly small); cap rows instead of bytes (does not bound the per-neuron string blow-up); drop the budget and always spill (loses the fast in-memory path for small traces).
- **Scope note:** changes the budget MEASUREMENT and the FFI payload string interning only; the `rebirth_trace` object, the `data.frame` schema, and `as.matrix` are unchanged. The pattern generalizes to Phase 6 (streaming traces) and Phase 14 (SAE features). On ratification the coder implements it and updates ARCH §5; until then the interim 256 MB default holds.

---

## D-018 — harness B acceptance: exact same-implementation legs + a scale-robust HF-fp32 semantic cross-check
- **Date:** 2026-07-07 · **Status:** ACCEPTED — founder ratified 2026-07-07 (corrects the ROADMAP WP4/WP6a "rank-correlation ≥ 0.999/layer vs HF fp32" criterion, empirically unreachable)
- **Decision:** harness B validates the activation taps against two references, each with an honestly-scoped bar:
  - **Same-implementation legs (the hard, exact / near-exact gates):** the in-repo synthetic 2-layer model vs the independent numpy oracle stays **exact** (ATOL 1e-2, per-component *and* per-token-position); logits vs an **unpatched llama.cpp** build (same pinned tag) stay near-exact (documented per-quantization tolerance).
  - **Independent-implementation leg (HF fp32) — a semantic cross-check, not a fidelity gate:** the CI model's activations vs a PyTorch fp32 reference confirm the taps read the **correct tensors**, at a **scale-robust tolerance** (per-layer Spearman and per-row cosine ≥ ~0.94), anchored by the **exact residual-decomposition identity** (`residual[l] = residual[l-1] + attn_out[l] + mlp_out[l]`, max|Δ| = 0.0) and **top-k next-token logit agreement**. Bit-fidelity / ≥ 0.999-per-layer is **not** asserted on this leg.
- **Why:** ≥ 0.999/layer against an independent HF reference is unreachable and **not a defect** — measured min Spearman ~0.976 on Qwen2.5-0.5B, and it is **not quantization** (an fp16 GGUF gives the same gap as Q8_0) nor **backend** (CPU == Metal): it is intrinsic llama.cpp-vs-PyTorch numerical divergence that compounds with depth (layer-1 cosine 0.999 → layer-24 ~0.96) on a numerically sensitive small model. Asserting an unreachable bar would either block a correct implementation or pressure the golden into being gamed; the residual identity + logit agreement + the exact same-implementation legs together prove tap correctness **without overclaiming fidelity** (honesty limits). Non-gameability is pinned: in the WP6b HF-golden review a +1-layer shift breached every gate (min Spearman −0.26, blow-up 55.6 ≫ the 8.0 gate) while genuine divergence passed with margin.
- **Alternatives rejected:** keep ≥ 0.999 vs HF (proven unreachable); drop the HF leg (loses the independent cross-check that catches a wrong-tensor tap); chase a tighter HF bound via TransformerLens / a larger model (deferred — the dual-reference already pins correctness; not worth the dependency + compute now).
- **Scope note:** updates the ROADMAP WP4/WP6a "≥ 0.999/layer" acceptance line only; the exact same-implementation gates and the synthetic per-position ATOL are unchanged. Applies to the nightly 0.5B run and future models. Evidence: the WP6b HF-golden PR + reviewer report.

---

## D-019 — F-1 memory-safety mechanism (full-stack Valgrind now; ASan/UBSan tracked) + the D-008 G4 supply-chain gate
- **Date:** 2026-07-07 · **Status:** accepted (test-engineer; branch `wp-f1-sanitizers`, pending founder review/merge)
- **Decision:** deliver F-1's memory-safety and supply-chain halves as follows.
  - **Memory safety = Valgrind memcheck on the normal build, full-stack**, in a dedicated nightly workflow (`nightly-memory-safety.yaml`, `schedule` + `workflow_dispatch`, never per-PR). It runs the download-free synthetic intervention-path cargo tests (`synthetic_intervene` = steer + ablate via the `build_cvec` patch + `clone_with_fresh_context`; `synthetic_trace` = the eval-callback tap; plus `synthetic_embed`/`synthetic_generate`), so the vendored ablation patch and the `OwnedContext` RAII drop (engine.rs) are on the exercised path. It fails loud via `--error-exitcode=1` + `--errors-for-leak-kinds=definite,indirect`, and asserts it *actually ran under Valgrind* (4 `ERROR SUMMARY` lines + the per-test markers) so a mis-set runner cannot pass a false green. Two build details make it robust: (i) **`SOURCE_DATE_EPOCH` is set**, which makes ggml's own CMake default `GGML_NATIVE=OFF` → a baseline (SSE2, no `-march=native`, no AVX/AVX-512) engine Valgrind can decode without an "unhandled instruction" abort; (ii) **sccache is disabled** for this job, so it cannot reuse the per-PR jobs' native-ISA cached objects (which would give a false-clean run). A committed suppressions file (`tests/valgrind/rebirth.supp`, initially empty, discipline documented in its header) absorbs any upstream-benign definite loss without weakening the gate.
  - **Supply chain (D-008 gate G4) = `cargo deny` + `cargo audit`, split per-PR / nightly.** The **deterministic** checks (`cargo deny check bans licenses sources` — a function of the committed `Cargo.lock`/`Cargo.toml` only) run **per-PR** as the `supply-chain` job in `rust.yaml`, so a bad-license / unexpected-source / banned new dependency is caught at merge time. The **feed-dependent** checks (`cargo deny check advisories` + `cargo audit`, which read the daily-changing RustSec DB) run **nightly** (`nightly-supply-chain.yaml`), so a freshly published advisory never turns an unrelated PR red. Policy lives in `rebirth/src/rust/deny.toml`: allow `MIT`/`Apache-2.0`/`Unicode-3.0` (the last is the AND-clause of `unicode-ident`), with a scoped `CC0-1.0` exception for `tiny-keccak`; `multiple-versions`/`wildcards` warn (not fail); one ignored advisory — `RUSTSEC-2024-0436` (`paste` unmaintained, a transitive proc-macro dep of `extendr-api` with no safe replacement; a maintenance notice, not a vulnerability). Verified locally 2026-07-07: `cargo deny check` = ok on all four checks; `cargo audit` = 0 vulnerabilities (the one `paste` unmaintained warning is non-failing by default).
- **Why:** the hard part of F-1 is the mixed Rust + **uninstrumented-C++** boundary (the FFI into vendored llama.cpp + the `build_cvec` patch). Valgrind instruments at the binary level, so it covers leaks / use-after-free / invalid access across the *whole* process — our Rust, the FFI, the uninstrumented C++, and the patch — with **no recompile and no symbol-interposition blind spot**, which a partial ASan build (our crates only) would have exactly at the boundary we care about. This is the robust, first-run-viable choice for the leak + invalid-access classes and directly makes the "nightly … leak test" real. The per-PR/nightly supply-chain split mirrors the existing nightly-vs-per-commit discipline (nightly-model-tolerance.yaml): keep merge-gating checks reproducible, push anything driven by an external feed to nightly.
- **Coverage / limits (honest):** Valgrind memcheck catches definite/indirect leaks, UAF, invalid/mismatched free, invalid reads/writes, and uninitialised-value use — but **not** stack-/global-buffer-overflow (ASan only) or non-memory UB such as signed-overflow / misalignment / invalid-enum (UBSan only). Data races are out of scope by design (D-008 G2 single-thread confinement). The complementary **ASan + UBSan job with the vendored llama.cpp *also* recompiled `-fsanitize=address,undefined`** (threaded via `CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS`, sccache disabled, nightly Rust) remains **open F-1 work**, as does gating the `rebirth_selftest_*` FFI behind a non-default `selftest` cargo feature. This ADR satisfies the `cargo audit`/`cargo deny` and leak-job parts of D-008 G4 (the vendored-tree SHA part of G4 was already wired as `rust.yaml`'s `vendored-tree` job).
- **Alternatives rejected:** ASan/UBSan on our crates only (blind spot at the FFI/patch — the very boundary F-1 exists to check); ASan/UBSan with the C++ recompiled *as the first delivery* (correct end-state but higher first-run risk — nightly toolchain, cmake flag-threading, ASan/UBSan runtime-linkage combos — deferred to the tracked follow-on rather than shipped unvalidated); running the advisory scan per-PR (a daily-changing external feed would gate merges on events unrelated to the diff); a global `CC0-1.0` allow (looser than needed — scoped to `tiny-keccak` so a new CC0 crate is still surfaced); a long-session 1,000-cycle RSS-flatness leak test (coarser than Valgrind's per-allocation proof of the `OwnedContext` drop; kept as complementary future work per SOLO-PHASE-PLAN §4).

---

## D-020 — v0.1.0 dependency posture: three analytical Suggests, base-graphics money plots, no ggplot2, no pROC
- **Date:** 2026-07-07 · **Status:** accepted (2026-07-07; founder delegated the call to Fable 5 within his constraints "keep plotting, few dependencies")
- **Decision:** the complete `rebirth/DESCRIPTION` delta for Phase 3 (WP7 + WP8) is:
  ```
  Suggests: testthat (>= 3.0.0), glmnet, uwot, dbscan, quarto
  VignetteBuilder: quarto
  ```
  `Imports:` is untouched (`nanoarrow` remains the package's only hard dependency). No other R dependency enters anywhere in Phase 3. Specifics:
  1. **Analytical Suggests = `glmnet`, `uwot`, `dbscan` — declared, because the WP7 vignettes execute them.** glmnet carries Demo A's per-layer probes (p ≫ n: hidden size 896–1536 vs a contrast set of ~10² rows — unpenalized `glm` yields perfect separation / non-convergence, so a cross-validated ridge logistic probe, the field-standard linear probe, is genuinely load-bearing). uwot (UMAP) and dbscan (HDBSCAN) carry Demo B and are disjoint — UMAP has no clusterer, HDBSCAN has no embedding, and "BERTopic-class pipeline" (SOLO-PHASE-PLAN §8) *means* UMAP + HDBSCAN. All three are tidyverse-free by recursive Imports (verified on CRAN 2026-07-07: Rcpp/Fortran/linear-algebra stacks; dbscan's `generics` is the zero-dependency r-lib S3 shim). Suggests are not installed by `install.packages("rebirth")` — the user-facing hard-dependency count stays at one.
  2. **`quarto` Suggests + `VignetteBuilder: quarto` are vignette machinery, not an analytical choice** — mandated by the settled stack table ("roxygen2 + pkgdown + Quarto vignettes") the moment WP7's "draft Quarto vignettes" deliverable exists; authorized here so WP7 does not stall on hard rule 5. Building vignettes needs the Quarto CLI on the build machine (present on CRAN/r-universe builders); users never need it.
  3. **Both money plots are base graphics** (`graphics` + `grDevices::hcl.colors()`, in base R since 3.6). **ggplot2 enters nowhere** — not Suggests, not the demo scripts. This **explicitly supersedes the SOLO-PHASE-PLAN §8 implementation detail** "the money plot … in ggplot2" (the *figure deliverable* — per-layer AUC + CI decodability plot; labeled 2-D cluster map — is preserved exactly; only the rendering library changes). Grounds: (a) the later-approved, binding API-GRAMMAR v1.0 (D-003) already fixes `plot.llm_probe()` — the Phase-4 in-package version of the *same* decodability figure — as "base graphics implementation with a documented ggplot2 recipe in the vignette", and calls whole-trace ggplot2 work "the user's territory"; a WP7 ggplot2 figure would be re-implemented in base at Phase 4 anyway and would diverge from the package's own future `plot()` method. (b) The WP7 vignette channel turns any demo plotting library into a *declared package Suggests*, and ggplot2's Imports closure (11 packages: rlang, vctrs, S7, scales, lifecycle, cli, withr, gtable, isoband, grid, grDevices — verified 2026-07-07) would put the tidyverse infrastructure stack into the package's declared dependency universe, breaching the absolute "no tidyverse dependencies in the package" rule (D-001, a hard project rule). (c) The pristine footprint is itself part of the pitch: the flagship demos run on the R the researcher already has.
  4. **pROC is dropped, replaced by a ~12-line base-R helper**: AUC in exact rank-based Mann–Whitney form (`(sum(rank(c(pos, neg))[seq_along(pos)]) - n_pos*(n_pos+1)/2) / (n_pos*n_neg)`, average ranks = correct tie handling) + a stratified, fixed-seed percentile-bootstrap CI (resample within class, B = 2000). It lives in `tests/demos/demo-utils.R` (repo, not package) with an executable self-test block (perfect separation → 1; label-flip symmetry → 1 − AUC; monotone-transform invariance; a hand-computed tie case), sourced by Demo A; vignette A deliberately *inlines* the function — "AUC needs no dependency" is part of the demo's argument. The duplication (script + vignette) is accepted and guarded by the self-test.
  5. **Declared-and-guarded rule:** every Suggests use — vignette chunk or demo script — sits behind `requireNamespace(..., quietly = TRUE)` with an informative skip message, and the package must pass `R CMD check` with `_R_CHECK_FORCE_SUGGESTS_=false` (CRAN policy). Vignette chunks that need a GGUF model are precomputed/conditionally evaluated (checkers have no model; the *executable* acceptance path for the demos is `tests/demos/` in nightly CI on the CI model, per WP7).
  6. **The guarded-but-undeclared class is empty at v0.1.0.** Demo scripts use only base R + the three declared packages, so nothing is script-only. (The class remains available for future demos whose deps never appear in a vignette.)
  7. **Bounded fallback, founder-triggered only:** if at WP7 review the founder judges a rendered base-graphics figure not presentable, ggplot2 may be used *in `tests/demos/` scripts only* — guarded, undeclared, never in vignettes or DESCRIPTION. This is the recorded boundary, not an expectation; the base implementations are assessed presentable (error-bar series and colored labeled scatters are classical base-graphics territory).
- **Why:** the two governing constraints pull against each other — the figures are the selling visuals and must ship (constraint 1); the dependency footprint must stay minimal (constraint 2) — and this posture is the unique point satisfying both without breaching a settled rule: the three packages that do irreplaceable statistical work are declared honestly where vignettes use them; the two deps that are replaceable by ~12 lines of base R (pROC) or by the plotting idiom the grammar already binds the package to (ggplot2) are removed entirely. glmnet/uwot/dbscan are also *credibility* choices: Friedman–Hastie–Tibshirani's glmnet and the canonical UMAP/HDBSCAN implementations are exactly the "R statistical heritage + live CRAN ecosystem" the demos exist to showcase, and hand-rolling a ridge-IRLS or a UMAP would undermine the demos' honesty (WP7 forbids cherry-picking; the methods must be the standard ones). Reproducibility (WP7 acceptance "pinned seeds → identical outputs") is handled in-script: fixed committed `foldid` for `cv.glmnet`, `set.seed` + single-threaded SGD (`n_sgd_threads = 1`) for uwot, fixed bootstrap seed for the AUC CI; HDBSCAN is deterministic given its input.
- **Alternatives rejected:** **ggplot2 in vignettes/Suggests** (declared tidyverse infrastructure in the package — breaches D-001/hard rule 2; diverges from the binding base-graphics `plot.llm_probe`); **ggplot2 script-only from day one** (the pkgdown vignette figure — the public face — would then differ from the demo-script figure or force duplicated figure code; if base graphics is good enough for the public figure it is good enough everywhere); **pROC** (a compiled Suggests for what is 12 auditable lines of base R; the helper is also the seed of Phase-4 `llm_probe`'s metric code); **base `glm` on top-k PCs instead of glmnet** (avoids the p ≫ n pathology only by discarding information and changes what is measured — variance-aligned decodability instead of full-space linear decodability — a probe a mech-interp reviewer would rightly flag); **cmdscale + kmeans instead of uwot + dbscan** (classical MDS blurs local cluster structure at 5k points and is O(n²); kmeans needs a-priori k and has no noise class — the result stops being a BERTopic-class map); **declaring nothing and keeping vignettes model-gated to dodge Suggests** (vignettes that use a package must declare it — dodging is a CRAN-policy breach or dishonest labeling); **knitr/rmarkdown vignettes to avoid the quarto dep** (contradicts the settled stack table for a same-order dependency swap).
- **Backlog note (scope control):** (1) Phase 4 / WP11 `llm_probe()` supersedes the demo-utils AUC helper and owns the standardized decodability figure (base graphics per the grammar); whether glmnet then moves Suggests → Imports is that WP's ADR, not settled here. (2) Demo C (optional stretch, D-010) adds no dependency — it reuses glmnet and the same helper. (3) The "documented ggplot2 recipe" the grammar promises for `plot.llm_probe`'s vignette is Phase-4 documentation work, not a Phase-3 dependency.

---

## D-021 — WP7.5 modern-model enablement: validate at the b9726 pin; a runtime sentinel intervention probe supersedes the D-016 hard arch allow-list; the vendor bump becomes conditional
- **Date:** 2026-07-07 · **Status:** accepted (founder delegated the intervention-gate call to Fable 5; sequencing ratified 2026-07-07 — modern models as TEXT land in WP7.5 before v0.1.0)
- **Context correction (verified live in the vendored tree, 2026-07-07):** two premises under which WP7.5 was requested are false at the source level. (1) The pin `b9726` (2026-06-19) ALREADY contains the target decoder arches — `LLM_ARCH_GEMMA4/QWEN3/QWEN3MOE/QWEN35/QWEN35MOE` in `llama-arch.h`, model graphs `gemma4.cpp`/`qwen3.cpp`/`qwen35.cpp` (all call `build_cvec` and name `l_out-<il>`), matching hparams/tensor cases in `llama-model.cpp`. A vendor bump is NOT required to load Gemma 4 / Qwen 3.5 as text. (2) The Gemma-3-4B-QAT load failure (`expected 883, got 444`) is a COMBINED text+vision GGUF (444 text + ~439 vision tensors) refused because the loader's single call site (`llama-model.cpp:1470`) passes the upstream default `partial=false`; text-only GGUFs of the same models load. So loading/generation/embedding/`llm_logits` work on modern models today; only `llm_trace` (arch-gated in `trace.rs`) and `llm_steer`/`llm_ablate` (the D-016 allow-list) need our work.
- **Decision:**
  1. **Enable modern models at the current pin — no bump in the default path.** A day-1 spike (founder's Mac, Metal) pins text-only instruct GGUFs (Gemma 4 up to 12B, Qwen 3.5 up to ~9B, Qwen 3 mid-sizes, Gemma-3-4B text-only as the control), dumps GGUF metadata, and runs `llm()`/`llm_generate` (chat TRUE+FALSE)/`llm_embed`/`llm_logits` per model → a committed support matrix (`docs/wp7.5-model-matrix.md`: arch, quant, SHA256, load, chat-template, RSS, tokens/s, license).
  2. **`llm_trace` matcher extension** — explicit per-arch component tables derived from the graph source (never name-trusting, per D-014): qwen3/qwen35 → {residual=`l_out`, mlp_out=`ffn_out`}, gemma4 → {residual=`l_out` only}. `attn_out` stays llama-only, and gemma4's SAME-NAMED `attn_out-<il>` tensor (a mid-block residual sum, `gemma4.cpp:287`, NOT the post-`Wo` attention output D-014 defines) MUST raise `rebirth_error_trace` — locked by an adversarial test.
  3. **A runtime sentinel intervention probe supersedes the D-016 hard allow-list** (the founder's "as universal as possible" direction, made rigorous). On `llm_steer`/`llm_ablate`, before returning the handle, a throwaway internal context (existing `cb_eval` + `llama_set_adapter_cvec` + `rebirth_set_intervene`, NO new FFI, NO new patch) decodes one token twice and asserts at each requested layer: an **ablation-pin** (`l_out[k] == sentinel` — proves `build_cvec` fires in this model's graph and acts on the traced residual) and a **steer-shift** (`l_out[k]` moves by exactly ε — proves the native cvec path reaches this layer). Pass → interventions enabled on this model (any standard-residual decoder llama.cpp loads — universal); fail → `rebirth_error_intervention` stating what was probed and did not respond (never a silent no-op, the D-012 worst-case). A curated "behaviorally validated" tier (arches also passing the WP5 [MODEL] valence/KL fixtures) remains DOCUMENTATION, not a gate. The R-side `INTERVENTION_SUPPORTED_ARCHS` hard-stop is removed (retargeted to the validated-tier doc list; twin-pin retargeted).
  4. **The vendor bump becomes conditional** — fires only on a trigger (T1 a target text-only GGUF fails to load for an engine reason; T2 chat-template undetected and chat=FALSE insufficient; T3 a family distributed ONLY as combined text+vision files). If triggered: newest `bNNNN` release tag ≥ ~2 weeks old containing the needed fix, diff-reviewed in our 7 patched files first; the ablation patch is mostly additive with 4 coupled hunks that fail LOUD at compile if upstream reorders; full harness-B re-validation (incl. rebuilding the unpatched reference at the new tag) + the sentinel-probe suite; 3-working-day timebox → else revert to b9726 and ship with what loads.
- **Supersedes:** the D-016 clause "Architecture support = the `build_cvec` archs, seeded `{llama,qwen2,gemma3}`, checked before decode" — replaced by the §3 probe. Every other D-016 clause (compose order, stacking, layer-1 steer, intervened-handle guards, reversibility) and D-012/D-014/D-015/D-017/D-018 are unchanged.
- **Why:** the cheapest correct path — the engine already supports the target families, so the risky operation (bump) is demoted from prerequisite to contingency; the first release is not hostage to engine churn. The probe answers universality more honestly than a longer list: it converts D-012's "never silently no-op" from a per-arch promise into a per-model theorem checked at runtime, and removes the hand-maintained enumeration the twin-pin discipline exists to babysit. The proposed Δ=0 residual-identity check was REJECTED as the gate (not computable from engine taps on qwen2/gemma3 per D-014; false-in-form on gemma3/gemma4 post-norms where interventions are still correct; blind to the no-op failure class — an arch without `build_cvec` passes the identity while steering no-ops).
- **Alternatives rejected:** hard-extend the allow-list to `{…,qwen3,gemma4,qwen35}` (stale-list treadmill; no per-model mechanism evidence — kept only as the 1-day fallback if the probe slips); the Δ=0 runtime identity as the gate (four grounds above); unconditional bump now (pays the full re-validation bill days before the first tag for arch support the pin already has); defer all of Track 1 post-v0.1.0 (leaves the flagship demos on 0.5–1.5B models the founder judges too limited).
- **Full analysis:** `scratchpad/WP7.5-vendor-bump-ADR-draft.md` (the working artifact behind this entry).

---

## D-022 — WP7.5 demo analysis & visualization deepening: five mech-interp analyses + topic-quality depth, base-graphics only, zero new dependencies
- **Date:** 2026-07-07 · **Status:** accepted (founder greenlit the WP7.5 analysis/viz track; Fable's recommendations adopted — formality as the second concept, base-R silhouette, no new deps)
- **Decision:** deepen the flagship demos entirely inside the approved API-GRAMMAR v1.0 surface (no new export) and D-020's dependency posture (Imports = nanoarrow only; base graphics + `hcl.colors`; NO ggplot2/pROC), all new code in `tests/demos/` + the two Quarto vignettes (never in `R/` — that is Phase-4 `llm_probe` territory):
  - **Demo A (read → localize → intervene):** A1 multi-concept decodability overlay (second committed contrast set = **formality**, orthogonal to sentiment, no demographic sensitivity); A2 token×layer concept heatmap (`llm_trace(positions="all")` on ≤ 8 committed exemplars, base `image()` + a color-strip legend helper — the D-017 materialized-bytes budget honored in-script); A3 steering dose–response curve (committed coef grid, bootstrap CIs, the full swept range INCLUDING the saturation/degradation tail always shown — honesty guard); A4 targeted-vs-matched-random ablation effect curve (KL via `llm_logits`; the WP5 honesty fixture promoted to a figure — random control must hug zero); A5 concept-direction cross-layer cosine-similarity matrix.
  - **Demo B:** B1 topic-quality metrics (simplified O(n·k) silhouette + embedding-space cohesion, base R, self-tested); B2 top terms per topic (Dirichlet-smoothed log-odds, base R); B3 inter-topic structure (centroid cosine heatmap + `hclust` dendrogram); B4 polished map.
  - **Visual-polish pass:** one shared style helper in `demo-utils.R` (palette `hcl.colors("Dark 3"/"YlOrBr"/"Blue-Red 3")`, `pch=21` fills with white strokes — the founder's noted `pch` preference, consistent `par`, halo-text + color-strip-legend helpers, model|n|seed subtitle), multi-panel `layout()`.
- **Dependencies:** NONE added. Candidates evaluated per D-020 and rejected with base-R equivalents: `fields` (image legend → 15-line helper), `plotrix` (nothing load-bearing), `cluster` (exact silhouette → simplified variant; kept as a one-line D-020-amendment founder option since `cluster` ships with every R), `ggplot2` (stays excluded).
- **Acceptance (executable):** extended runs ≤ +10 min per demo on the Mac (behind `extended=TRUE`) + nightly on 0.5B relaxed; fixed seeds ⇒ byte-identical numeric re-runs asserted in CI; extended `demo_utils_selftest()` (simplified-silhouette hand case, log-odds sanity, dose-response reproducibility) green per commit; A4's random control near-null while targeted discriminates; vignettes render model-free; no DESCRIPTION diff; docs-vs-diff grep clean (hard rule 8g).
- **Why:** the chosen set is the complete minimal causal narrative (observe A1/A2 → characterize A5 → intervene with dose+controls A3/A4) using only shipped verbs, each figure a distinct reviewer-grade question, none needing a claim the honesty limits forbid (framing = localize/quantify, never fix). Demo B reaches BERTopic-report parity (quality/terms/structure) where "zero Python" is most checkable. Zero-dependency is load-bearing pre-release (D-020's "the demos run on the R the researcher already has").
- **Explicitly out (backlog, kept OUT of the WP):** true logit-lens (needs unembedding access — new API/FFI; Phase-4 candidate), per-position activation patching (D-016 positions backlog), SAE (Phase 14).
- **Full analysis:** `scratchpad/WP7.5-analysis-viz-ADR-draft.md`.

### D-022 — implementation note on A4 (2026-07-08, status: accepted)

Founder chose Fable's option (b)+(d) on 2026-07-08 (two-series money figure + vignette subsection); this note moves `proposed` → `accepted`. No superseding ADR: D-022's binding A4 text ("targeted-vs-matched-random ablation effect curve; KL via `llm_logits`; the WP5 honesty fixture promoted to a figure — random control must hug zero") is satisfied as written, and the WP5 fixture's own targeted set (`calibrate_kl` in `intervene_kl.rs`) was ranked by measured per-neuron ablation-KL, not probe coefficients.

Empirical finding (Qwen2.5-0.5B Q8_0 and Gemma 4 E4B, committed eliciting prompts): zero-ablating top-|probe-coef| residual units moves next-token KL no more than matched random (≈ 0.1–0.6×) — the decodability ≠ causality gap; the working-artifact intent to rank A4's targeted set by |probe coef| is falsified and retired. A4's money figure = top-residual-RMS units vs size-matched random (the faithful promotion of the WP5 fixture), framed as **unit-specificity** + the outlier / "massive-activation" dimension phenomenon, **never** as the concept's causal locus. The three-series figure (adding the probe-readout series) and the decodability ≠ causality discussion move to the `anatomy-lab.qmd` vignette with the A3 reconciliation (additive **sufficiency** of the direction — A3 steers behaviour — vs zero-ablation **non-necessity** of its top basis units — A4; sufficiency ≠ necessity, so no contradiction) and the magnitude-confound wording ("no more disruptive than matched random"; the count-matched randoms carry a larger typical magnitude, so "below random" is **not** claimed). The concept-readout series is **recorded** in the returned data (drawn by the supplementary `.demo_A4_plot_decodability()`), **never gated** — an empirical finding that may legitimately differ across models.

- **Executable acceptance (sharpened, encoded in `.demo_A4_accept()`):** nightly 0.5B — pooled matched-random mean KL ≤ 0.10 nats at every k; impact ≥ 10× random at k = 8; paired one-sided Wilcoxon p ≤ 0.01 at max k (its floor at n = 8 is 1/2⁸ = 0.0039). `[MODEL]` Gemma 4 E4B (founder's Mac) — impact ≥ 5× random at k = 8. Observed: Qwen impact/random ≈ 457× @k=8, random_max 0.056, p = 0.0039; E4B recorded on the Mac showcase run.
- **Backlog (Phase 4, `llm_probe`/patching):** intervention-based unit importance (split-half ablation screening; the `calibrate_kl` pattern) and direction-projection ablation (new verb semantics — API-GRAMMAR + ADR); optional WP7.5b polish, founder-triggered: one magnitude-matched random series (would let the vignette claim "below random" cleanly).
- **Docs-vs-diff (hard rule 8g):** the A4 retitle strings ("surgical", "high-magnitude … readable direction", "decodability != causal locus" in the money figure) were grepped tree-wide; they existed only in `tests/demos/demo-A-anatomy-lab.R` and are corrected in the same pass.

---

## D-023 — Vision/multimodal is a dedicated phase (v0.2.0), not a v0.1.0 blocker; T3 vision-tower interpretability is a later research phase
- **Date:** 2026-07-07 · **Status:** accepted (founder ratified 2026-07-07: v0.1.0 text-only → vision as v0.2.0; demo default = Gemma 4 E4B as text, with the CI/reproduction split below)
- **Context correction (verified live):** the vendored b9726 tree was DELIBERATELY PRUNED of the ENTIRE multimodal subsystem — no `clip`/`mtmd`/`tools/`/`common/`, `include/` holds only `llama.h`+`llama-cpp.h` (VENDORING.md "Removed" list confirms). Only the VLM TEXT decoders are vendored (`gemma4.cpp`, `qwen2vl.cpp`, `qwen3vl.cpp`); the `llama_batch.embd` image-embedding decode hook exists (`llama.h:244`) but nothing produces image embeddings. So vision is not "wire up an API" — it is re-vendoring + building a SECOND native library.
- **Decision:**
  1. **v0.1.0 ships text-only; vision does not gate it.** (WP7.5's modern models are usable AS TEXT now — D-021 — so the founder's "bigger models" want is met for v0.1.0.)
  2. **Vision T1 (image→`llm_generate`) + T2 (image→`llm_embed`) are one dedicated phase = the existing Phase 11, pulled forward to produce v0.2.0** immediately after v0.1.0. Scope: re-vendor + build `libmtmd`/`clip` (+ the pruned `common/`/`stb_image` pieces), a new image-preprocess + vision-encode FFI (hand-written extern "C" per D-006; image parsing = untrusted input → security-auditor gate), the interleaved `batch.embd` decode path (honoring the n_batch chokepoint, hard rule 8a), the API-GRAMMAR entries `llm(projector=)` / `llm_generate(images=<file paths>)` / `llm_embed(images=)` (already reserved at API-GRAMMAR:156 for Phase 11 — exact signatures need founder sign-off, file-paths-only for v1), and a new vision golden category in harness B. ~5–7 engineer-weeks across 3–4 WPs.
  3. **T3 (interpretability of the vision ENCODER itself — trace/steer/ablate on the vision tower) is a separate research phase after the interpretability core is frozen.** It reuses almost none of the existing machinery: `cb_eval` taps the llama context, not clip's separate ggml graph; `build_cvec` is in libllama, not clip; and the D-018 residual-decomposition golden assumption breaks on a non-causal (bidirectional) SigLIP encoder. Same open problem as Phase-18 `rebirth.bio` encoder interpretability (D-012 backlog). Note: T1+T2 already give TEXT-side interpretability of a VLM (trace/steer the language decoder over image-conditioned generation) once gemma4/qwen-vl is on the D-021 probe path — a real capability without T3.
  4. **Demo default = Gemma 4 E4B (as text), per the founder** — with the consequence recorded and mitigated: because the Gemma Terms of Use gate download (breaking the "a stranger reruns it from the README" WP8 acceptance) and CI cannot fetch a gated ~4 GB model, the SHOWCASED/documented default is Gemma 4 E4B while the **CI nightly + the documented license-clean reproduction path stay on Qwen (Apache-2.0)**. The WP7.5a spike must confirm a TEXT-ONLY Gemma 4 E4B GGUF loads (the combined QAT file is refused). For the vision phase, the license-clean default is a Qwen-VL (Apache-2.0; decoders already vendored), Gemma 4 E4B the quality option.
- **Why:** vision sized truthfully is a native-subsystem un-pruning + a second library + new goldens + an image-parsing security surface = a phase by the project's own ≤2-week-WP / golden-first / spec-first rules, already scoped as Phase 11 with the grammar slot reserved. Blocking v0.1.0 on it realizes roadmap Risk #7 (scope creep; the first release receding as text→modern-models→vision pile on). Every phase ends shippable, so sequencing vision after v0.1.0 loses nothing and gives it a real phase instead of a destabilizing cram.
- **Alternatives rejected:** cram T1 into WP7.5/Phase 3 (mis-sized — slips and destabilizes the first release); leave Phase 11 in its post-Phase-10 slot (correct but later than the founder wants — viable fallback); fold T3 into the T1/T2 phase (T3 is research, not an extension); default the demos to Gemma 4 E4B WITHOUT the Qwen CI/reproduction split (Gemma Terms break the stranger-reruns acceptance).
- **Scope-control backlog (kept OUT of the Phase-11 WP list):** vision-tower trace/steer/ablate (T3); an `rebirth_image` S3 input type (v1 = file paths); multi-image batching; a combined-GGUF guarded-partial loader (only if a real combined-file need appears); audio via mtmd (out).
- **Full analysis:** `scratchpad/WP-vision-feasibility.md`.

---

## D-024 — WP8a `llm_download()`: a base-R zero-dependency verified fetch, a two-alias license-clean registry, and runtime fail-closed hardening
- **Date:** 2026-07-08 · **Status:** accepted, implemented (branch `wp8a-llm-download` → PR; reviewer approve-with-nits + security-auditor SHIP-YES, all actioned nits landed)
- **Context:** WP8 needs a "a stranger reruns the demo from the README" model fetch. The obvious ecosystem tools (`curl`/`httr` for HTTP, `digest`/`openssl` for hashing) would each be a new dependency — against Hard rule 5 and the D-020 lean posture. Verified live that base R already covers the whole surface: `utils::download.file(method = "libcurl")` does HTTPS (and follows redirects), and `tools::sha256sum()` is in base R for R ≥ 4.5 and byte-for-byte matches `shasum -a 256`.
- **Decision:**
  1. **Zero new dependencies.** `llm_download(model, dir = NULL, quiet = FALSE)` is built only on `utils::download.file(method = "libcurl")` + `tools::sha256sum()`. No `digest`/`openssl`/`curl`/`httr`. (No ADR-gated dependency added; this records that none was needed.)
  2. **Fail-closed by construction.** The fetch lands in a `.part` temp on the same filesystem, is `sha256sum`'d there, and is renamed into place **only** if it matches the pinned hash; a mismatch unlinks the temp before raising `rebirth_error_download` (fields `expected`/`actual`/`url`); `on.exit` unlink on every path. A registry alias whose hash matches an already-present file is returned without network (idempotent). A bare `https://` URL has no pinned hash, so its computed SHA256 is **reported, never asserted** — an unverifiable file is never presented as verified. Only HTTPS is accepted; path-traversal in the URL basename is rejected. Nothing downloaded is executed.
  3. **Registry scope (`inst/models.csv`): two verified Apache-2.0 Qwen aliases** — `qwen2.5-0.5b-instruct-q8_0` (the CI-integration model; its sha256 twin-pins the three nightly YAMLs + the test literal) and `qwen2.5-1.5b-instruct-q4_k_m` (the license-clean demo/reproduction default). **Qwen-7B is omitted** (it ships as a split multi-part GGUF; a shard-aware fetch+concat is deferred). **Gemma is omitted** (the Gemma Terms of Use gate download behind an access token — a plain libcurl fetch 401s — so Gemma models are supplied by local path, consistent with D-023's demo-showcase/CI split).
  4. **Runtime hardening applied at merge** (from the two gates, over the clean fail-closed core): (a) *LOW-1* — a runtime `^[0-9a-f]{64}$` assertion on an alias's hash in `resolve_model()` makes fail-closed total even for a re-packaged/hand-edited registry, independent of the ship-time well-formedness test, plus `na.strings = character(0L)` on the registry read so a field never silently coerces to `NA` and downgrades to unverified; (b) *LOW-4 / reviewer nit 2* — a bare URL never reuses a same-named cached file (basename collision → could return another URL's bytes), it always re-fetches; (c) *LOW-5* — `fetch_url()` raises the download timeout to ≥ 3600 s for the duration (base R's 60 s default would abort a legitimate > 1 GB model fetch) and (reviewer nit 1) threads the `call` so a network error names `llm_download()`, not the internal; (d) *LOW-2/LOW-3* — documented that a redirect cannot defeat the pinned checksum and that `dir` must be a directory only the user can write to. Two regression tests lock (a) and (b).
- **Why:** base R already has everything a verified fetch needs, so a dependency-free download honors Hard rule 5 + D-020; and a permanent public API on the FFI-free side deserves fail-closed-by-construction — the runtime hash guard, the no-stale-cache rule, and a timeout that lets real models actually finish complete the security-auditor's SHIP-YES rather than leaving it resting on a ship-time test.
- **Alternatives rejected:** `digest`/`openssl` for hashing (unneeded — `tools::sha256sum` is base); `curl`/`httr` for the fetch (unneeded — `download.file(libcurl)` does HTTPS + redirects); shipping the 7B alias now (multi-shard GGUF needs a shard-aware fetch/concat — deferred, tracked); auto-downloading Gemma (ToU token gating — local path per D-023); enforcing `size_bytes` as a hard cap (LOW-5 informational — deferred; the raised timeout + fail-closed checksum already bound the exposure); a curl-based fetch pinning `CURLOPT_REDIR_PROTOCOLS = https` to forbid a redirect transport-downgrade (LOW-2 — not worth a dependency, since for an alias the pinned checksum guards integrity end-to-end regardless of the hop).

---

## D-025 — The R package is renamed `rebirth` → `relm` before first publish (the project stays "R-ebirth")
- **Date:** 2026-07-08 · **Status:** accepted (founder chose `relm`)
- **Context:** The package had not been tagged or published, so this is the last no-cost moment to rename (no `install.packages("rebirth")` in the wild to break). The founder wanted a name that conveys what the package does and where it is going, is short, and is an acronym or crasi.
- **Decision:** The **R package** is renamed `rebirth` → **`relm`** — a crasi of **R + LLM** that reads as **"realm"** (the domain where you explore local models and their internals). The **project / repository / vision name stays "R-ebirth"** (the umbrella); only the package is renamed. The public `llm_*` API is unchanged. Renamed user-facing surface: condition classes `relm_error_*`, S3 class `relm_trace`, option `relm.trace_budget`, environment variables `RELM_*`, the r-universe URL segment `/relm`, and all package docs. Verified end-to-end: builds/installs/loads as `relm` (`R_init_relm`, `librelm.a`, `relm.so`); 525 offline tests pass.
- **Kept internal (deliberately unchanged — not user-visible):** the Rust crate names `rebirth-ffi`/`rebirth-llm`, the internal `#[extendr]` FFI function names (`rebirth_model_load`, …), the `RebirthError` Rust type, the vendored llama.cpp patch's C ABI symbol `rebirth_set_intervene` (renaming needs a re-patch + the vendor gate), and the synthetic-model fixture name `rebirth-synthetic-llama-2l` (baked into the committed golden GGUF; renaming needs a golden regeneration). Tracked for a later low-priority cleanup.
- **Why `relm` (and not `LLR`, the founder's first idea):** a scan of 24,204 CRAN packages showed `relm` free and `LLMR` (the cleaner "LLM for R" expansion) already taken. `LLR` was rejected on three grounds: it collides with a standard statistics acronym (log-likelihood ratio / local linear regression) in the exact target audience; it is three consonants, hence unpronounceable; and "Large Language for R" positions the package as yet-another LLM binding, hiding its interpretability differentiator. `relm` encodes R+LLM, reads as a word, is free on CRAN, and is brandable.
- **Alternatives rejected:** `LLR` / `LLMR` (above); keeping `rebirth` (the founder wanted a name that says what it does); renaming the whole project/repo to `relm` (kept "R-ebirth" as the umbrella/vision brand); renaming the internal crates/FFI symbols/fixture now (deferred — needs a vendor re-patch and a golden regeneration for no user-visible gain).
- **Follow-up (tracked):** sync the internal governance docs that still say "rebirth" in prose (`ROADMAP.md`, `ARCHITECTURE.md`, `SOLO-PHASE-PLAN.md`, `API-GRAMMAR.md`) to "relm", preserving the "R-ebirth" project name and the append-only `DECISIONS.md` history.

---

## D-026 — Vision (v0.2.0): re-vendor libmtmd at the same tag b9726, a second native library, T1+T2 only
- **Date:** 2026-07-14 · **Status:** accepted (founder approved 2026-07-14 — including audio **Option A**; the companion `API-GRAMMAR.md` entries approved the same day per the D-003 protocol). Full plan: `docs/phase11-vision-plan.md`.
- **Context:** Phase 11 (vision, pulled forward to v0.2.0 per D-023) is current. The vendored b9726 tree was pruned of the entire multimodal subsystem, but the VLM **text** decoders (`gemma4`/`qwen2vl`/`qwen3vl`/`qwen3vlmoe`) are already vendored. Verified against the upstream b9726 tarball (SHA256 `117e95a5…f2e0`, matching the VENDORING.md pin): (a) `libmtmd` is a buildable library at b9726 that links only `ggml`+`llama` and is **explicitly forbidden** from linking `llama-common` — so `common/` is NOT needed (correcting the ROADMAP/D-023 "+ common/" assumption); (b) clip supports `QWEN2VL/QWEN25VL/QWEN3VL` and `GEMMA3/GEMMA4V` — both the Apache-2.0 default and the Gemma quality tier; (c) the interleaved image+text decode is a tested upstream helper (`mtmd_helper_eval_chunks`, `n_batch`-aware, handling the gemma3 non-causal mask + qwen-vl M-RoPE internally); (d) image decode uses `stb_image`, and `mtmd-helper.cpp` also pulls `miniaudio`; (e) libmtmd is unreachable with our `LLAMA_BUILD_TOOLS=OFF`/`LLAMA_BUILD_COMMON=OFF` flags, needing a library-only build path.
- **Decision:**
  1. **Re-vendor at the SAME tag b9726 (no version bump)** — clip already supports every target model, keeping the ablation patch, the text goldens, and the unpatched reference all at one pin. Plan §8 lists the tripwires that would later force a bump (D-021 playbook).
  2. Widen the prune manifest to add `tools/mtmd` (library sources + `models/` + the debug header) and `vendor/stb/stb_image.h` (+ `vendor/miniaudio/miniaudio.h`, point 4); recompute the three VENDORING.md SHAs and keep G4 + reverse-apply coherence green. `common/` is NOT restored.
  3. Build `libmtmd.a` as a **second native archive** via a library-only build integration (a minimal vendored CMake option `LLAMA_BUILD_MTMD`, recommended; a `build.rs` second-configure is the fallback), `MTMD_VIDEO=OFF`; Metal on macOS arm64, CPU elsewhere, same pattern as libllama. Any committed-tree change joins the D-015 patch set.
  4. **Audio surface = Option A (founder's call):** vendor miniaudio and compile `mtmd-helper.cpp` unchanged (zero source patch), with a Rust-side image **magic-byte allow-list** (JPEG/PNG/BMP/GIF) so the audio decoder is unreachable from the R API; the security-auditor may escalate to Option B (a second small patch dropping miniaudio) at the WP-V1 gate. Both pre-authorized so the coder does not stall.
  5. Scope = **T1** (`llm(projector=)` + `llm_generate(images=)`) + **T2** (`llm_embed(images=)`), file-paths-only, single-image-before-text, per the approved API-GRAMMAR entries (`projector=`, `images=` ×2, `relm_error_image`). The interleaved decode reuses `mtmd_helper_eval_chunks` (never a hand-rolled M-RoPE/non-causal reimplementation — the D-012 fails-silent trap). **T3** (vision-tower trace/steer/ablate), an `relm_image` S3 type, multi-image, and audio stay OUT (D-023 backlog).
  6. A new harness-B **vision golden category**: same-implementation leg only — token-for-token greedy match + image-embedding `ATOL 1e-3` vs the **unpatched** upstream `llama-mtmd-cli` at b9726 (per D-018 logic; no HF cross-check — that would be a T3 tower check). No in-repo synthetic vision model exists, so the vision golden is a `[MODEL]`/nightly gate, never per-commit; per-commit CI covers the build, the byte-identical text goldens, the FFI ABI/error paths, and the magic-byte gate.
  7. **Dev-version discipline:** `DESCRIPTION` moves to `0.1.0.9000` for the phase (`main` stays releasable at every merge; r-universe rebuilds `main` on push), bumping to `0.2.0` at the release WP with the tag.
  8. **Model pins** (SHA256 pinned at WP-V4 via the D-024 flow): default = Apache-2.0 **Qwen2.5-VL-3B** + its mmproj (two registry aliases, no `models.csv` schema change); Gemma/MedGemma the local-path quality option (ToU-gated, per D-023's CI/reproduction split).
- **Why:** vision at b9726 needs no bump (clip already supports the targets), so the risky operation stays a contingency (D-021), not a prerequisite; reusing the tested interleaved-decode helper honors the `n_batch` chokepoint (Hard rule 8a) and avoids a fails-silent M-RoPE reimplementation (D-012); the magic-byte gate + reject-not-clamp dimension checks (Hard rule 8b) keep the untrusted image surface auditable; the byte-identical text goldens + re-asserted tree SHA are the formal "v0.1.0 does not break" guarantee; the dev version keeps `main` honestly labeled while r-universe builds it.
- **Alternatives rejected:** a vendor bump now (pays the full harness-B re-validation bill for arch support b9726 already has — kept only as the plan-§8 contingency); restoring `common/` (verified unnecessary — libmtmd forbids `llama-common`); reimplementing the interleaved decode in Rust (duplicates tested M-RoPE/non-causal logic, a fails-silent risk); a `build.rs` mtmd source list without a CMake option (manual sync burden across bumps — the fallback, not the default); audio Option B as the default (a second patch is not *necessary* once the magic-byte gate makes audio unreachable — D-012 bias; the auditor can still escalate); folding T3 into this phase (T3 is research and breaks the D-018 residual-decomposition golden on a non-causal encoder — D-023); shipping vision as a v0.1.x patch instead of a versioned phase (mis-sized, D-023).

### D-026 addendum (2026-07-14, founder-approved at the WP-V2 gate)

1. **Image allow-list = JPEG / PNG / BMP — GIF removed** (amending point 4's
   "JPEG/PNG/BMP/GIF"), on the WP-V1 security-auditor's recommendation
   (`docs/audit-wp-v1-mtmd-2026-07-14.md` §2b: GIF is the riskiest allow-listed
   stb decoder — LZW state machine, longest bug tail — for near-zero VLM value,
   since stb decodes only the first frame). Founder confirmed 2026-07-14; the
   shipped gate uses the full magics (JPEG `FF D8 FF`, PNG 8-byte, BMP `42 4D`)
   and the per-commit tests assert a real GIF is rejected.
2. **The point-6 `mtmd_get_output_embd` `ATOL 1e-3` image-embedding golden leg
   is deferred to WP-V4 as a BINDING requirement** (founder approved
   2026-07-14): the phase does not close and `v0.2.0` is not tagged without it.
   WP-V2's shipped golden gate is the **byte-exact greedy text leg** vs the
   unpatched b9726 `llama-mtmd-cli` (CPU, `tests/llm-golden/vision/`) — the
   upstream CLI exposes no token ids, so exact text is the strongest
   reproducible equality its output supports; the T1 FFI deliberately does not
   declare `mtmd_get_output_embd` (the helper-based ingest never needs it), so
   the embedding leg lands with WP-V4's nightly wiring.
3. **`options(relm.image_max_bytes = )` is the pinned user-facing byte-cap
   surface** implementing the WP-V1 audit's binding requirement 3a: default
   64 MB, validated in R, with the hard ceiling `2^31 - 1` bytes enforced in
   Rust regardless of the option (the stb `int`-length narrowing, audit F6).

### D-026 second addendum (2026-07-14, founder-approved at the WP-V3 gate)

**The T2 mechanism** (spike evidence: `docs/wp-v3-embed-spike.md`, citations
reviewer-verified against the pristine b9726 tarball): `llm_embed(images=)`
runs inside the D-011 embeddings context; image chunks are delegated
unchanged to `mtmd_helper_eval_chunk_single` (upstream owns the M-RoPE
positions and the gemma3 non-causal toggle), text chunks are decoded by the
engine's flag-all batch at helper-accounted positions.

1. **Amending D-011's "pool over all positions" for image-bearing inputs
   only: pooling reduces over the TEXT-position rows** (including the
   projector's image-delimiter tokens, e.g. `<|vision_start|>`/
   `<|vision_end|>`); image content conditions those rows through attention.
   Image patch positions expose no per-token hidden states at the pinned
   tag — the upstream helper's output flags are hard-coded false for image
   batches, and both routes around that (a vendored patch; an M-RoPE batch
   reimplementation) are barred by D-015 discipline and D-026.5
   respectively. The upstream server's own multimodal `/embeddings` at b9726
   is text-scoped in the same way. Text-only inputs are byte-identical to
   D-011 (all positions are text positions).
2. **`x = ""` is allowed for an input that carries at least one image** (the
   image alone is embedded via its delimiter-token rows); an empty string
   without an image stays rejected. An input yielding zero text rows raises
   `relm_error_embed` — never a silent zero vector.
3. **The T2 golden is a same-implementation regression pin, not an
   independent oracle** (none exists for this object at b9726: the upstream
   CLI emits no embeddings; the server pools in-graph per ubatch — a
   different object). Numeric anchoring is by decomposition — the WP-V2
   byte-exact generation golden gates the image encode+decode; the WP3
   synthetic numpy goldens gate the per-token rows and reductions — until
   the **binding** WP-V4 `mtmd_get_output_embd` ATOL leg (first addendum,
   point 2) extends nightly coverage to the encoder output.

### D-026 third addendum (2026-07-14, founder-approved at the WP-V4 release gate)

**The registry default is Qwen2-VL-2B-Instruct, not Qwen2.5-VL-3B** — amending
point 8, which named "Apache-2.0 **Qwen2.5-VL-3B**".

1. **Why the plan's model was dropped: the licence assumption was wrong.**
   Point 8 was written assuming Qwen2.5-VL-3B is Apache-2.0. It is not: the
   3B is released under the **Qwen Research License** (non-commercial,
   research-only), verified on the Hugging Face model card at WP-V4. Only the
   **2B and 7B** Qwen2-VL are Apache-2.0. A research-licensed default would
   have contradicted D-026 point 8's own stated requirement (an Apache-2.0
   default, so `llm_download()` hands every user a model they may actually
   use), and put a non-free artifact in the CI/nightly path.
2. **The substitution:** default = **Qwen2-VL-2B-Instruct Q4_K_M** + its
   f16 mmproj (aliases `qwen2-vl-2b-instruct-q4_k_m` /
   `qwen2-vl-2b-instruct-mmproj-f16`, ~2.3 GB for the pair), from
   `ggml-org/Qwen2-VL-2B-Instruct-GGUF` at the immutable revision
   `bb307c03…`, Apache-2.0 verified from the card. Every WP-V2..V4 test,
   golden, and pin is already recorded against this pair — it is the model
   the phase was actually validated on, so this addendum corrects the
   register to what shipped, and no golden moves.
3. **The Gemma quality tier stays a documented local-path route, not a
   registry alias** (founder's call, refining point 8's "Gemma/MedGemma the
   local-path quality option"): **Gemma 4 E2B** is the showcased quality
   model in the vision docs, loaded from a user-supplied path. It is not
   downloadable through `llm_download()` because Google gates the weights
   behind a click-through ToU acceptance — a checksum-pinned registry alias
   would either break for anyone who has not accepted, or invite relm to
   route around the gate. The D-023 CI/reproduction split already draws this
   line: the automated tier is Apache-2.0 and fetchable; the quality tier is
   ToU-gated and manual.
- **Why record it:** point 8 is the shipped contract for `llm_download()`'s
  vision default; leaving the register naming a model that neither ships nor
  is freely licensed is exactly the docs-vs-diff drift Hard rule 8g exists to
  catch (reviewer finding, WP-V4 gate).
- **Alternatives rejected:** shipping the 3B under its research licence
  (contradicts point 8's own Apache-2.0 requirement, and would taint CI);
  Qwen2-VL-7B as the default (Apache-2.0, but ~4.5 GB more to fetch on every
  nightly and on the 16 GB primary machine, for a default whose job is to be
  cheap and reproducible — it stays available as a local path); a registry
  alias for Gemma 4 E2B (the ToU gate makes a pinned auto-download either
  broken or evasive); delaying v0.2.0 to find an Apache-2.0 2.5-generation
  VLM (the 2B is validated, pinned, and green today — a newer generation is
  a v0.3.0 model-matrix question, not a release blocker).

### D-026 fourth addendum (2026-07-15, founder-approved at the WP-V4 release gate)

> **Two claims below were overtaken by the fifth addendum (2026-07-16) — read it
> before citing either.** (a) Point 1's "undiagnosed" and point 2's untested
> hypothesis: the cross-ISA divergence is now **diagnosed** — SIMD path alone,
> measured on one runner. (b) Point 3's `RELM_VISION_RECORDING_MACHINE` gate: the
> T2 pin is now gated on a **derived machine fingerprint** (it was an operator
> assertion, and the pin consequently ran nowhere). The text below stands as
> written — this log is append-only, and it records what was known at the time.

**A float reference is specific to the MACHINE that produced it, not to its
OS/arch. So the encoder leg builds its reference on the machine that runs it,
and stays exact everywhere.** Amending point 6 (the vision golden category) and
scoping *where* the first addendum's BINDING leg is asserted.

1. **The measurements** (`nightly-vision-golden.yaml` run 29420676427, the
   workflow's first execution on real runners; diagnostic run 29427129990):

   | comparison | what it isolates | result |
   |---|---|---|
   | relm vs upstream, **same machine** | implementation only | `max \|Δ\| = 0.0`, cos `1.000000000` — on the founder's M4 **and** on x86_64 |
   | upstream vs **itself**, x86 vs arm | ISA only | `max \|Δ\| = 3.30`, cos `0.999350281` — *diagnostic runner only* |
   | relm-x86 vs the committed arm reference | both, conflated | `max \|Δ\| = 3.30`, cos `0.999350281` — *identical to the row above* |

   The last two rows match to nine digits: **relm's image encoder contributes
   exactly zero divergence** on the two machines tested.

   **What that does and does not establish** (reviewer catch at this gate; the
   first draft of this addendum claimed "the engine is bit-exact ... there is no
   x86 bug", which is wider than the measurement and wrong in a checkable way):
   - **It gates relm's libmtmd API usage**, and only that. The encoder path
     carries **none of relm's patch** — `0001` touches `include/llama.h`,
     `llama-adapter.*`, `llama-context.*`, `llama-graph.*` (all llama-side);
     `0002` touches two `CMakeLists.txt`. Clip/mtmd/ggml are byte-identical
     source to pristine b9726, so `max |Δ| = 0.0` there is the **expected**
     result and is blind by construction to `build_cvec`, the one thing relm
     changes — which lives on the decode side this leg never enters.
   - **"No x86 bug" ≠ "no relm x86 bug".** Upstream's own encoder differs from
     its arm64 self by `max |Δ| = 3.30` (cos `0.99935`) where that was isolated;
     cross-machine values reach `8.71` (cos `0.995`), attributed to the ISA by
     inference, not isolation (point 2). That is real,
     undiagnosed, and — now that both sides of the nightly comparison are built
     on the same machine — **structurally invisible to CI**, by design. relm
     ships that upstream behavior to Linux users. Leading hypothesis (untested):
     x86 SIMD width changes the reduction order, and a ViT amplifies it;
     consistent with the gap not being constant across runners of one label.
   - **What supports shipping Linux vision** is therefore not this leg but the
     genuine cross-ISA gates: the **byte-exact T1 text golden** and the
     **token-ids pin**, both passing on `ubuntu-24.04` against an *arm-recorded*
     reference, plus the cat-vs-car semantic gate. Identical semantics across
     ISAs is the claim that carries the release; encoder bit-exactness is a
     narrower, separate one.

2. **Why no tolerance is set:** the ISA gap is not a constant. The diagnostic
   runner isolated it at `max |Δ| = 3.30` (cos `0.99935`); the nightly runner
   showed `8.71` (cos `0.995`) — two machines carrying the same `ubuntu-24.04`
   label. **The `8.71` is an inference, not an isolation:** the nightly only ever
   ran relm-x86 against the committed arm reference (the conflated row), never
   upstream against itself. Attributing it to the ISA rests on relm ≡ upstream
   holding bit-exactly on the diagnostic x86 runner; it was not separately
   isolated on the nightly's. Stated as such because this addendum's own closing
   paragraph is about a number that got written up as fact.
   Any fixed floor would have to sit below the worst runner never yet sampled,
   and a tolerance loose enough for `8.71` would pass a genuinely broken encoder.
   Comparing against a reference built **here** removes the question: the gate is
   exact, with nothing to tune.

3. **The decision:**
   - The nightly **builds the SHA-verified pristine b9726 on its own runner**
     (~12 min) and points `RELM_VISION_ENCODER_REFERENCE` at it. The leg keeps
     its exact `|Δ| <= 1e-3` assertion — **the BINDING requirement of the first
     addendum is unchanged, and now holds on every runner, not just one.**
   - The committed golden remains the fast path on its recording machine
     (`[MODEL]`, the founder's M4), where it is bit-exact.
   - **The T2 pooled pin cannot be rebuilt this way** — no upstream reference
     exists for a pooled multimodal embedding at b9726 (second addendum), so
     there is nothing to regenerate from. It stays an exact pin gated to its
     recording machine (`RELM_VISION_RECORDING_MACHINE`), and the nightly's T2
     coverage is the **cat-vs-car semantic gate**, which holds on any machine
     (observed margin 0.047 against a 0.01 floor).
   - The exact-semantic gates — the byte-exact upstream text golden and the
     token-ids pin — hold cross-ISA and stay exact on both runners.
   - **No cosine floor is introduced anywhere.** An earlier draft of this
     addendum proposed one; the diagnostic made it unnecessary, and it was
     deleted rather than kept "just in case".

4. **A second defect the same run exposed:** the cargo golden gates had **never
   executed on a macOS runner**, in any run. `ggml-metal-device.m` guards
   features with `@available(macOS 15.0, ...)`, which above the deployment target
   emits `___isPlatformVersionAtLeast` from `libclang_rt.osx.a`; R's SHLIB link
   picks the runtime up through the compiler driver, a cargo-driven link does
   not. The step was only ever reached after an earlier failure had already
   stopped the job, so nothing reported it. `build.rs` now links clang's darwin
   runtime (path from `clang -print-resource-dir`, never hard-coded).

- **Why:** comparing a float vector against a reference from another machine
  measures the machine, not the implementation — the same "comparing definitions,
  not implementations" trap the second addendum named for T2. A gate that cannot
  pass on the machine it runs on catches nothing and gets muted.
- **Alternatives rejected:** a cosine floor in the nightly (the ISA gap varies
  by runner, so the floor would be fitted to the worst sample seen rather than
  derived — and D-018 is this project's own evidence that guessing this class of
  threshold goes wrong); re-recording the committed goldens per runner (GitHub
  rotates runner CPUs without notice, so the reference would silently go stale
  and get "fixed" instead of the code — a golden you re-record when the platform
  moves is a snapshot, not a golden); dropping the float legs from the nightly
  (loses all encoder coverage on Linux); widening the exact tolerance (a
  tolerance that admits 8.71 admits anything).
- **Cost of the lesson:** the defects shipped because per-commit CI is
  model-free, so no gate before the first real nightly could have caught them —
  the reviewer and the security-auditor both passed the branch. Worse, the first
  diagnosis was wrong: the original per-element assert reported value 0's
  `|Δ| = 3.96e-2` and stopped, hiding a 200x larger divergence further in, and
  that small number was written up as "ISA noise" in an earlier draft of this
  addendum before the max-over-all-values rewrite exposed `8.71`. **A gate that
  reports the first violation instead of the worst one does not just fail to
  inform — it actively misleads.** The leg now reports the max.

### D-026 fifth addendum (2026-07-16) — the cross-ISA gap is diagnosed, and the T2 gate is derived

Two loose ends from the fourth addendum, closed. Both were tracked as
non-blocking after `v0.2.0`; neither changes shipped behavior.

**1. The encoder's cross-ISA divergence is no longer "undiagnosed".** The fourth
addendum recorded a hypothesis and marked it untested: x86 SIMD width changes the
reduction order and a ViT amplifies it. Tested (diag run 29455236480,
`diag-simd-reduction.yaml`, since deleted): pristine b9726 built **three times on
one AMD EPYC 7763 runner** (avx2 + fma, no avx512), changing nothing but the
vector path ggml compiles for.

| comparison (one machine, one source) | `max \|Δ\|` | cosine | exactly equal |
|---|---|---|---|
| native vs AVX2+FMA forced | `0.000000` | `1.000000000` | **98304 / 98304** |
| native (AVX2+FMA) vs baseline x86-64 (SSE2, no FMA) | **`1.624`** | `0.999822` | **0 / 98304** |
| committed arm64 (M4) vs this runner's native — *for scale* | `3.300` | `0.999350` | 0 / 98304 |

- **The mechanism is confirmed — by the signature, not the magnitude.** Changing
  only the vector path moves **every one of 98,304 values**, `max |Δ| = 1.624`.
  What ties that to the cross-ISA gap (`3.300`) is that both show the same
  fingerprint of float reordering: all 98,304 values move, cosine of the same
  order (`0.99982` / `0.99935`), and the biggest gaps land on the biggest values
  (ratio 9.7x / 11.2x) — which is what reordering does and what a computational
  bug does not. **Row 3 is not a controlled comparison** and the 2x is not
  attributed: arm-vs-x86 changes the kernels, `GGML_ACCELERATE` (on by default on
  Apple; `-DGGML_BLAS=OFF` does not disable it), SME/SVE runtime dispatch (point
  2 below establishes that as an independent float-moving mechanism) and the
  compiler/libm, all at once. Which of those dominates was not measured, and
  reordering divergence has no reason to be magnitude-conserving across different
  kernel sets — expecting `1.624 ≈ 3.300` would be the error. Rows 1–2 establish
  **sufficiency** on one machine; the signature is what carries the claim to arm.
- **`native == avx2` bit-for-bit** is the internal control: forcing the flags this
  hardware actually has reproduces `-march=native` exactly, so the three builds
  differ in the intended variable and nothing else.
- **It also explains the observation that most resisted explanation** — the gap
  was not constant across two `ubuntu-24.04` runners (`3.30` vs `8.71`). The
  pristine build never passes `-DGGML_NATIVE=OFF`, so ggml compiles `-march=native`
  and **each runner bakes in its own ISA**; GitHub's pool is heterogeneous (this
  one is an EPYC without AVX-512). Two runners under one label were never the same
  float machine. *Still an inference:* that the `8.71` runner had AVX-512 was not
  measured, only predicted by this mechanism.
- **"Benign" needs saying carefully, because the sloppy version of this sentence
  is what started the whole episode.** Benign at the level that ships: cosine
  `0.9998`, and the byte-exact T1 text golden passes cross-ISA — identical
  semantics. **Not** benign as "differs in the last decimals": individual values
  move by tens of percent (the worst bulk gap here is `0.470` on a value of
  `0.997` — **47% relative**). The honest claim is that this is upstream's
  arithmetic being float-path-dependent, not ours being wrong, and that the
  aggregate is stable while individual values are not.
- **Nothing to fix, therefore nothing changed.** relm contributes zero divergence
  on the machines tested (fourth addendum), the nightly's same-machine design
  already removes the question from CI, and no tolerance was invented. The
  diagnostic workflow is deleted; this table is its result.

**2. The T2 pooled-embedding pin is now gated on a derived machine fingerprint**
(hard rule 8d). The fourth addendum's `RELM_VISION_RECORDING_MACHINE=1` was an
operator assertion, and it had 8d's predicted failure mode: **the pin ran
nowhere** — skipped by design in the nightly, and skipped on the founder's Mac
because nobody remembers an env var. `helper-llm.R::machine_fingerprint()` now
derives `Darwin | arm64 | Apple M4` from the machine; the recording machine is
committed as `goldens/embed-red-square-mean.csv.machine`; the test compares and
runs or skips on the answer. Verified with the env var unset: the pin **runs**
(suite 34 passed / 0 skipped / 0 failed, was 32 / 1 / 0), a foreign fingerprint
skips with a message naming both machines, and an unrecorded golden reports `NA`.
Three model-free tests lock the mechanism into per-commit CI, since the pin itself
executes on exactly one machine in the world.

- **Why the CPU model and not the arch** (`Darwin && arm64` had already failed
  once, missing the pin by 600x the tolerance on a non-M4 arm64 runner): ggml
  keeps `GGML_ACCELERATE` on for the macOS CPU backend and dispatches on runtime
  CPU features (`ggml_cpu_has_sme`, `ggml_cpu_has_sve`). The founder's M4 reports
  `FEAT_SME = 1` and `FEAT_SME2 = 1`; earlier Apple Silicon has neither. **Two
  arm64 machines do not run the same instructions.** Same family as point 1, one
  level down.
- **Also corrected:** the test's old comment blamed "thread-pool reduction order".
  relm never sets `n_threads`, so it is 4 everywhere — thread count was never the
  variable. A plausible guess, written as if it were a finding.
- **What it does not claim:** a machine identity, not proof of float equivalence.
  A compiler or Accelerate update under a stable CPU name would go unnoticed by
  the key — and then the pin runs and **fails loudly**, which is what a golden is
  for. The dangerous direction (a pin silently not running) is the one this closes.

---

## Appendix A — Rung-3 fork playbook (archived from SOLO-PHASE-PLAN v0.1, 2026-07-03)

Preserved verbatim in substance for the day Phase 21 triggers fire (≥ 3 sustained external contributors + adoption signal + maintenance funding). If that day comes:

1. **Fork base:** the newest *patched* upstream release at fork time. **Patch-first rule:** never base on or adopt an `x.y.0`; adopt a new minor series only at `x.y.1+`; adopt upstream patch releases within ~4 weeks, only after differential CI is green; never track R-devel.
2. **Divergence registry:** every modification of upstream sources recorded in `PATCHES.md` (file, reason, date, revert plan); divergence kept minimal and mechanical so upstream merges stay cheap.
3. **Non-negotiable invariant:** the fork passes upstream's own `make check-all` (including recommended packages) on every commit to `main` — the machine-checkable definition of "we didn't break R".
4. **Versioning:** `R-ebirth X.Y (compatible with R x.y.z)` — the upstream compatibility level always stated, including in `R.version`.
5. **Scope reserved to the fork (nothing else justifies it):** speculative JIT in the evaluator; real surface syntax (type annotations, `async`/`await` keywords); base-default changes. All three stay function-based/API-level until then.
6. **Licensing at rung 3:** the fork repository inherits GPL-2 | GPL-3 (combined distributions effectively GPL-3 for Apache-2.0 compatibility); the permissive Rust crates (`rebirth-llm` etc.) remain MIT OR Apache-2.0 and are linked in — which is why they must stay R-free (see `ARCHITECTURE.md` §2).
