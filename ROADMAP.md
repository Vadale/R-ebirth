# R-ebirth Roadmap — Execution Plan

Operational companion to `SOLO-PHASE-PLAN.md` (decisions) and `THESIS-PLAN.md` (the thesis case study). This document states *execution*: phases, work packages, toolchain, acceptance tests, and prompts for the coding model.

- **Status:** v3.0 — **22 phases**, covering the *full* original vision (not just the old Phase 0/1 scope): the package path removed the fork-era constraints, so everything from the founding discussions that is solo-deliverable is now a numbered phase. Ordering rule unchanged: **everything achievable by one person + a coding model comes first; phases that genuinely require more than one human are explicitly last.**
- **Date:** 2026-07-03
- **Owner:** Alessandro (founder)
- **Written by:** the planning model (Claude). **Implementation is driven by a separate coding model** using the prompts in §5.
- **Mapping to `SOLO-PHASE-PLAN.md`:** the plan's "Phase 0" = roadmap **Phases 0–3**; the plan's "Phase 1" = roadmap **Phases 4–9**. The plan's exit checklists apply unchanged at those boundaries.
- **Deliberately out (settled decisions, not omissions):** XLA/TVM integration; datacenter-scale RLHF/PPO; rebuilding what the ecosystem already does well (API clients = ellmer, RAG = ragnar, evals = vitals); JIT and new surface syntax (those live in the final fork phase by design); webR/Wasm builds (revisit post-v1.0 if demand appears).

**Design principle: every phase ends shippable.** Each phase closes with a working, tested, releasable state — the project can pause at any boundary and still be a useful public tool.

---

## 0. Execution model and ground rules

### Roles
- **Founder:** decides, reviews every diff, runs acceptance tests on real hardware (Mac mini M4 16 GB; Windows/RTX 2060 PC from Phase 8), owns the thesis.
- **Coding model:** implements one work package (WP) at a time from the prompts in §5.

### The loop
1. Pick the next WP (strict order within a phase; one WP in flight).
2. Paste the **Session Preamble** (§5.1) + the WP prompt (ready-to-paste library in §5.3; §5.2 pattern for phases not yet covered).
3. The coding model implements in small steps, tests first where possible.
4. Founder reviews with the checklist (§5.4), runs acceptance locally, commits.
5. WP acceptance fully green → mark done here → next WP. All WPs of a phase done → tag a release.

### Ground rules (bind every session — also in `AGENTS.md`)
1. Everything in **English** (code, identifiers, comments, docs, commits).
2. API grammar per `SOLO-PHASE-PLAN.md` §2: base-R idiom, S3, plain `data.frame`/`matrix`, `llm_*` prefix, native `|>`.
3. **Spec-first:** no exported function before its `API-GRAMMAR.md` entry is approved.
4. **Golden-first:** numerical features merge only with their reference goldens.
5. **No new dependencies** (R or Rust) without an approved `DECISIONS.md` entry.
6. Tests pass locally before "done"; CI green before merge.
7. Small, reviewable diffs; one concern per commit.

---

## 1. Toolchain (install once, before Phase 0)

### Mac mini M4 (primary)
| Tool | Purpose | Notes |
|---|---|---|
| R 4.6.1 (CRAN, arm64) | the platform | dev target |
| RStudio (latest) | founder's IDE | package must feel native here |
| Xcode Command Line Tools | C/C++ toolchain, Metal | `xcode-select --install` |
| rustup → Rust stable + `rustfmt`, `clippy` | native engine | pin in `rust-toolchain.toml` |
| CMake ≥ 3.28, git, gh CLI | build + repo/CI | Homebrew |
| R dev pkgs: `rextendr`, `devtools`, `usethis`, `testthat`≥3, `roxygen2`, `pkgdown`, `styler`, `nanoarrow` | development | `nanoarrow` = spill-file reader |
| R analysis pkgs: `glmnet`, `uwot`, `dbscan`, `ggplot2`, `pROC` | demos + thesis | all CRAN, unchanged |
| `huggingface-cli` | model downloads | accept MedGemma (HAI-DEF) terms once |
| Reference llama.cpp build (unpatched) | harness B comparator | same pinned tag as `vendor/` |
| Python 3.12 venv: `torch`, `transformers`, `numpy`, `gguf` | **golden generation only** | test tooling, never a runtime dependency |
| Quarto | vignettes; thesis manuscript | |

### Windows PC, RTX 2060 (from Phase 8)
WSL2 + Ubuntu 24.04 + CUDA toolkit (CUDA-on-WSL2 first); native later: R 4.6.x + matching Rtools + rustup.

### Accounts
GitHub repo (public recommended from first tag); r-universe org (automatic macOS/Linux/Windows binaries); Hugging Face with MedGemma terms accepted.

---

## 2. The phase map

**Solo track (one person + coding model):**

| Phase | Name | Exit deliverable |
|---|---|---|
| **0** | Foundations | models load on the Mac; CI-green skeleton |
| **1** | Generation & embeddings | reproducible generation; embeddings usable (topic modelling already possible via CRAN) |
| **2** | The anatomy lab | traces, steering, ablation — numerically validated |
| **3** | First public release | `v0.1.0` on r-universe, stranger-installable |
| **4** | Probe API *(thesis pilot parked)* | `llm_probe()` formula interface working; thesis WP-T parked until assignment (≈ Q1–Q2 2027) |
| **5** | Async & token streaming | console never blocks; token streams as data |
| **6** | Live introspection & guardrails | per-token activation monitoring + intervention hooks during generation |
| **7** | Types & serving | runtime type contracts; typed HTTP endpoint + OpenAPI |
| **8** | Windows & CUDA | harness B green on CUDA (WSL2); Windows binaries |
| **9** | CRAN, docs & API freeze | CRAN release; AI-readable docs; `llm_*` stable; **v1.0** |
| **10** | MLX backend | second Apple-native engine behind the same API |
| **11** | Multimodal models | vision GGUF (mmproj): image+text locally — radiology images unlocked |
| **12** | Fine-tuning | `llm_finetune()` (LoRA/QLoRA on small models) |
| **13** | Alignment & RL | preference optimization (DPO-class) on small models, with evals |
| **14** | Topics & SAE analysis | `rebirth.topics` package; pretrained-SAE features on traces |
| **15** | Model export & interop | ONNX export for classical R models; adapter export — "write in R, deploy anywhere" |
| **16** | Real-time data streams | general tidy-streaming: the "infinite data.frame" on live sources |
| **17** | Fast data layer | Arrow-native verbs; `reb_compile()`; public benchmarks |
| **18** | Science verticals (`rebirth.bio`) | native protein/DNA LM inference + **tidy mech-interp of protein LMs** + residue-graphs + zero-shot variant effect — the R answer to graphein/ESM |

