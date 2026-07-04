# R-ebirth — Solo Phase Plan

**Document 1 of 3** — operational decisions for the solo-development period (Phase 0 through end of Phase 1).
Companion documents (to be written): `ARCHITECTURE.md` (document 2 — package internals, native boundary, ladder mechanics) and `API-GRAMMAR.md` (document 3 — final function signatures and naming rules).
Operational companion: **`ROADMAP.md`** — work packages, toolchain, prompts for the coding model, and the thesis case study (WP-T). This plan states *decisions*; the roadmap states *execution*.

- **Status:** draft **v0.2** for founder review
- **Date:** 2026-07-03 (v0.1 same day; superseded)
- **Owner:** Alessandro (founder) + Claude (AI engineering)
- **Scope:** everything needed to build alone, before any community involvement.

**What changed in v0.2 (decision D-002):** v0.1 planned a source fork of GNU R as the delivery vehicle from day one. v0.2 changes the *delivery vehicle*, not the vision: the solo phase ships as a **package suite running on unmodified R**, with the fork deferred to the community era as the third rung of an explicit ladder (§0). Everything already designed — API grammar, Rust crates, demos, correctness harness, memory-budget rules — carries over unchanged. Consequences ripple through §1, §3, §4, §6, §7, §9. A major side effect: the GPL constraint disappears and the project can be licensed maximally free (§6).

---

## 0. Delivery strategy: the three-rung ladder

**Decision: capabilities first, language later. Each rung is climbed only when the previous one has proven demand, and nothing built on one rung is discarded on the next.**

- **Rung 1 — the package suite (solo phase, now).** `rebirth` (and later satellite packages) on stock R ≥ 4.5: the native inference engine with activation taps, the tidy-anatomy workflow, embeddings, topic modelling, steering/ablation — everything in the Phase 0–1 deliverables. Installs with one command into the R every researcher already has.
- **Rung 2 — the distribution (transition).** An installer bundling vanilla R + the R-ebirth suite preinstalled + curated defaults (packages auto-attached via site profile, sensible options, pinned versions). Delivers the "batteries included, feels like a new environment" experience **without forking a single line of R**.
- **Rung 3 — the fork (community era).** Only for the things a package can never do: new surface syntax (real type annotations, `async`/`await` keywords), changed base defaults, the speculative JIT in the evaluator, allocator/GC work. Entered only when there is a community to share the permanent upstream-merge tax. The v0.1 fork plan (base pinning, patch-first rule, PATCHES.md, upstream `make check` invariant) is preserved verbatim in `DECISIONS.md` as the rung-3 playbook.

**What a package genuinely cannot do** (the honest boundary, so it is never rediscovered by surprise): modify the parser, change base-R defaults, replace the evaluator/GC, or make R itself faster on arbitrary user loops. **Interim mitigations on rung 1:** function-based forms instead of new syntax (`async({...})`/`await()` in the promises tradition; type declarations as arguments rather than annotations), and — Phase 2 option — a `reb_compile()` transpiler for typed hot functions (nimble/odin precedent). Everything else discussed for research capability — speed on real workloads, the LLM anatomy lab, topic modelling, the base-R grammar — is fully deliverable from the package, because the heavy compute lives in the native engine either way.

---

## 1. R version support (replaces v0.1 "fork base")

**Decision: develop and test primarily on R 4.6.1 "Happy Hop" (2026-06-24); declare `Depends: R (>= 4.5.0)`.**

- CI tests against **R-release and R-oldrel** on every platform; never require R-devel features.
- The v0.1 "patch-first rule" survives in spirit: new upstream minor versions (e.g. a future 4.7.0) enter the CI matrix immediately but the declared minimum moves conservatively and never to an `x.y.0`.
- Nothing of R is modified, so there is no divergence registry and no upstream merge tax — that burden is deferred to rung 3.

---

## 2. API grammar: base R first (unchanged from v0.1)

The grammar decisions are delivery-independent — identical whether the functions live in a package or in a fork's base. This is precisely why the pivot wastes nothing. Binding rules (final signatures in `API-GRAMMAR.md`):

