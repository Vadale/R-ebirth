# CLAUDE.md — R-ebirth Project Guide

Entry point for any AI model working on this project. **The repository documents are the single source of truth** — if chat memory, prior conversations, or anything else disagrees with these files, the files win. This file was written so a model with zero prior context can carry the project forward.

## What this project is

**R-ebirth** makes R the best environment for scientific research on data and AI — mechanistic interpretability ("AI neuroscience"), ML including topic modelling, biology, medicine — while staying simple for researchers. It is delivered as **`rebirth`**: an R package with a Rust native core embedding a patched llama.cpp, exposing local LLMs (loading, generation, embeddings, **activation tracing, steering, ablation**) as base-R-idiom functions returning plain `data.frame`s and `matrix`es.

Strategy = the **three-rung ladder** (see `SOLO-PHASE-PLAN.md` §0): rung 1 = this package suite (now); rung 2 = a curated distribution; rung 3 = a fork of GNU R (JIT, new syntax) — team-gated, last. We are on **rung 1**.

**Status (2026-07-04):** planning complete; `API-GRAMMAR.md` v1.0 **approved by the founder — binding** (D-003); `DECISIONS.md` seeded (D-001…D-004 + the rung-3 fork playbook). **Code not started.** WP0 can begin locally at any time; only the GitHub org/handle blocks its CI acceptance, and the HF account (MedGemma terms) is needed by WP1.

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

## Stack

| Layer | Choice | Notes |
|---|---|---|
| R | dev target 4.6.1; `Depends: R (>= 4.5.0)` | CI on R-release + R-oldrel; never require x.y.0 or R-devel |
| Rust↔R bridge | extendr (`rextendr` scaffold) | savvy = fallback if CRAN friction (needs ADR) |
| Inference engine | vendored llama.cpp, pinned tag, patched for activation taps | Metal (macOS), CPU, CUDA (Phase 8); patch set versioned in `vendor/` |
| Spill format | Rust writes Arrow IPC; R reads via `nanoarrow` | for traces exceeding memory budget |
| Testing | `testthat` (≥3) + `cargo test`; harness B = goldens vs unpatched llama.cpp + HF fp32 | synthetic 2-layer in-repo GGUF for exact tests |
| Docs | roxygen2 (runnable examples, executed in CI) + pkgdown + Quarto vignettes | AI-readable docs bundle (`llms.txt`) at Phase 9 |
| CI | GitHub Actions: `R CMD check` (macOS arm64, Linux; Windows from Phase 8) + cargo test/clippy/fmt; nightly sanitizers + leak test + demos | |
| Distribution | r-universe (binaries all platforms) from Phase 3; CRAN at Phase 9 | |
| License | everything original: dual **MIT OR Apache-2.0**; vendored llama.cpp MIT (NOTICE) | name protected via `TRADEMARK.md` (modified redistributions must rename) |

## Hardware and pinned models (founder's machines)

- **Primary: Mac mini M4, 16 GB unified memory** (~10–11 GB free), RStudio + console. Consequence: capture filters are mandatory API on `llm_trace()`; big traces spill to disk; a full trace must never OOM the session.
- **Ollama is installed on the Mac with models already pulled.** rebirth never depends on Ollama (its server API exposes no activations — we embed our own engine), but Ollama's downloaded blobs ARE plain GGUF files and can be reused as local model paths during development: `ollama show <model> --modelfile` reveals the blob path under `~/.ollama/models/blobs/`. Stop the Ollama server before trace sessions — it keeps models resident and competes for the 16 GB. Pinned test/demo models still come from the checksummed registry (reproducibility).
- **Windows PC, RTX 2060 (6 GB VRAM):** CUDA via WSL2 first (Phase 8), native Windows build after.
- Local arm64 Linux VMs (UTM/lima) for smoke tests only (≤ 4 GB, never alongside a 7B model); real Linux coverage lives in CI.
- **Pinned models:** synthetic 2-layer seeded GGUF (in-repo, exact-value tests); Qwen2.5-0.5B-Instruct Q8_0 (CI integration); Qwen2.5-1.5B-Instruct Q4_K_M (demos); Qwen2.5-7B-Instruct Q4 (quality option); **MedGemma-1.5-4B-it** (thesis; HF terms must be accepted; if no community GGUF, quantize locally or fall back to MedGemma 1.0 4B). Llama-family supported but not demo defaults (license gating). All pins recorded with SHA256.

## Background knowledge (from the planning sessions; not written elsewhere)

- **Why package, not fork (D-002):** forking GNU R meant GPL inheritance, a permanent upstream-merge tax (2–3 releases/year), brutal Windows builds, and replace-your-R adoption friction. The package path removed all four (notably: licensing became fully permissive) while keeping every research capability — the heavy compute lives in the native engine either way. The fork remains as Phase 21 with its playbook archived in `DECISIONS.md`.
- **Prior-art lessons (why predecessors died — treat as engineering data):** FastR/Renjin reimplemented R and underfunded the C-API bridge → incompatible with the compiled-package ecosystem → death. pqR proved fork-and-improve works technically but died solo. Ř/rir proved a speculative JIT *inside* GNU R works — research funding ended. webR proved the codebase is malleable (R in Wasm). Lesson: compatibility is the product; that is why rung 1 runs *on stock R*.
- **Do NOT rebuild what the ecosystem already does well:** ellmer/mall/ragnar/vitals (API-based LLM work), localLLM/llamaR (plain llama.cpp bindings — rebirth's differentiator is taps/steering/tidy traces, not inference itself), duckplyr/data.table (fast wrangling), mirai (async workhorse — likely dependency in Phase 5, needs ADR).
- **The white space rebirth owns:** tidy mechanistic interpretability, local fine-tuning from R, native topic modelling, live introspection during generation.

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
| `simplifier` | **mandatory at each phase end, and after any WP adding > ~500 lines** | behavior-preserving complexity reduction; the anti-entropy agent |
| `security-auditor` | phase boundaries touching the FFI/unsafe boundary, file parsing, downloads, or the serve module (Phases 0–2, 7, 8) | read-only + reports |
| `doc-writer` | after WP acceptance passes; before releases | roxygen/vignettes/README/NEWS; examples must run |

## Skills (`.claude/skills/`)

- `new-wp` — start a work package correctly (branch, spec check, TDD order, acceptance copy).
- `golden-update` — regenerate reference goldens safely (the only sanctioned way to touch them).
- `vendor-bump` — quarterly llama.cpp update: re-apply tap patch, re-run harness B, document.
- `release` — cut a release: check matrix, NEWS, tag, r-universe verification.

## Session hygiene (before ending any session)

1. Report the true state: what passed, what failed, what is untested.
2. Any decision made → `DECISIONS.md` entry (ID, date, decision, why, alternatives rejected).
3. User-visible change → `NEWS.md`.
4. Durable project fact changed → update **this file** (keep it short; details belong in the referenced docs).

## Open inputs from the founder (as of 2026-07-03)

GitHub handle/org (repo + r-universe — blocks WP0's CI acceptance only); HF account with MedGemma terms accepted (needed by WP1); hours/week (calendar planning only); repo visibility (recommendation: public at first tag). Thesis inputs parked until assignment (≈ Q1–Q2 2027).