**Team track (deliberately last — requires more than one person):**

| Phase | Name | Why it needs a team |
|---|---|---|
| **19** | The distribution (rung 2) | multi-OS installers, signing, support burden |
| **20** | Community & governance | contributors, review capacity, grants, papers |
| **21** | The fork (rung 3) | JIT, new syntax, base defaults + permanent upstream-merge tax |

---

## 3. Solo phases in detail

> Phases 0–4 carry full work-package detail (they are next). Phases 5–9 are specified at WP level. Phases 10–18 are specified at phase level (goal/scope/exit) — each gets its WP breakdown when it becomes current, as its own planning session.

### Phase 0 — Foundations (~3 weeks)

**WP0 — Repository bootstrap (week 1).**
`git init`; layout per plan §4 (`rebirth/` scaffolded with `rextendr::use_extendr()`, `rust/` workspace with `rebirth-ffi`, `rebirth-llm`; `vendor/`, `tests/llm-golden/`, `tests/demos/`, `docs/`); `LICENSE` (dual MIT OR Apache-2.0), `TRADEMARK.md`, `NOTICE`; seed `DECISIONS.md` (D-001 grammar, D-002 ladder) and `AGENTS.md` (= §5.1); GitHub Actions: `R CMD check` (macOS arm64 + Ubuntu), `cargo test` + `clippy` + `rustfmt --check`.
*Acceptance:* clean `R CMD check` (0 errors/warnings) with the stub package on both platforms; workspace builds; README states scope honestly.

**WP1 — Vendored engine + model loading (weeks 1–3).**
Vendor llama.cpp at a pinned tag (tag + SHA in `vendor/README`); static-lib build from `src/Makevars`, Metal on macOS, CPU fallback; `rebirth-ffi` = the single unsafe boundary, Rust errors → classed R conditions; `llm()` returns an S3 object (external pointer + metadata); `print.llm`, `summary.llm`; GC-safe finalizer.
*Acceptance:* loads Qwen2.5-0.5B (CI model) and MedGemma-1.5-4B Q4 on the Mac; `summary(m)` correct; 100× load/unload → flat RSS; corrupt/missing file → catchable condition, never a crash.

### Phase 1 — Generation & embeddings (~3 weeks)

**WP2 — Tokenization + generation.**
`llm_tokens()` (UTF-8-correct; Italian-text tests); `llm_generate()` (`max_tokens`, `temperature`, `top_p`, `seed`, `chat = TRUE` with Gemma + Qwen templates, stop sequences); documented determinism contract.
*Acceptance:* seeded generation identical across runs/sessions; greedy decoding matches unpatched reference llama.cpp **token-for-token**; chat templates match reference for both families.

**WP3 — Embeddings.**
`llm_embed()` → base `matrix`; pooling (`"mean"`, `"last"`, model default), L2-normalization flag; batching; generative + dedicated embedding GGUFs.
*Acceptance:* dims match model card; similarity fixture ranks correctly; golden vs reference where available.

**WP6a — Harness B, first slice (parallel).**
`tests/llm-golden/` structure; Python fixture scripts; the **synthetic 2-layer seeded GGUF builder** (committed — exact-value tests, no download); CI wiring per commit.
*Acceptance:* logit goldens active in CI for WP2 paths.

> **Phase 1 exit bonus:** `llm_embed()` + CRAN's `uwot`/`dbscan` = BERTopic-class topic modelling without Python, already.

### Phase 2 — The anatomy lab (~6 weeks; the core)

**WP4 — Activation taps + `llm_trace()`.**
Tap patch on vendored llama.cpp (residual stream post-block, attention out, MLP out; opt-in, guarded, zero overhead when off); `llm_trace(m, prompts, layers=, positions=, components=, spill=TRUE)` → classed `data.frame` (`prompt_id, token_pos, token, layer, component, neuron, value`); spill = Rust writes Arrow IPC, R reopens lazily via `nanoarrow`; `as.matrix()` slice accessor.
*Acceptance:* synthetic-model activations match the independent numpy oracle exactly (ATOL 1e-2, per-component and per-position); CI-model activations vs HF fp32 validate tap semantics at a documented scale-robust tolerance (per-layer Spearman / per-row cosine ≥ ~0.94), anchored by the exact residual-decomposition identity and top-k logit agreement (**D-018** — ≥ 0.999/layer vs an independent HF reference is not achievable and is not asserted); full 4B trace on 16 GB spills and completes; tap-off overhead < 2%.

**WP5 — Interventions.**
`llm_steer(m, layer, vector, coef, positions)` (composable, removable); `llm_ablate(m, layer, neurons, value = 0)`; head ablation = stretch.
*Acceptance:* sentiment-direction steering shifts valence on held-out prompts (statistical fixture); matched-random ablation ≈ null vs targeted; after removal, outputs reproduce bit-for-bit.

**WP6b — Harness B complete.**
Activation goldens; nightly 0.5B tolerance runs; the **mutation test** (injected off-by-one layer index must make the harness fail).
*Acceptance:* mutation test fails loudly; golden regeneration documented.

### Phase 3 — First public release — v0.1.0, text-only (~2 weeks + WP7.5 ≈ 4 weeks)

> **WP7.5a/b (D-021 / D-022) are inserted between WP7 and WP8** — modern models usable as text + richer demo analysis/viz. **Vision is deferred to v0.2.0 / Phase 11 (D-023)**; v0.1.0 ships text-only.