1. **Model-object idiom:** `m <- llm("qwen2.5-1.5b-instruct-q4_k_m.gguf")` returns an S3 object; inspection via `print(m)`, `summary(m)`, `str(m)`.
2. **S3 generics and methods** wherever natural: `predict`, `plot`, `summary`, `coef`, `as.data.frame`, `as.matrix`.
3. **Returns are base structures:** plain `data.frame` (classed for printing/plot methods) and base `matrix`. No tibble dependency; dplyr/ggplot2 interop is automatic.
4. **`llm_` family prefix:** `llm()`, `llm_generate()`, `llm_embed()`, `llm_trace()`, `llm_steer()`, `llm_ablate()`, `llm_logits()`, `llm_tokens()` (`base::embed()` collision noted).
5. **Capture filters as first-class arguments** (16 GB rule, §3): `llm_trace(m, prompts, layers = 8:16, positions = "last", components = "residual", spill = TRUE)`.
6. **Native pipe `|>`** everywhere; no magrittr.
7. **Formula interfaces where natural** (Phase 1): `llm_probe(label ~ activations(layer = 10:20), data = tr)`.
8. **Errors are R conditions** with actionable messages; Rust panics never reach the console raw.
9. **Every exported function ships a runnable self-contained example**, executed in CI.
10. **All identifiers, messages, docs in English.**

Package namespace: **`rebirth`** — verified available on CRAN and unclaimed on GitHub as an R project (checked 2026-07-03). "R-ebirth" remains the umbrella project/brand name.

---

## 3. Platforms and test matrix (updated — the package makes this cheaper)

| Tier | Platform | Backend | Where it runs | When |
|------|----------|---------|---------------|------|
| 1 (primary) | macOS arm64 | Metal | Mac mini M4 16 GB (RStudio + console) | Phase 0 |
| 1 | Linux x86_64 + arm64 | CPU | GitHub Actions CI; local arm64 VM for smoke tests | Phase 0 |
| 2 | Linux + CUDA | CUDA | WSL2 Ubuntu on the founder's Windows PC (RTX 2060, 6 GB) | Phase 1, early |
| 2 (was 3) | Windows native | CPU, then CUDA | Same PC | Phase 1 |

Notes:

- **Windows is dramatically cheaper on the package path** than it was for the fork: no interpreter build, just a package with native code under the standard Rtools toolchain — and **users never compile anything** because r-universe serves prebuilt binaries (§4). Windows native is therefore promoted from "experimental at Phase 1 exit" to a full tier-2 target during Phase 1. CUDA validation still starts on WSL2 (cheapest route), then moves native.
- **Mac mini memory budget (≈10–11 GB free)** unchanged: capture filters mandatory, large traces spill to Arrow IPC files reopened lazily; a full trace degrades to disk, never OOMs the session.
- **Local Linux VMs** (UTM/lima, arm64 Ubuntu): smoke tests only, VM ≤ 4 GB, never concurrently with a 7B model; heavy testing lives in CI.
- **MLX:** still Phase 2, via `mlx-c`, as a second backend behind the same R API.
- **Pinned reference models** unchanged: synthetic ~2-layer GGUF in-repo for exact-value unit tests; Qwen2.5-0.5B-Instruct Q8_0 (~0.5 GB, Apache-2.0) for CI integration; Qwen2.5-1.5B-Instruct Q4_K_M (~1 GB) as demo model and 7B Q4 as quality option. Llama-family supported but not demo defaults (license gating).

---

## 4. Repository, build, CI, distribution (updated)

Layout:

```
r-ebirth/
├── rebirth/              # the R package (R/, src/, man/, tests/, vignettes/)
├── rust/                 # cargo workspace
│   ├── rebirth-llm/      # inference engine wrapper + activation taps (MIT|Apache-2.0)
│   ├── rebirth-kernel/   # columnar kernels (later; off critical path)
│   └── rebirth-ffi/      # SEXP boundary — one crate owns all unsafe
├── vendor/               # pinned llama.cpp (patched for taps) + NOTICE
├── tests/
│   ├── llm-golden/       # logits + activation goldens vs reference implementations
│   └── demos/            # the two reference demos as executable acceptance tests
├── docs/
├── DECISIONS.md          # decision log (D-001 grammar, D-002 ladder pivot, ...)
└── CLAUDE.md             # AI session context
```

