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

## Appendix A — Rung-3 fork playbook (archived from SOLO-PHASE-PLAN v0.1, 2026-07-03)

Preserved verbatim in substance for the day Phase 21 triggers fire (≥ 3 sustained external contributors + adoption signal + maintenance funding). If that day comes:

1. **Fork base:** the newest *patched* upstream release at fork time. **Patch-first rule:** never base on or adopt an `x.y.0`; adopt a new minor series only at `x.y.1+`; adopt upstream patch releases within ~4 weeks, only after differential CI is green; never track R-devel.
2. **Divergence registry:** every modification of upstream sources recorded in `PATCHES.md` (file, reason, date, revert plan); divergence kept minimal and mechanical so upstream merges stay cheap.
3. **Non-negotiable invariant:** the fork passes upstream's own `make check-all` (including recommended packages) on every commit to `main` — the machine-checkable definition of "we didn't break R".
4. **Versioning:** `R-ebirth X.Y (compatible with R x.y.z)` — the upstream compatibility level always stated, including in `R.version`.
5. **Scope reserved to the fork (nothing else justifies it):** speculative JIT in the evaluator; real surface syntax (type annotations, `async`/`await` keywords); base-default changes. All three stay function-based/API-level until then.
6. **Licensing at rung 3:** the fork repository inherits GPL-2 | GPL-3 (combined distributions effectively GPL-3 for Apache-2.0 compatibility); the permissive Rust crates (`rebirth-llm` etc.) remain MIT OR Apache-2.0 and are linked in — which is why they must stay R-free (see `ARCHITECTURE.md` §2).
