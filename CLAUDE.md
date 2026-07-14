# CLAUDE.md — R-ebirth Project Guide

Entry point for any AI model working on this project. **The repository documents are the single source of truth** — if chat memory, prior conversations, or anything else disagrees with these files, the files win. This file was written so a model with zero prior context can carry the project forward.

## What this project is

**R-ebirth** makes R the best environment for scientific research on data and AI — mechanistic interpretability ("AI neuroscience"), ML including topic modelling, biology, medicine — while staying simple for researchers. It is delivered as **`relm`**: an R package with a Rust native core embedding a patched llama.cpp, exposing local LLMs (loading, generation, embeddings, **activation tracing, steering, ablation**) as base-R-idiom functions returning plain `data.frame`s and `matrix`es.

Strategy = the **three-rung ladder** (see `SOLO-PHASE-PLAN.md` §0): rung 1 = this package suite (now); rung 2 = a curated distribution; rung 3 = a fork of GNU R (JIT, new syntax) — team-gated, last. We are on **rung 1**.

**Status (2026-07-09):** **v0.1.0 SHIPPED as `relm`** (the package was renamed `rebirth` → `relm`, D-025; published on r-universe — macOS Apple Silicon + Linux binaries, `install.packages("relm", repos = c("https://vadale.r-universe.dev", getOption("repos")))`; verified installing + running on the founder's M4; tagged `v0.1.0` + GitHub release). **Phase 1 complete (3/3); Phase 2 (the anatomy lab) COMPLETE — WP4, WP5, `llm_logits()`, and WP6b (Harness B complete) all merged; the phase-end simplifier pass is merged (PR #14) and F-1's memory-safety + supply-chain gates are delivered (D-019). **Phase 3 COMPLETE — v0.1.0 shipped: WP7 demos (PR #17), WP7.5a (D-021) + WP7.5b (D-022), WP8a (`llm_download()`, PR #24), WP8b (release docs — README/pkgdown/`NEWS.md` PR #25, getting-started #26, real demo figures #28), and WP8c (rename `rebirth`→`relm` #27 under D-025; r-universe registry `Vadale/vadale.r-universe.dev`; `v0.1.0` tagged + GitHub release) all merged; vision deferred to v0.2.0/Phase 11 (D-023) — v0.1.0 ships text-only.** WP0 (bootstrap + CI), WP1 (`llm()` model loading over vendored llama.cpp b9726, Metal), WP6a (Harness B synthetic oracle), WP2 (`llm_tokens()`/`llm_generate()`), WP3 (`llm_embed()`, ADR D-011), **WP4 (`llm_trace()` — activation taps + disk spill)**, and **WP5 (`llm_steer()`/`llm_ablate()` — the intervention core)** are merged to `main`; CI green cross-platform. WP4 delivered zero-patch eval-callback observation (D-012), the `attn_out` post-projection semantics (D-014), and Arrow-IPC disk spill (D-013). **WP5** delivered steering as llama.cpp's native control vector (zero patch) and ablation as a native `(x+steer)⊙mask+add` graph op via the project's **first vendored patch** — the `build_cvec` ablation hook, under **D-015** (patch-application: commit the patched tree + the G4 post-patch-SHA gate + a reverse-apply coherence check, both wired in CI) and **D-016** (semantics: ablate-after-steer, steer-sums / ablate-union, `layer=1`-steer + intervened-handle `llm_embed`/`llm_trace` guards, arch allow-list `{llama,qwen2,gemma3}`); handles are fresh contexts on a cloned `Arc<Model>` → bit-for-bit reversible; synthetic golden ≤ 2.1e-3 vs the numpy oracle, plus mutation-proven `[MODEL]` valence + KL acceptance fixtures; passed the security-auditor (no reachable memory-safety defect), reviewer (approve), and simplifier gate. `llm_logits()` (next-token distribution as a `data.frame`) followed (PR #9), sharing generation's `n_batch`-chunked last-only prompt decode — a reviewer catch fixed a session-killing `ggml_abort` on a prompt longer than `n_batch` — and it is intervention-aware (reflects a steered/ablated handle). **Next in Phase 2: WP6b (Harness B complete: activation goldens + nightly 0.5B tolerance + mutation test) → Phase 2 closes; then Phase 3 = `v0.1.0` (WP7 demos incl. Demo B "topics without Python", WP8 release + `llm_download()` + r-universe).** `API-GRAMMAR.md` v1.0 binding (D-003, + §4 WP5 scope note); `DECISIONS.md` at **D-023** (+ rung-3 fork playbook, Appendix A). See `HANDOFF.md` for the full development handoff. Exported so far: `llm()`, `llm_tokens()`, `llm_generate()`, `llm_embed()`, `llm_trace()`, `llm_steer()`, `llm_ablate()`, `llm_logits()`, **`llm_download()`** + S3 methods. A **full-codebase audit** (2026-07-07, `docs/full-review-2026-07-07.md`) found the numerical core genuinely clean; its correctness fixes are merged (PR #10: H-2 `n_batch` decode chokepoint, M-1 trace-position dedup, M-2 spill nonce, M-4 reject-not-clamp at the FFI, an interim 256 MB trace budget, CI gaps), its recurring-error preventions are **Hard rule 8**, and **D-017** (trace budget measured on materialized bytes, superseding ARCH §5) is **accepted and implemented** (2026-07-07, PR #11): the budget is measured on materialized bytes (K=11, twin-pinned) with the FFI payload de-duped, and the default budget is restored to `min(2 GB, 20% RAM)`. The **HF-Qwen fp32 activation golden** (WP6b) then landed (PR #12) under **D-018** — harness B dual-reference acceptance: the same-implementation legs stay exact gates (synthetic numpy oracle; unpatched-llama.cpp logits), while the HF-fp32 leg is a scale-robust tap-semantics cross-check (Spearman/cosine ≥ ~0.94) anchored by the exact residual-decomposition identity (Δ = 0) + top-k logit agreement, since ≥ 0.999/layer vs an independent HF reference is not achievable (intrinsic llama.cpp-vs-PyTorch divergence, not quantization/backend) — this corrected the ROADMAP WP4/WP6a criterion. **WP6b closed** (PR #13): a model-free per-commit mutation test (locks the HF-golden non-gameability into per-commit CI, satisfying the ARCHITECTURE §4 off-by-one mutation requirement) + a separate nightly 0.5B tolerance workflow (fail-closed model pin, never gates PRs) — **Phase 2 is complete** — then the phase-end simplifier pass (PR #14) and the sccache CI compile-cache speedup (PR #15) landed, plus F-1's memory-safety + supply-chain gates (D-019). Next: **v0.2.0 = vision — UNDERWAY** (Phase 11 pulled forward, D-023; **D-026 accepted 2026-07-14**: re-vendor `libmtmd` at the same tag b9726 — no vendor bump — audio Option A, and the `projector=`/`images=`/`relm_error_image` grammar entries approved; full plan in `docs/phase11-vision-plan.md`; WP-V1 = re-vendor + build libmtmd, then WP-V2 image FFI + T1, WP-V3 T2, WP-V4 release). Post-v0.1.0 follow-ups closed: the governance-doc prose sweep (PR #29); the Intel-Mac r-universe binary (PR #30 — v0.1.0 binaries now cover macOS arm64 + **macOS Intel** + Linux; Windows = Phase 8); the Show HN is posted. F-1's deeper ASan/UBSan job remains (Deferred note). **Deferred (tracked):** **F-1 (memory-safety + supply-chain DELIVERED on branch `wp-f1-sanitizers`, D-019; ASan/UBSan + selftest-gating still open):** now wired — a nightly Valgrind memory-safety + leak CI job (`nightly-memory-safety.yaml`) exercising the intervention path (steer/ablate/trace + the OwnedContext drop, download-free on the synthetic model, baseline-ISA build so Valgrind decodes every instruction), and the `cargo audit`/`cargo deny` supply-chain gate for D-008 G4 (per-PR licenses/bans/sources in `rust.yaml`; nightly RustSec advisories in `nightly-supply-chain.yaml`; `deny.toml` pins the allow-list). CLAUDE.md's advertised "nightly sanitizers" claim is reconciled to what exists (Valgrind, not yet ASan/UBSan). **Still open in F-1:** the deeper ASan/UBSan job with the vendored llama.cpp also recompiled `-fsanitize=address,undefined` (catches the stack/global-buffer-overflow + non-memory UB Valgrind misses); gate the `rebirth_selftest_*` FFI behind a non-default `selftest` cargo feature; the `[MODEL]` 4B-spill + Qwen-tolerance + WP5 valence/KL acceptances run on the founder's Mac (Metal). **Repo visibility resolved (public).** Founder input still open: HF account with MedGemma terms (thesis-era, parked); optional non-blocking: pin a small embedding GGUF for automated non-causal embedding coverage (`docs/wp3-embed-plan.md` §9).

## Language rules (absolute — founder's standing order)

- Conversation **with the founder (Alessandro): Italian**.
- Everything **produced** — code, identifiers, comments, documentation, commit messages, file contents, PR text: **English**. No exceptions, ever.

## Read these before working (in this order)

1. `SOLO-PHASE-PLAN.md` — binding decisions; **§2 = the API grammar rules**.
2. `ROADMAP.md` — the 22 phases; the current work package (WP) is the task; §5 = prompt templates.
3. `API-GRAMMAR.md` — approved function signatures (v1.0, 2026-07-03 — **pending founder sign-off**). Nothing may be exported without an entry here.
4. `ARCHITECTURE.md` — package internals: crate layout, FFI boundary, tap strategy (eval-callback first, patch only if the WP4 spike demands it), spill, build pipeline (v1.0, 2026-07-04).
5. `DECISIONS.md` — ADR log, append-only (seeded 2026-07-04: D-001 grammar, D-002 ladder, D-003 API approval, D-004 thesis parked, + Appendix A = the rung-3 fork playbook).
6. `THESIS-PLAN.md` — the founder's master's-thesis case study. **Parked** until the thesis is assigned (≈ Q1–Q2 2027); `llm_probe` (Phase 4) is unaffected. Do not raise thesis topics until the founder does.
7. `R-vs-Python-La-Rivoluzione-Definitiva.md` — the founding vision (historical; superseded by the plans where they conflict).

## Hard rules (bind every session)

1. English everywhere in artifacts (see above).
2. Base-R idiom: S3 classes/generics, plain `data.frame`/`matrix` returns, native `|>`, `llm_*` prefix. **No tidyverse dependencies in the package** (interop comes free).
3. **Spec-first:** no exported function before its `API-GRAMMAR.md` entry is approved by the founder.
4. **Golden-first:** numerical features merge only together with their reference goldens (`tests/llm-golden/`).
5. **No new dependencies** (R or Rust) without an approved `DECISIONS.md` entry.
6. Tests pass locally before claiming "done"; CI green before merge. Report test results honestly — a failing test is reported as failing.
7. Small, reviewable diffs; one concern per commit. Errors reach R as classed conditions, never raw Rust panics.
8. **Recurring-error guards** (from the 2026-07-07 audit, `docs/full-review-2026-07-07.md` §2 — these codify mistake classes that already recurred): (a) all prompt-ingest decode goes through the single `n_batch`-chunked chokepoint — never guard a decode with only `≤ n_ctx`, and every new decode path ships an over-`n_batch` regression test; (b) the FFI boundary **rejects** an out-of-contract index/argument with a classed condition, never `.max()`-clamps it to item 0/1; (c) any memory/size budget is measured against the peak resident cost of the *materialized R object* (with a `object.size ≤ K×estimate` test), not an engine representation; (d) integrity/staleness keys are nonces or content digests, never filenames/counters/echoed filters; (e) every test states where it runs (which CI job or `[MODEL]` gate); (f) any constant/formula duplicated across R and Rust carries a twin-pin equality test; (g) at merge, grep the docs for any statement the diff falsifies and fix it in the same PR. Also settled house standards: independent-oracle + artifact-byte-checked goldens, adversarial no-op guards, fails-loud gates, a regression test for every fixed bug, incremental commits, and run `fmt`/`clippy` *after* the last edit.

## Stack

| Layer | Choice | Notes |
|---|---|---|
| R | dev target 4.6.1; `Depends: R (>= 4.5.0)` | CI on R-release + R-oldrel; never require x.y.0 or R-devel |
| Rust↔R bridge | extendr (`rextendr` scaffold) | savvy = fallback if CRAN friction (needs ADR) |
| Inference engine | vendored llama.cpp, pinned tag, patched for activation taps | Metal (macOS), CPU, CUDA (Phase 8); patch set versioned in `vendor/` |
| Spill format | Rust writes Arrow IPC; R reads via `nanoarrow` | for traces exceeding memory budget |
| Testing | `testthat` (≥3) + `cargo test`; harness B = goldens vs unpatched llama.cpp + HF fp32 | synthetic 2-layer in-repo GGUF for exact tests |
| Docs | roxygen2 (runnable examples, executed in CI) + pkgdown + Quarto vignettes | AI-readable docs bundle (`llms.txt`) at Phase 9 |
| CI | GitHub Actions: `R CMD check` (macOS arm64, Linux; Windows from Phase 8) + cargo test/clippy/fmt + per-PR cargo-deny (licenses/bans/sources); nightly Valgrind memory-safety + leak check (intervention path) + supply-chain advisories (cargo audit/deny) + 0.5B tolerance; ASan/UBSan + demos pending | |
| Distribution | r-universe (binaries all platforms) from Phase 3; CRAN at Phase 9 | |
| License | everything original: dual **MIT OR Apache-2.0**; vendored llama.cpp MIT (NOTICE) | name protected via `TRADEMARK.md` (modified redistributions must rename) |

## Hardware and pinned models (founder's machines)

- **Primary: Mac mini M4, 16 GB unified memory** (~10–11 GB free), RStudio + console. Consequence: capture filters are mandatory API on `llm_trace()`; big traces spill to disk; a full trace must never OOM the session.
- **Ollama is installed on the Mac with models already pulled.** relm never depends on Ollama (its server API exposes no activations — we embed our own engine), but Ollama's downloaded blobs ARE plain GGUF files and can be reused as local model paths during development: `ollama show <model> --modelfile` reveals the blob path under `~/.ollama/models/blobs/`. Stop the Ollama server before trace sessions — it keeps models resident and competes for the 16 GB. Pinned test/demo models still come from the checksummed registry (reproducibility).
- **Windows PC, RTX 2060 (6 GB VRAM):** CUDA via WSL2 first (Phase 8), native Windows build after.
- Local arm64 Linux VMs (UTM/lima) for smoke tests only (≤ 4 GB, never alongside a 7B model); real Linux coverage lives in CI.
- **Pinned models:** synthetic 2-layer seeded GGUF (in-repo, exact-value tests); Qwen2.5-0.5B-Instruct Q8_0 (CI integration); Qwen2.5-1.5B-Instruct Q4_K_M (demos); Qwen2.5-7B-Instruct Q4 (quality option); **MedGemma-1.5-4B-it** (thesis; HF terms must be accepted; if no community GGUF, quantize locally or fall back to MedGemma 1.0 4B). Llama-family supported but not demo defaults (license gating). All pins recorded with SHA256.

## Background knowledge (from the planning sessions; not written elsewhere)

- **Why package, not fork (D-002):** forking GNU R meant GPL inheritance, a permanent upstream-merge tax (2–3 releases/year), brutal Windows builds, and replace-your-R adoption friction. The package path removed all four (notably: licensing became fully permissive) while keeping every research capability — the heavy compute lives in the native engine either way. The fork remains as Phase 21 with its playbook archived in `DECISIONS.md`.
- **Prior-art lessons (why predecessors died — treat as engineering data):** FastR/Renjin reimplemented R and underfunded the C-API bridge → incompatible with the compiled-package ecosystem → death. pqR proved fork-and-improve works technically but died solo. Ř/rir proved a speculative JIT *inside* GNU R works — research funding ended. webR proved the codebase is malleable (R in Wasm). Lesson: compatibility is the product; that is why rung 1 runs *on stock R*.
- **Do NOT rebuild what the ecosystem already does well:** ellmer/mall/ragnar/vitals (API-based LLM work), localLLM/llamaR (plain llama.cpp bindings — relm's differentiator is taps/steering/tidy traces, not inference itself), duckplyr/data.table (fast wrangling), mirai (async workhorse — likely dependency in Phase 5, needs ADR).
- **The white space relm owns:** tidy mechanistic interpretability, local fine-tuning from R, native topic modelling, live introspection during generation, and — the biology bet (roadmap Phase 18, `relm.bio`) — **tidy mechanistic interpretability of protein/DNA language models** (ESM-2/DNABERT-class): the R answer to Python's graphein/ESM stack, where R's statistics + Bioconductor make it stronger than parity, not weaker. Today R's only protein-LM bridge (`immLynx`) shells out to Python; relm runs the encoder natively.

## Honesty limits (never claim, anywhere — code, docs, papers, README)

1. C-like speed on arbitrary untyped R code (kernels and typed paths only).
2. "Bias removed / model made safe" via ablation or steering — the framing is always *audit, investigate, quantify, localize*.
3. "Impossible in Python" — the true claim is: an order of magnitude more readable and integrated for statisticians.
4. The live guardrail (Phase 6) is a *mechanism*; detection reliability is open research, never a safety guarantee.

## Working with the founder

Alessandro: Italian data scientist, R-native, statistician mindset (not a systems engineer — explain runtime/FFI internals when they matter, don't assume them); MSc Public and Health Economics (UniMol, English-taught); the thesis (`THESIS-PLAN.md`) is parked until assigned (≈ Q1–Q2 2027) and then becomes a first-class deadline driver. He reviews **every diff** personally.

Interaction rules he has explicitly set: peer tone (no lecturing, no condescension); when something looks infeasible, analyze *why* and propose engineering paths through it — never gatekeep with "it failed before"; don't downscope his vision without asking; state a disagreement once, with evidence, then move on (he accepts clearly-argued limits — see Honesty limits — but not vague resistance). Decisions are his; preparation of decisions (ADRs, options with a recommendation) is ours.

## Agents (`.claude/agents/`)

| Agent | Use when | Notes |
|---|---|---|
| `architect` | a phase becomes current and needs its WP breakdown; any ADR-sized decision | writes plans/ADRs, no product code |
| `coder` | implementing the current WP | the workhorse; follows ROADMAP §5 prompts |
| `test-engineer` | goldens, fixtures, harness B work; before merging numerical code | adversarial mindset; owns `tests/` |
| `reviewer` | after every WP implementation, before the founder's own review | read-only; checks grammar/rules/diff quality |
| `simplifier` | **mandatory at each phase end, and after any WP adding > ~500 lines** | the maintainability & refactoring engineer — behavior-preserving refactoring (structure, indirection layers), measured hot-path optimization, dependency reduction, real-reuse helper extraction, leak/resource-hygiene fixes, clean code |
| `security-auditor` | phase boundaries touching the FFI/unsafe boundary, file parsing, downloads, or the serve module (Phases 0–2, 7, 8) | read-only + reports |
| `doc-writer` | after WP acceptance passes; before releases | roxygen/vignettes/README/NEWS; examples must run |

> **Coding model = Opus.** Run the session in Opus (`/model opus`). The agents above carry no `model:` field, so they **inherit the session model** — running on Opus means every subagent (coder, architect, reviewer…) implements with Opus. To pin a different model per agent, set `model:` in its `.claude/agents/<name>.md` frontmatter.

## Skills (`.claude/skills/`)

- `new-wp` — start a work package correctly (branch, spec check, TDD order, acceptance copy).
- `golden-update` — regenerate reference goldens safely (the only sanctioned way to touch them).
- `vendor-bump` — quarterly llama.cpp update: re-apply tap patch, re-run harness B, document.
- `release` — cut a release: check matrix, NEWS, tag, r-universe verification.

## Knowledge graph (graphify) — query it to save tokens

A persistent knowledge graph of the codebase lives at `graphify-out/` (`graph.json`, `graph.html`, `GRAPH_REPORT.md`). **Before opening many source files to answer a "how does X work" / "what calls Y" question, query the graph** — it returns the relevant nodes and their source locations without loading every file, which is the cheapest way to build context:

- `graphify query "how does generation decode the prompt"` — BFS traversal from the matched nodes.
- `graphify path "llm_generate" "llama_decode"` — how two things connect.
- `graphify explain "RebirthError"` — a plain-language description of a node.

**Keep it fresh — but refresh carefully:** the curated graph is code-only (Rust engine + Python goldens) and **deliberately excludes the vendored `rebirth/src/llama.cpp/` tree**. A bare `graphify update .` / `graphify .` on this repo re-ingests that vendored C++ and swamps our code with ~10 k noise nodes (verified 2026-07-06). Refresh via the **graphify skill** (it does the narrowing/exclusion) after new code lands, not by pointing the CLI at the repo root; if a run pollutes anyway, graphify auto-backs-up the prior graph to `graphify-out/<date>/` — restore those 5 files to recover the clean state. Enriching the graph with the R surface + planning docs is the budget-permitting task in `HANDOFF.md` §6.

## Session hygiene (before ending any session)

1. Report the true state: what passed, what failed, what is untested.
2. Any decision made → `DECISIONS.md` entry (ID, date, decision, why, alternatives rejected).
3. User-visible change → `NEWS.md`.
4. Durable project fact changed → update **this file** (keep it short; details belong in the referenced docs).

## Open inputs from the founder (as of 2026-07-06)

Code is underway (Phase 1, 2/3 done — WP0/WP1/WP6a/WP2 merged). The GitHub remote + r-universe org are needed before the `v0.1.0` release (Phase 3, WP8), not before coding continues. HF account with MedGemma terms is thesis-era (parked). Still open: repo visibility (recommendation: public at first tag); hours/week (calendar planning only). Thesis inputs parked until assignment (≈ Q1–Q2 2027).