- **Build:** cargo invoked from the package's `src/Makevars`; vendored crates for CRAN compliance later; the llama.cpp tap patch set versioned in `vendor/`.
- **Distribution from day 1: r-universe.** It builds **binary packages for macOS, Linux, and Windows automatically** — testers run one `install.packages()` with a repo URL and never need Rust, Xcode, or Rtools. CRAN submission is a Phase 1 exit goal (their Rust vendoring policy is accounted for in the layout), not a Phase 0 concern.
- **CI harnesses:**
  - **Harness A (new meaning):** `R CMD check --as-cran` clean on {macOS arm64, Linux x86_64/arm64, Windows} × {R-release, R-oldrel}. The v0.1 harness A (upstream `make check`) is obsolete — nothing of R is modified, so there is nothing to break by construction.
  - **Harness B (unchanged, the crown jewel):** logits vs unpatched reference llama.cpp token-by-token on pinned models (documented tolerance per quantization); activations vs precomputed PyTorch/TransformerLens goldens in `tests/llm-golden/`. Per commit on the synthetic model; nightly on the 0.5B.
  - **Nightly:** ASAN/UBSAN, valgrind on Linux, long-session leak test (1,000 trace/generate cycles, flat RSS), both demos end-to-end.
- **RStudio:** nothing to verify beyond normal package behavior — it is just a package in the user's existing R. (The v0.1 drop-in machinery is gone.)

---

## 5. Decision log and AI-assisted workflow (unchanged)

- **`DECISIONS.md`** — append-only ADR-lite (`ID / date / decision / why / alternatives rejected`). D-002 (this pivot) is its first major entry; the v0.1 fork playbook is archived there for rung 3.
- **`CLAUDE.md`** — standing AI-session context: current phase, constraints (§2 grammar, §3 memory budget, §6 licensing), pointers to the three documents.
- **Spec-first rule:** no exported function before its `API-GRAMMAR.md` entry is accepted by the founder.
- **Golden-first rule:** the correctness golden exists before the feature it validates is merged.

---

## 6. Licensing and naming (major update — founder guideline now fully satisfied)

**Decision: everything original is dual-licensed `MIT OR Apache-2.0`. The GPL constraint of v0.1 no longer applies.**

- The GPL inheritance in v0.1 came solely from modifying GNU R's sources. A package does not derive from R's code — it is original work using R's public API, and the R ecosystem's settled practice (CRAN hosts MIT/Apache/BSD packages routinely) supports permissive licensing. Result: **the founder's "freest possible license" guideline is now met in full** — any person, lab, startup, or corporation can use, modify, embed, and redistribute, including in proprietary products.
- `rebirth` (R package), `rebirth-llm`, `rebirth-kernel`, `rebirth-ffi` (Rust crates): **MIT OR Apache-2.0**.
- Vendored llama.cpp: MIT — compatible; tracked in `NOTICE`.
- **Name protection unchanged (`TRADEMARK.md`):** the code is free, the name is not. Modified redistributions must rename (Rust/Firefox model). This remains the correct instrument for "my work must not be confused with someone else's fork."
- Project self-description: *"R-ebirth — a scientific computing toolkit for R"* on rung 1; the "derived from GNU R" phrasing belongs to rung 3 only. No use of the R Foundation's logo or implied endorsement.
- Rung-3 note for the future: if/when the fork happens, *that repository* inherits GPL-2 | GPL-3 — but the crates stay permissive and simply get linked in, which is exactly why the permissive-core structure is right today.

---

## 7. Non-goals through end of Phase 1 (updated)

- **No source fork of GNU R** — re-evaluated only at the community rung (D-002).
- **No new surface syntax** (type annotations, `async`/`await` keywords) — parser work is rung 3; interim function-based forms only.
- **No JIT / evaluator work** — rung 3 by definition now.
- **No Arrow-backed default verbs on the critical path** — the LLM module returns plain R structures first; kernel/Arrow work proceeds behind a flag.
- **No MLX backend** (Phase 2), **no fine-tuning / LoRA training / RLHF** (Phase 2), **no SAE training** (Phase 2; applying pretrained SAEs = late-Phase-1 stretch, decided then).
- **No `serve`/streaming before the second half of Phase 1.**
- **No multi-GPU, no distributed, no cloud integration.**
- **No CRAN submission before Phase 1 exit** (r-universe carries distribution until then).
- **No public release engineering** beyond r-universe binaries (no website/installer campaigns) until the community phase.

---

## 8. Reference demos (unchanged — the pivot does not touch them)

Both demos pinned to license-clean models, runnable on the Mac mini 16 GB from RStudio, offline after one model download, seeded and reproducible. The medical-bias scenario stays deferred to documentation as a carefully-framed exploratory case study — not a launch demo (a launch demo must survive hostile expert scrutiny; "how to *investigate*" does, "we fixed clinical bias" does not).