**WP7 — Demos as acceptance tests.** ✅ merged (PR #17).
Demo A "anatomy lab" (contrast set → trace → `prcomp` → per-layer `glmnet` probes → AUC+CI plot → steer verification); Demo B "topics without Python"; **Demo C (optional stretch) "biological-sequence anatomy lab"** — any protein/DNA-sequence encoder that already loads through the engine (BERT-class today; full ESM-2 support is the Phase-18 arch ADR) → `llm_embed`/`llm_trace` → a per-layer `glmnet` probe that localizes a residue-level property → the same money-plot, on biology. Scripts in `tests/demos/` + draft vignettes.
*Acceptance:* Demos A and B each < 10 min on the Mac mini from RStudio; pinned seeds ⇒ identical outputs; Demo A nightly in CI. **Demo C does not gate Phase 3** — it ships if an encoder loads cleanly (makes the biology promise runnable at first release, per D-010), otherwise it becomes the seed of Phase 18.

**WP7.5a — Modern models as text (D-021).** ✅ merged (PRs #19, #20). Day-1 spike (founder's Mac, Metal): pin text-only instruct GGUFs (Gemma 4 up to 12B, Qwen 3.5 up to ~9B, Qwen 3 mid-sizes; Gemma-3-4B text-only as control) → support matrix (`docs/wp7.5-model-matrix.md`, SHA256/license/RSS/tokens-s); `llm_trace` per-arch matcher extension (qwen3/qwen35/gemma4, with the adversarial test rejecting gemma4's same-named `attn_out` collision); a **runtime sentinel intervention probe** replacing the D-016 hard allow-list; WP5 `[MODEL]` valence/KL fixtures on the new families. Engine untouched in the default path; the vendor bump is conditional (trigger-gated, 3-day timebox, revertible).
*Acceptance:* matrix committed; a text-only Gemma 4 E4B GGUF loads; per-arch trace `[MODEL]` tests + the gemma4-`attn_out` rejection test; the sentinel probe passes on synthetic + all pinned decoders and rejects a no-choke-point case with `rebirth_error_intervention`; original-handle bit-for-bit reversal still green; `cargo test` + `R CMD check` green.

**WP7.5b — Demo analysis & visualization deepening (D-022).** ✅ merged (PRs #21–#23). Five Demo A mech-interp analyses (A1 multi-concept overlay, A2 token×layer heatmap, A3 steering dose–response, A4 targeted-vs-random ablation curve, A5 direction geometry) + Demo B depth (silhouette, log-odds top terms, inter-topic dendrogram) + a base-R visual-polish pass. Behind `extended = TRUE`; **zero new dependencies**.
*Acceptance:* extended runs ≤ +10 min per demo on the Mac + nightly on 0.5B; fixed seeds ⇒ byte-identical numeric re-runs; extended `demo_utils_selftest()` green per commit; A4 random control near-null while targeted discriminates; vignettes render model-free; no `DESCRIPTION` diff.

**WP8 — Docs + release.** WP8a `llm_download()` ✅ merged (PR #24); WP8b docs (README + pkgdown + NEWS + version bump) in progress; WP8c (create the r-universe org + tag `v0.1.0`) = founder gate.
roxygen2 with runnable examples (run in CI); README quickstart; **`llm_download()` helper for pinned models** (checksums verified); pkgdown site; r-universe live; `NEWS.md`; tag **`v0.1.0`**. Demo default = **Gemma 4 E4B (as text)**, showcased; the **license-clean reproduction path + CI stay on Qwen (Apache-2.0)** (D-023).
*Acceptance:* `install.packages("rebirth", repos = <r-universe>)` works on clean R 4.6.1; a stranger runs Demo B from the README alone on the Apache-2.0 default (Qwen).

> **= `SOLO-PHASE-PLAN.md` Phase 0 exit checklist.**

### Phase 4 — Probe API (thesis pilot parked)

**WP11 — `llm_probe()` formula API**: `llm_probe(label ~ activations(layer = 10:20), data = tr, method = "glmnet", cv = 10)`; tidy stats output; `plot()` = the standardized decodability figure. A core capability regardless of the thesis. *Acceptance:* reproduces Demo A's manual pipeline in ~5 lines.
**WP-T pilot — PARKED (2026-07-04).** The founder's thesis assignment is ~6–8 months away (≈ Q1–Q2 2027); `THESIS-PLAN.md` stays ready and resumes unchanged then. Convenient consequence: by assignment time the software will be several phases ahead of the thesis's needs (it requires only Phases 1–2 plus `llm_probe`). No WP-T work until then.

### Phase 5 — Async & token streaming

**WP9 — Async generation:** `later`/`promises` integration — generation returns a promise, console stays live, progress callbacks. *Acceptance:* long generation never blocks RStudio; async result equals seeded sync result.
**WP10 — Token streaming v1:** token streams as data (callback/connection API); windowed aggregation prototype. *Acceptance:* live token stream feeds a growing data.frame; live token-statistics demo.

### Phase 6 — Live introspection & guardrails *(new — from the founding vision)*

**Goal:** watch and act on the model's internals *while it generates* — the founding document's "live guardrail," delivered as research instrumentation.
**Scope:** per-token callbacks receiving token, logit summaries, and selected activations (`llm_generate(..., on_token = function(state) ...)`); streaming traces (windowed `rebirth_trace` chunks during generation, spill-aware); intervention hooks callable from the R callback (abort, adjust steering coefficient mid-generation); documented overhead budget.
**Exit:** demo — live monitoring of a concept-direction score token-by-token during generation; a guardrail *research demo* that halts generation when a probe score crosses a threshold. **Framing rule applies:** the deliverable is the *mechanism*; detection reliability is an open research question, never a safety guarantee.

### Phase 7 — Types & serving

**WP14 — Type contracts + `reb_compile()` spike:** runtime-checked type declarations (API form; **no new syntax** — that boundary belongs to Phase 21); transpiler spike → go/no-go ADR with benchmarks. *Acceptance:* contracts catch type errors with clear conditions; ADR written.
**WP12 — `serve` v1:** decision spike (plumber vs thin `httpuv` wrapper → ADR); typed endpoint from an R function with generated OpenAPI, local-first. *Acceptance:* an audit analysis served over HTTP with correct schema; sanity load test.

### Phase 8 — Windows & CUDA

**WP13:** WSL2 CUDA build + harness B on GPU first; then native Windows build (Rtools); r-universe Windows binaries. *Acceptance:* harness B green on CUDA (WSL2); binary `install.packages` works on Windows.

### Phase 9 — CRAN, docs & API freeze

**WP15 — CRAN prep:** vendored crates per CRAN Rust policy; WRE compliance; submission. *Acceptance:* accepted (or blockers documented; r-universe continues).
**WP16 — Docs site + freeze:** full pkgdown from runnable examples; **AI-readable docs bundle** (`llms.txt` + self-contained executable examples per export — the "AI-native documentation" goal); semver policy; `llm_*` declared stable. *Acceptance:* 30-day green CI window → **v1.0**.

> **= `SOLO-PHASE-PLAN.md` Phase 1 exit checklist.**

### Phase 10 — MLX backend
**Goal:** second Apple-native inference engine via `mlx-c`, behind the unchanged R API (backend selection in `llm()`). **Scope:** generation + embeddings first; traces if MLX exposes comparable capture points, else documented as llama.cpp-only. Harness B extended with cross-engine agreement tests. **Exit:** same script, two engines, agreeing numbers; Metal-llama.cpp vs MLX benchmark table.

### Phase 11 — Multimodal models *(pulled forward → v0.2.0, per D-023 — unlocks radiology images)*
**Goal:** vision-language GGUFs under the same API. The vendored engine was pruned of the entire multimodal subsystem, so this **re-vendors and builds a second native library** (`libmtmd`/`clip`). **Scope (T1+T2, ~5–7 weeks / 3–4 WPs):** re-vendor + build the vision library (+ the pruned `common/`/`stb_image`); image-preprocess + vision-encode FFI (image parsing = untrusted input → security-auditor gate); the interleaved `batch.embd` decode path (n_batch chokepoint honored); `llm(projector=)` + `llm_generate(images=)` (T1) + `llm_embed(images=)` (T2) per approved API-GRAMMAR entries (reserved at API-GRAMMAR:156); a new vision golden category in harness B. License-clean default = **Qwen-VL (Apache-2.0**; decoders already vendored), MedGemma/Gemma 4 E4B the quality option. **T3 — interpretability of the vision tower itself (trace/steer/ablate the vision encoder) is a SEPARATE later research phase** (reuses none of the tap/intervention machinery; a non-causal SigLIP encoder breaks the D-018 residual-decomposition golden — the same open problem as Phase-18 encoder interpretability). **Exit:** a VLM answering questions about an image locally on the Mac; **`v0.2.0` tagged**.

### Phase 12 — Fine-tuning
**Goal:** `llm_finetune()` — LoRA/QLoRA on 1–8B models, base-R formula-flavored interface; adapters loadable in `llm()`. **Scope:** backend ADR first (candle vs libtorch/R-torch). **Exit:** documented end-to-end fine-tune of a small model on founder hardware, reproducible, with before/after evals.

### Phase 13 — Alignment & RL *(new — the RL slice of the vision, at honest local scale)*
**Goal:** preference optimization for small models. **Scope:** DPO/ORPO-class training on top of the Phase 12 backend; reward/eval loops in R; consistent formula-flavored interface. Datacenter PPO/RLHF explicitly out (header list). **Exit:** documented preference-tuning run of a 1–3B model with before/after evals.

### Phase 14 — Topics & SAE analysis *(where topic modelling and interpretability merge)*
**Goal:** productize the analysis layers, and close the loop the founding vision asked for — interpretability *inside* topic modelling. **Scope:** `rebirth.topics` satellite (Demo-B pipeline as one function + options); pretrained sparse-autoencoder application to traces (`llm_trace() |> sae_features()`) using public SAE releases; **topic × interpretability integration** — the same local model that embeds documents for clustering also *explains* the clusters, so a topic can be characterized not only by its label (`llm_generate`) but by the internal concepts/SAE features that drive its documents (`llm_trace`/`llm_probe`). **Exit:** topics package on r-universe; SAE-features demo reproducing a known finding on a public SAE; a topic map whose clusters are annotated with the interpretable features that distinguish them.
> **Note:** the *basic* integration (embed + label with one model, probe why documents group) is already possible from Phases 2–4; Phase 14 productizes and deepens it with SAE features.

### Phase 15 — Model export & interop *(new — "write in R, deploy anywhere")*
**Goal:** what leaves R runs anywhere. **Scope:** ONNX export for classical R models (lm/glm + tree ensembles; exact coverage by ADR); LoRA adapter merge/export (GGUF/safetensors); model-card generation. **Exit:** an R-trained classical model served from a non-R runtime via ONNX; an adapter exported, reloaded, verified.

### Phase 16 — Real-time data streams *(new — general tidy-streaming, beyond tokens)*
**Goal:** the founding document's "infinite data.frame" on live sources. **Scope:** stream sources as connections (file-tail, websocket, Arrow IPC stream; each new protocol = its own ADR); windowed verbs (`summarise_window()`-style) built on the Phase 5 async core; backpressure + spill discipline from Phase 2 reused. **Exit:** live demo — windowed statistics + threshold alerts on a real stream while the console stays interactive.

### Phase 17 — Fast data layer
**Goal:** the columnar performance story. **Scope:** Arrow-native verbs graduate from behind the flag; `reb_compile()` productization (if Phase 7 ADR said go); public reproducible benchmark suite vs current Python stacks (honest baselines: polars/duckdb, not strawmen). **Exit:** benchmarks published; verbs documented. *(Solo-feasible; a second contributor halves the calendar.)*

### Phase 18 — Science verticals: `rebirth.bio` *(the biology promise — a deliberate white-space bet)*

**The white space (researched 2026-07-06).** R's structural-bioinformatics leader, `bio3d`, is excellent at *classical* analysis (structure superposition, PCA, dynamic correlation networks) but has no path to protein *language models* or to the geometric-deep-learning-style graph featurization that now dominates the field. Python owns that ground: `graphein` builds residue/atomic graphs wired to PyG/DGL, and pre-trained protein LMs (ESM-2 class) are the frontier — increasingly fused into geometric nets. R's only bridge to protein LMs today (`immLynx`, Bioconductor 3.23) *shells out to Python/HuggingFace*; there is no native engine. That is the gap `rebirth` is uniquely built to close, because a protein LM is a transformer encoder — the exact machinery `llm_embed`/`llm_trace`/`llm_logits`/`llm_probe` already provide.

**Goal:** make R the best place to *interrogate* protein/DNA language models — not just run them, but open them up with statistics. The differentiator is not "embeddings in R" (that is mere parity); it is **tidy mechanistic interpretability of biological sequence models**, which does not yet exist well anywhere.

**Scope (`rebirth.bio` satellite):**
1. **Native protein/DNA LM inference** — load ESM-2-class / DNABERT-class encoder GGUFs through the existing engine; per-residue and pooled embeddings; amino-acid/genomic tokenization helpers. *(Arch-support ADR first: ESM-2 is BERT/RoBERTa-style; stock `llama.cpp` computes BERT-class embeddings but ESM's architecture mapping in `convert_hf_to_gguf.py` is not first-class — resolve via a conversion patch or a minimal vendored arch patch, which is exactly what a patchable vendored engine exists for. Feasible; scoped in the ADR.)*
2. **The anatomy lab, for proteins** — `llm_trace` + `llm_probe` to localize *which layer encodes which biophysical property* (secondary structure, solvent accessibility, catalytic/binding sites, evolutionary conservation), probed against structural annotations with `glmnet` and honest confidence intervals. This is Demo A applied to biology; it is essentially unpublished as a reproducible tidy workflow.
3. **Residue-graph analysis, native** — build contact/interaction graphs (the `graphein` value proposition) in R with per-residue LM embeddings/activations as node features, feeding `igraph`/`tidygraph` and R's statistical models. Bridges LM internals to Bioconductor's mature sequence/annotation/structure stack (`Biostrings`, `GenomicRanges`, `bio3d`).
4. **Zero-shot variant effect** — mutation scanning from pLM pseudo-log-likelihoods via `llm_logits` at masked positions (ESM's flagship capability). R cannot do this natively today.

**Why R goes *stronger*, not merely even:** the downstream statistics the protein-ML world routinely under-does are R's home turf — proper CIs on decodability, mixed-effects models across protein families, multiple-testing control, phylogenetic comparative methods, and outcome/econometric models (a natural fit for the founder's health-economics lens) — layered on Bioconductor's annotation infrastructure, which Python has no equal to.

**Exit:** `rebirth.bio` on r-universe; a reproducible demo that (a) localizes secondary-structure decodability by layer in an ESM-2 model and (b) runs a zero-shot variant-effect scan on a small protein — both on the founder's Mac, offline.

**Early proof-of-concept (optional, needs no reorder):** capabilities 1–2 ride entirely on machinery that exists by **Phase 2–3**. A protein-LM mini-demo ("Demo C") can therefore be shown as soon as an encoder model loads, long before the full satellite — a cheap way to make the biology promise *runnable* early without pulling the whole vertical forward. *(Solo-possible; also the ideal first-contributor on-ramp and a natural bridge to the Bioconductor community.)*

---

## 4. Team phases (deliberately last)

### Phase 19 — The distribution (rung 2) — *team recommended*
Installer bundling vanilla R + the suite + curated defaults (site profile, pinned universe snapshot); macOS notarization, Windows signing; onboarding polish. Solo-possible technically; the multi-OS **support burden** makes it a team phase in practice. *Trigger:* sustained inbound "how do I install all this?" demand.

### Phase 20 — Community & governance — *team by definition*
CONTRIBUTING + review process; issue triage; JOSS paper (synergistic with the thesis); conference talk (useR!/posit::conf); R Consortium ISC grant; maintainer succession (bus-factor > 1 is the point). *Trigger:* first external PRs.

### Phase 21 — The fork (rung 3) — *team required*
Playbook archived in `DECISIONS.md` (plan v0.1): fork base pinning, patch-first rule, `PATCHES.md`, upstream `make check` invariant. Scope: speculative JIT, real surface syntax (type annotations, `async`/`await`), base defaults. The permanent upstream-merge tax is why this is last and team-gated. *Trigger criteria (all three):* ≥ 3 sustained external contributors; adoption signal (downloads/citations/labs); a funding source for maintenance.

---

## 5. Prompting guide for the coding model

### 5.1 Session Preamble (paste at every session start; lives in `AGENTS.md`)

```text
You are the implementation engineer for R-ebirth, an R package (`rebirth`) with a
Rust native core that embeds a patched llama.cpp to expose local LLMs — loading,
generation, embeddings, activation tracing, steering, ablation — as base-R-idiom
functions returning plain data.frames and matrices.

Before writing any code, read these repo files and treat them as binding:
  1. SOLO-PHASE-PLAN.md   (decisions; §2 = API grammar rules)
  2. ROADMAP.md           (current phase + work package = your task)
  3. API-GRAMMAR.md       (approved signatures; do not invent or alter APIs)
  4. DECISIONS.md         (settled decisions; do not relitigate)

Hard rules:
- Everything in English (identifiers, comments, docs, commit messages).
- Base-R idiom: S3 classes and generics, data.frame/matrix returns, native |>,
  llm_* prefix. No tidyverse dependencies in the package.
- Do NOT add any R or Rust dependency without asking; a DECISIONS.md entry is
  required first.
- Do NOT export any function that is not in API-GRAMMAR.md.
- Errors reach R as classed conditions with actionable messages; a Rust panic
  reaching the R console is a bug.
- Numerical features require goldens (tests/llm-golden/) in the same PR.
- Write tests first where practical (testthat for R, cargo test for Rust).
- Work in small steps; after each step, state what changed and how you verified it.
- Definition of done: all tests pass locally AND the work-package acceptance
  criteria in ROADMAP.md are met. Do not claim done otherwise.

Current constraints:
- Primary target: macOS arm64 (Metal), R 4.6.1, 16 GB unified memory —
  activation capture must respect filters and the disk-spill path.
- CI models are tiny (synthetic in-repo + Qwen2.5-0.5B); never require a large
  download in tests.
```

### 5.2 Work-package prompt pattern

```text
TASK: Implement <WP-ID — name> as specified in ROADMAP.md §3, Phase <n>.

CONTEXT
- Current repo state: <one line>.
- Relevant files: <paths>.
- Approved API entries for this WP (from API-GRAMMAR.md): <signatures>.

SCOPE
- In scope: <bullets from the WP>.
- Explicitly out of scope: <WP exclusions + plan §7 non-goals>.

STEPS (suggested order)
1. <step>
2. <step>

ACCEPTANCE (all must pass before claiming done)
- <copy the WP acceptance list verbatim>

FORBIDDEN
- New dependencies without approval; API changes; touching vendor/ outside the
  marked patch points; weakening or skipping existing tests.
```

### 5.3 Prompt library — ready to paste (Phases 0–3)

One prompt per WP, pre-filled from the §5.2 pattern. Usage: paste §5.1, then the prompt for the current WP. Each prompt's CONTEXT states the *expected* repo state — verify it matches before starting. **Policy for later phases:** prompts for Phase 4 onward are produced by the `architect` agent when a phase becomes current, using the §5.2 pattern.

#### WP0 — Repository bootstrap

```text
TASK: Implement WP0 — Repository bootstrap, per ROADMAP.md §3, Phase 0.

CONTEXT
- Expected repo state: planning documents only (no code, no git yet).
- Read first: CLAUDE.md; SOLO-PHASE-PLAN.md §2+§4; ROADMAP.md §0 + §3 (WP0);
  ARCHITECTURE.md §2 + §9.

SCOPE
- In scope:
  1. git init; first commit = the planning documents unchanged.
  2. Layout per SOLO-PHASE-PLAN.md §4: rebirth/ (R package scaffolded with
     rextendr::use_extendr()), rust/ workspace with rebirth-ffi and
     rebirth-llm crates (empty but compiling), vendor/ (placeholder README),
     tests/llm-golden/, tests/demos/, docs/.
  3. LICENSE (dual MIT OR Apache-2.0), NOTICE (llama.cpp MIT — pinned in WP1),
     TRADEMARK.md (Rust/Firefox model: modified redistributions must rename).
  4. GitHub Actions workflows: R CMD check on macos-15 (arm64) + ubuntu-24.04;
     cargo test + clippy + rustfmt --check. Written now, green on first push.
  5. rust-toolchain.toml (pin stable), Cargo.lock committed, .gitignore
     (R + Rust + macOS), NEWS.md ("0.0.0.9000 — repository bootstrap").
- Out of scope: vendoring llama.cpp (WP1), any llm_* function, any model
  download, README beyond an honest stub of what exists today.

ACCEPTANCE
- Clean `R CMD check` (0 errors, 0 warnings) on the stub package, locally.
- `cargo build` and `cargo test` succeed for the workspace.
- Workflow files are valid and download no models.
- README stub states what exists and what does not.
- Planning documents and DECISIONS.md untouched (founder territory).

FORBIDDEN
- Dependencies beyond the extendr/rextendr toolchain, testthat, roxygen2.
- Any exported function (the API-GRAMMAR gate applies from the first commit).
```

#### WP1 — Vendored engine + model loading

```text
TASK: Implement WP1 — Vendored engine + model loading, per ROADMAP.md §3, Phase 0.

CONTEXT
- Expected repo state: WP0 merged (skeleton, CI green on the stub package).
- Read first: ARCHITECTURE.md §2, §3, §8, §9.
- Approved API (API-GRAMMAR.md §3): llm(path, context_length = 4096,
  gpu_layers = NULL, backend = c("auto","metal","cuda","cpu"), mmap = TRUE);
  print.llm; summary.llm; close.llm.

STEPS
1. Vendor llama.cpp at a pinned release tag; record tag + SHA256 in
   vendor/README. No source modifications (taps are WP4).
2. Static-library build from rebirth/src/Makevars: Metal on macOS arm64,
   CPU elsewhere; CUDA feature-flagged off until Phase 8.
3. rebirth-llm: model/context lifecycle over the C API (safe Rust, no R types).
4. rebirth-ffi: every entry point wrapped in catch_unwind; RebirthError ->
   classed R conditions (rebirth_error_model_load, rebirth_error_backend,
   rebirth_error_closed, rebirth_error_internal).
5. R layer: llm() validation; S3 object with the metadata slots of
   API-GRAMMAR §2; print/summary; close() + GC finalizer (two deallocation
   paths, ARCHITECTURE §3).

ACCEPTANCE
- Loads Qwen2.5-0.5B-Instruct Q8_0 and MedGemma-1.5-4B Q4 on the Mac
  (local paths supplied by the founder; llm_download arrives in WP8).
- summary(m) reports architecture, parameters, quantization, layers,
  hidden_size, context_length, backend — verified against the model cards.
- 100x load/unload loop: flat RSS.
- Missing file, corrupt file, unavailable backend: classed conditions with
  actionable messages; never a crash.
- R CMD check clean; cargo test green; CI green on both platforms.

FORBIDDEN
- Any llama.cpp source patch; any generation/tokenization API (WP2);
  new dependencies without an approved DECISIONS.md entry.
```

#### WP2 — Tokenization + generation

```text
TASK: Implement WP2 — Tokenization + generation, per ROADMAP.md §3, Phase 1.

CONTEXT
- Expected repo state: WP1 merged (llm() loads models; conditions work).
- Approved API (API-GRAMMAR.md §3): llm_tokens(m, x, decode = FALSE);
  llm_generate(m, prompt, max_tokens = 256, temperature = 0.8, top_p = 0.95,
               seed = NULL, chat = TRUE, stop = NULL).

SCOPE
- In: encode (named integer vector per prompt; list when length(x) > 1) and
  decode (integer ids -> single string); UTF-8 correctness with
  Italian-language test strings; vectorized generation with names preserved;
  seed contract (seed drawn if NULL, always returned via attr(result,"seed"));
  Gemma + Qwen chat templates; stop sequences;
  rebirth_error_context_overflow with overflow size in the message.
- Out: streaming and async (Phase 5), on_token callbacks (Phase 6),
  llm_logits (its own entry, Phase 2).

ACCEPTANCE
- Same seed + params => identical output across runs and R sessions.
- Greedy decoding matches unpatched reference llama.cpp token-for-token on
  the synthetic model and on Qwen2.5-0.5B (goldens via WP6a).
- Chat-template output matches the reference for both model families.
- R CMD check clean; cargo test green.

FORBIDDEN
- Sampling on the GPU (determinism contract: sampler runs on CPU from logits,
  ARCHITECTURE §7); new dependencies.
```

#### WP3 — Embeddings

```text
TASK: Implement WP3 — Embeddings, per ROADMAP.md §3, Phase 1.

CONTEXT
- Expected repo state: WP2 merged.
- Approved API (API-GRAMMAR.md §3): llm_embed(m, x,
  pooling = c("mean","last","model"), normalize = TRUE).

SCOPE
- In: batched embedding; base matrix return (rows = inputs, rownames =
  names(x) else seq_along as character); pooling options incl. the model's
  own pooling when the GGUF defines one; dedicated embedding GGUFs supported;
  rebirth_error_embed.
- Out: image embeddings (Phase 11), similarity utilities (user territory).

ACCEPTANCE
- Dimensions match the model card for both CI models.
- Semantic-similarity fixture: related sentence pairs rank above unrelated
  ones (fixed committed fixture, not cherry-picked).
- Golden vs reference where the backend exposes one.
- R CMD check clean; cargo test green.

FORBIDDEN
- Silent normalization changes; new dependencies.
```

#### WP6a — Correctness harness, first slice (parallel with WP2–WP3)

```text
TASK: Implement WP6a — Harness B, first slice, per ROADMAP.md §3, Phase 1.

CONTEXT
- Runs in parallel with WP2. Read: ARCHITECTURE.md §11 and the golden-update
  skill (.claude/skills/golden-update/SKILL.md) before touching anything.

SCOPE
- In: tests/llm-golden/ structure; pinned Python venv (lockfile committed:
  torch/transformers/numpy/gguf versions) + fixture scripts generating logit
  goldens from the UNPATCHED reference llama.cpp at the vendored tag; the
  synthetic 2-layer seeded GGUF builder (script + committed binary, <= 2 MB,
  tiny vocab, weights recomputable in numpy); CI wiring: exact synthetic
  tests per commit.
- Out: activation goldens and nightly 0.5B suite (WP6b), mutation test (WP6b).

ACCEPTANCE
- WP2's generation paths are covered by logit goldens running in CI.
- Goldens regenerable from scripts alone; procedure documented.
- The synthetic model's logits verified independently (numpy recomputation).

FORBIDDEN
- Hand-edited goldens; adding the Python venv as a package dependency
  (test tooling only); product-code changes.
```

#### WP4 — Activation taps + llm_trace()

```text
TASK: Implement WP4 — Activation taps + llm_trace(), per ROADMAP.md §3, Phase 2.

CONTEXT
- Expected repo state: Phase 1 complete (generation + embeddings green with
  goldens).
- Read first: ARCHITECTURE.md §5 (tap strategy), §6 (spill), §4 (indexing);
  API-GRAMMAR.md §2 (rebirth_trace schema) + §4.
- Approved API: llm_trace(m, prompts, layers = NULL, positions = "last",
  components = "residual", spill = TRUE, spill_dir = NULL);
  as.matrix.rebirth_trace(x, layer, component = "residual");
  print.rebirth_trace; summary.rebirth_trace.

STEPS
1. DAY-1 SPIKE (mandatory, before any implementation): verify Strategy A at
   the vendored tag — observe per-layer tensors via llama.cpp's eval
   callback (cb_eval, the llama-imatrix mechanism); map tensor names to
   residual/attn_out/mlp_out; establish whether the callback permits tensor
   mutation (decides WP5 ablation). Write findings as a PROPOSED ADR in
   DECISIONS.md and STOP for founder approval.
2. Capture-spec plumbing: R-side validation -> Rust spec; 1-based -> 0-based
   conversion only in rebirth-ffi (property tests).
3. The tap: callback matches the spec, copies matching tensors to host
   buffers; bounded channel -> sink thread; zero overhead when off (guarded).
4. rebirth_trace assembly: exact schema and column order of API-GRAMMAR §2;
   print/summary/as.matrix methods.
5. Spill: Arrow IPC writer (Rust) + nanoarrow lazy reader (R); session spill
   dir under R_user_dir with cleanup; predictive OOM estimate ->
   rebirth_error_oom carrying estimate_bytes + filter suggestions; budget =
   min(2 GB, 20% RAM), option rebirth.trace_budget.
6. Activation goldens wired into harness B (coordinate with WP6b).

ACCEPTANCE
- Synthetic-model activations match the independent numpy oracle exactly
  (ATOL 1e-2, per-component and per-position).
- CI-model activations vs HF fp32 validate tap semantics at a documented
  scale-robust tolerance (per-layer Spearman / per-row cosine >= ~0.94),
  anchored by the exact residual-decomposition identity + top-k logit
  agreement (D-018; >= 0.999/layer vs an independent HF reference is not
  achievable and is not asserted).
- A deliberately full trace of the 4B model on the 16 GB Mac spills to disk
  and completes; the session survives.
- Tap-off generation overhead < 2% (benchmark script committed).
- R CMD check clean; cargo test green.

FORBIDDEN
- Any implementation before the spike ADR is approved; unbounded buffering;
  vendored patches beyond what the approved ADR allows; hand-edited goldens.
```

#### WP5 — Interventions: llm_steer() + llm_ablate()

```text
TASK: Implement WP5 — Interventions, per ROADMAP.md §3, Phase 2.

CONTEXT
- Expected repo state: WP4 merged; the WP4 spike ADR (approved) states the
  ablation mechanism. Steering uses llama.cpp's native control-vector API.
- Approved API: llm_steer(m, layer, direction, coef = 1, positions = "all");
  llm_ablate(m, layer, neurons, value = 0, component = "residual").

SCOPE
- In: new-handle semantics (Arc clone + intervention list; the original
  handle is NEVER mutated — ARCHITECTURE §3); steering via control vectors
  (stacked steers = summed per-layer vectors, computed on our side);
  ablation per the spike ADR; print.llm shows active interventions;
  rebirth_error_intervention on dimension/layer validation.
- Out: attention-head ablation (stretch — only if the ADR made it cheap);
  weight editing of any kind (activations only, permanently).

ACCEPTANCE
- Steering along a sentiment direction measurably shifts a valence score on
  held-out prompts (statistical fixture, CI model, committed prompt sets).
- Ablating matched RANDOM neurons ~ null effect vs targeted ablation
  (the honesty fixture).
- Using the original handle after creating steered/ablated ones reproduces
  original outputs bit-for-bit.
- R CMD check clean; cargo test green.

FORBIDDEN
- In-place mutation of any handle; weight modification; new dependencies.
```

#### WP6b — Harness B complete

```text
TASK: Implement WP6b — Harness B completion, per ROADMAP.md §3, Phase 2.

CONTEXT
- Expected repo state: WP4 merged (WP5 merged or in final review).

SCOPE
- In: full activation-golden wiring; nightly 0.5B tolerance suite; the
  mutation test (in a scratch branch, inject an off-by-one layer index — the
  harness MUST fail loudly; record the run); long-session leak test
  (1,000 trace/generate cycles, flat RSS) in nightly CI.
- Out: demo wiring (WP7).

ACCEPTANCE
- Mutation test demonstrably fails (link the recorded run in the PR).
- Golden regeneration is script-only and documented (golden-update skill).
- Nightly jobs green three consecutive nights before closing the WP.

FORBIDDEN
- Weakening tolerances to pass; hand-edited goldens.
```

#### WP7 — The two demos as acceptance tests

```text
TASK: Implement WP7 — Demos as acceptance tests, per ROADMAP.md §3, Phase 3.

CONTEXT
- Expected repo state: Phase 2 complete (trace/steer/ablate validated).
- Read: SOLO-PHASE-PLAN.md §8 (the demo definitions are acceptance criteria).

SCOPE
- In: tests/demos/demo-A-anatomy-lab.R — sentiment contrast set (fixed,
  committed) -> llm_trace -> prcomp -> per-layer glmnet probes -> AUC+CI
  plot -> llm_steer verification on held-out prompts.
  tests/demos/demo-B-topics.R — public abstracts -> llm_embed -> uwot::umap
  + dbscan::hdbscan -> cluster naming via llm_generate -> labeled map.
  Demo B data: prepared public-abstracts sample (<= 5 MB) in inst/extdata
  + a fetch script for the full corpus. Draft Quarto vignettes for both.
  Wire demo A into nightly CI on the CI model with relaxed thresholds.
  OPTIONAL STRETCH — tests/demos/demo-C-bio-anatomy.R (per D-010): load any
  protein/DNA-sequence ENCODER that already converts to GGUF and loads through
  the engine (BERT-class; do NOT block on ESM-2 arch support — that is the
  Phase-18 ADR) -> llm_embed/llm_trace -> a per-layer glmnet probe localizing a
  residue-level property (e.g. secondary structure) -> the Demo-A money-plot on
  biology. Ship it only if an encoder loads cleanly; it does NOT gate Phase 3.
- Out: README/pkgdown polish (WP8); ESM-2 arch support and rebirth.bio proper
  (Phase 18); anything that would delay v0.1.0.

ACCEPTANCE
- Demos A and B each run end-to-end on the Mac mini from RStudio in < 10
  minutes (Demo C is optional per D-010 and does not gate this WP).
- Pinned seeds -> identical outputs across runs (probe AUCs, cluster labels).
- Demo A nightly green in CI.

FORBIDDEN
- Cherry-picked prompts (committed fixed sets only); dependencies beyond
  ggplot2, glmnet, uwot, dbscan, pROC for the demo scripts.
```

#### WP8 — Docs + release v0.1.0

```text
TASK: Implement WP8 — Docs + release v0.1.0, per ROADMAP.md §3, Phase 3.

CONTEXT
- Expected repo state: WP7 merged. The founder has created the GitHub remote
  and the r-universe organization.
- Read: the release skill (.claude/skills/release/SKILL.md) and
  ARCHITECTURE.md §12 (model registry).

SCOPE
- In: roxygen docs with runnable examples for every export (executed in CI);
  README quickstart with an honest scope statement; llm_download(model,
  dir = NULL, quiet = FALSE) + inst/models.csv registry (HTTPS only, SHA256
  fail-closed, R_user_dir cache, gated-model notes for MedGemma); pkgdown
  site; NEWS.md; then follow the release skill to tag v0.1.0.
- Out: CRAN submission (Phase 9), AI-readable docs bundle (Phase 9).

ACCEPTANCE
- install.packages("rebirth", repos = <r-universe URL>) works on a clean
  R 4.6.1 (macOS binary at minimum).
- A stranger can run Demo B from the README alone.
- R CMD check --as-cran clean on the built tarball.
- Every export documented; every example executes in CI.

FORBIDDEN
- Documenting unimplemented behavior; registry entries without verified
  SHA256; marketing claims that violate CLAUDE.md's honesty limits.
```

### 5.4 Founder review checklist (before every commit)
- [ ] `devtools::test()` + `cargo test` pass locally; `R CMD check` clean.
- [ ] No new dependencies (`DESCRIPTION`, `Cargo.toml` diff inspected).
- [ ] Exports match `API-GRAMMAR.md` exactly (names, args, defaults).
- [ ] Every new export has roxygen docs with a runnable example.
- [ ] Numerical changes ship with goldens; regeneration has a documented reason.
- [ ] Error paths tested (classed condition, not a crash).
- [ ] `NEWS.md` updated; commit message English and specific.

### 5.5 Anti-patterns to reject on sight
API invention beyond the grammar file; "temporary" dependencies; weakened/skipped tests; `unwrap()` in boundary Rust; large diffs mixing concerns; non-English identifiers; "should work" without an executed test.

---

## 6. Risk register (top 10)

| # | Risk | L×I | Mitigation |
|---|------|-----|------------|
| 1 | llama.cpp tap-patch breaks on upstream bumps | M×H | pinned tag; quarterly bump as its own mini-WP; minimal documented patch points |
| 2 | Quantization gap vs HF goldens | H×M | dual-reference (exact vs unpatched llama.cpp on same GGUF; tolerance + rank-correlation vs HF fp32; synthetic model exact) |
| 3 | 16 GB OOM during traces | M×H | capture filters + spill are acceptance criteria (Phase 2), not options |
| 4 | extendr/CRAN friction | M×M | r-universe primary until Phase 9; savvy fallback (ADR if needed) |
| 5 | MedGemma 1.5 GGUF/arch support gap | M×M | quantize locally; fall back to MedGemma 1.0 4B GGUF; thesis text-only |
| 6 | Coding-model quality variance | H×M | harness B + review checklist as backstop; small WPs; executable acceptance |
| 7 | Scope creep (solo founder, now 22 phases of temptation) | H×H | phases are strictly ordered; one WP in flight; ideas → `DECISIONS.md` backlog, not code |
| 8 | Thesis calendar collides with phase order | L×M | thesis parked until assignment (≈ Q1–Q2 2027); by then the software runs ahead of its needs; `THESIS-PLAN.md` ready to resume |
| 9 | MIMIC-CXR access delays | M×L | OpenI is primary; MIMIC is optional upgrade |
| 10 | Founder burnout | M×H | WPs ≤ 2 weeks; every phase ends shippable (natural pause points); monthly review |

---

## 7. Open inputs from the founder

1. **Thesis inputs — parked** until the thesis is assigned (≈ Q1–Q2 2027); `THESIS-PLAN.md` resumes then.
2. **Hours per week** → converts working weeks into calendar.
3. **GitHub handle/org** for repo + r-universe.
4. **HF account** with MedGemma terms accepted (needed by Phase 0/WP1).
5. Repo visibility: public from day 1 vs public at `v0.1.0` (recommendation: public at first tag).
6. Approval of this roadmap → next artifact: **`API-GRAMMAR.md`** (Phases 0–2 prompts depend on it), then `ARCHITECTURE.md` (FFI/tap/spill internals).