### Demo A — flagship: "The anatomy lab"
1. `m <- llm("qwen2.5-1.5b-instruct-q4_k_m.gguf")`
2. Contrast prompt pairs (opposite **sentiment**) → `llm_trace()` on a band of layers.
3. Concept direction via plain `prcomp()` — deliberately classical.
4. Cross-validated per-layer probes (`glmnet`) → **the money plot**: decodability (AUC + CI) by layer, in ggplot2 — "where sentiment becomes readable."
5. `llm_steer()` along the direction; before/after generations; statistical verification on held-out prompts.

Target: ~40 lines of base-R idiom, < 10 minutes end-to-end on the Mac mini.

### Demo B — utility: "Topic modelling without Python"
~5,000 public abstracts → `llm_embed()` → `uwot::umap()` + `dbscan::hdbscan()` (unchanged CRAN packages, ecosystem compatibility live) → cluster naming via `llm_generate()` → one labeled map. A BERTopic-class pipeline, fully local, zero Python.

**Acceptance:** both live in `tests/demos/`, run nightly in CI (Demo A on the CI model with relaxed thresholds), and run on the founder's Mac mini from RStudio with pinned seeds giving identical outputs across runs.

### Case study (Phase 1) — master's thesis: statistical audit of a medical LLM

The founder's thesis (MSc Public and Health Economics, UniMol) doubles as the first real-world application: a demographic-sensitivity audit of **MedGemma 1.5 4B** (local GGUF) on radiology-report triage, using `llm_trace`/`llm_probe`/`llm_steer` for the internal analysis and a health-economics framing (misclassification costs, equity in AI-assisted screening, local-vs-API deployment economics). Full design, data plan (OpenI reports primary, MIMIC-CXR upgrade path), and timeline live in `THESIS-PLAN.md`. Framing rule applies: *audit and investigation*, never "bias fixed." **Parked 2026-07-04:** the thesis will be assigned in ~6–8 months; the plan resumes then and gates nothing else.

---

## 9. Phase exit checklists (updated)

**Phase 0 exit (~month 3, was ~4 — fork bootstrap no longer exists):**
- [ ] `install.packages("rebirth", repos = <r-universe>)` works on stock R 4.6.1 (macOS binary at minimum)
- [ ] `R CMD check` clean on macOS arm64 + Linux (Windows may lag until Phase 1)
- [ ] `llm()`, `llm_generate()`, `llm_embed()`, `llm_trace()` (filters + spill), `llm_steer()`, `llm_ablate()` working on GGUF models (Qwen + Llama families)
- [ ] Harness B green: logits vs reference llama.cpp, activations vs PyTorch goldens
- [ ] Demo A and Demo B pass as scripted acceptance tests on the Mac mini (RStudio)
- [ ] Seeded generation reproducible run-to-run
- [ ] `DECISIONS.md`, `CLAUDE.md` in active use

**Phase 1 exit (~month 10–12):**
- [ ] Async generation integrated with the console event loop (session never blocks; `promises`-style API)
- [ ] Streaming verbs v1 (token streams as data; windowed aggregation prototype)
- [ ] Type declarations as function API (runtime-checked); `reb_compile()` transpiler explored and go/no-go decided
- [ ] `serve` module v1: an analysis exposed as a typed HTTP endpoint with generated OpenAPI
- [ ] Windows binaries on r-universe; CUDA green (WSL2 first, then native Windows)
- [ ] CRAN submission of `rebirth` (Rust vendoring policy compliant)
- [ ] Docs site generated from runnable examples; `llm_*` API declared stable
- [ ] WP-T (thesis case study) — **parked, not blocking Phase 1 exit** (thesis assignment ≈ Q1–Q2 2027; see `THESIS-PLAN.md`)
- [ ] Full CI matrix green 30 consecutive days before declaring Phase 1 closed

---

## 10. Open questions routed to the next two documents

- `ARCHITECTURE.md` (document 2): `rebirth-ffi` unsafe-boundary design; tap-patch maintenance strategy against upstream llama.cpp releases; spill file format; async integration with R's event loop; rung-2 distribution mechanics; rung-3 trigger criteria (what observable success justifies the fork).
- `API-GRAMMAR.md` (document 3): full signatures and defaults for every `llm_*` function; trace data.frame schema (`layer`, `token_pos`, `component`, `neuron`, `value`, `prompt_id`); condition class hierarchy; print formats.
- Deferred, tracked in `DECISIONS.md` when opened: Phase 2 training backend (candle vs libtorch), MLX binding scope, satellite package split (`rebirth.topics`?), Positron timing.
