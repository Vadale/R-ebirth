# R-ebirth — Solo Phase Plan

**Document 1 of 3** — operational decisions for the solo-development period (Phase 0 through end of Phase 1).
Companion documents: `ARCHITECTURE.md` (document 2 — package internals and native boundary) and `API-GRAMMAR.md` (document 3 — final function signatures and naming rules).
Operational companion: the work-package plans under `docs/` — toolchain, sequencing, and the thesis case study (WP-T). This plan states *decisions*; the roadmap states *execution*.

- **Status:** focused product scope approved under D-043; earlier decisions remain historical
- **Date:** 2026-10-05 (product focus revision; original plan 2026-07-03)
- **Owner:** Alessandro (founder) + Claude (AI engineering)
- **Scope:** a maintainable R package for reproducible observation, intervention and evaluation of local language models.

**Execution amendment (2026-09-27, D-028):** the next increment is specified in
[Structured output, statistical research and practical deployment](docs/structured-production-plan.md).
Start with the extraction/output contract (S0), then native constraints, an
evaluated demo and reproducible batch operation, followed by statistical probes
and a bounded service template. Historical phase numbers below are preserved;
the amendment explicitly selects the near-term order. It adds no approved
function signature or dependency and does not mark a capability delivered.

**Assistant companion amendment (2026-10-01, D-036):** an external statistical
skill reuses the R ecosystem and remains outside relm core. General statistical
requests default to R while explicit user language choices prevail. After WP9
and WP10, I1 validates one actual external-assistant workflow and packages the
integration; see [the companion plan](docs/external-assistants-plan.md). This
adds no approved relm API or dependency.

**Current product amendment (2026-10-05, D-043):** focus the product on the
model-research workflow already being built. Biology/DNA is excluded; existing
topic modelling remains an application, without a planned satellite package.
Other historical expansions are options requiring explicit reactivation, not
work to complete automatically after v1.0. D-043 supersedes that part of the old
three-rung strategy while preserving all delivered capabilities and contracts.

---

## 0. Product objective and delivery boundary

**Make local language models inspectable and experimentally controllable from R,
with reproducible statistical evaluation and understandable visual results.**

The primary workflow is **load → observe → compare → intervene → evaluate →
export**. It runs on stock R and returns ordinary R data structures, with
explicit model support, numerical provenance, bounded memory/spill and classed
failures. Captured associations are not automatically causal explanations;
interventions require controlled comparisons, and no safety guarantee is implied.

Maintain existing generation/structured output, embeddings, probes, traces,
steering/ablation, async/streaming/live observation, supported T1/T2 multimodal
work, reference applications and external-assistant integration. General
statistics and clustering reuse the R ecosystem. Topic modelling demonstrates
these building blocks; a separate `relm.topics` product is not an active goal.

The active remaining sequence is **F6c graphics → F6d reproducible directions →
F6e projection steering → Phase 7 consolidation/usability/external validation →
hardware-gated Phase 8 Windows/CUDA → Phase 9 CRAN/docs/API stability**.
Documentation and compatibility-preserving simplification also accompany every
increment. Product progress is measured by a researcher completing a reliable
experiment, not by the number of APIs, backends, phases or graphical panels.

Biology/protein/DNA specialization and the optional biological Demo C are outside
this product. MLX, fine-tuning/RL, SAE productization, general compiler/type
systems, generic serving/OpenAPI frameworks, model export, general data engines,
a bundled distribution and a fork are historical options. A concrete user need,
bounded design and sustainable maintenance case are required before reactivation.
Existing capabilities are not removed by a roadmap edit; actual deprecation or
removal needs compatibility analysis and a reviewable implementation proposal.

The former three-rung plan and original phase identifiers remain in DECISIONS
for provenance. They no longer define a mandatory path beyond the focused
package. No change to R's parser, evaluator, allocator, defaults or dependency
policy is part of this revision.

---

### 0.1 Practical operation of reference applications (D-028)

Reduce the work needed to move a relm analysis from an interactive R session to
a reproducible batch job, then to a modest local/small-team service. The first
delivery is a reference application with documented setup/run commands, pinned
configuration, evidence-linked tables and restartable document-level results.
The application owns persistent artifacts; core functions keep their declared
side effects and base-R return structures.

Reuse existing environment, HTTP and supervision tools through reviewed optional
dependencies. A model handle belongs to one process; workers load their own
model and process requests sequentially. Start with one inference worker on the
16 GB target. Installation, interruption recovery, memory and the declared load
envelope are acceptance tests, not implied by a lockfile or endpoint alone.

The delivered application service remains a supported example. Under D-043 it
does not imply a scheduled generic typed endpoint/compiler framework or a
bundled distribution. Generalization requires a demonstrated caller and its own
bounded proposal. New API and dependency choices retain their approval gates.

---

### 0.2 Visual analysis and directional steering sequence (D-042)

After completed F6a/F6b, deliver F6c reusable graphics/intervention comparisons,
then F6d construction/storage/held-out evaluation of steering directions, then
F6e projection steering. These extend roadmap Phase 6 and precede Phase 7;
the v1.0 boundary remains. D-043 subsequently redefines Phase 7 as consolidation
and removes unrelated expansion from the active plan. The founder approved
this scope and ordering on 2026-10-04. Detailed plan:
`docs/phase6-visual-steering-plan.md`.

Direction building first uses the existing additive residual intervention.
Projection editing is a distinct native operation, with exact tensor semantics,
independent goldens and its own concrete contract before implementation. This
amendment does not approve new public signatures, dependencies or vendor edits.
Phase 8 remains hardware-deferred and Phase 9 remains the CRAN/docs/API-freeze
stage. The existing service and graphical demos do not complete these new steps.

---

## 1. R version support (replaces v0.1 "fork base")

**Decision: develop and test primarily on R 4.6.1 "Happy Hop" (2026-06-24); declare `Depends: R (>= 4.5.0)`.**

- CI tests against **R-release and R-oldrel** on every platform; never require R-devel features.
- The v0.1 "patch-first rule" survives in spirit: new upstream minor versions (e.g. a future 4.7.0) enter the CI matrix immediately but the declared minimum moves conservatively and never to an `x.y.0`.
- Nothing of R is modified, so no interpreter divergence registry or fork maintenance is required.

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

Package namespace: **`relm`** — verified available on CRAN and unclaimed on GitHub as an R project (checked 2026-07-03). "R-ebirth" remains the umbrella project/brand name.

---

## 3. Platforms and test matrix (updated — the package makes this cheaper)

**Execution status (2026-09-27, D-027):** macOS and Linux ship today. Windows/CUDA
remains a target and is deferred pending hardware validation; the historical
phase labels below are planning targets, not evidence of delivered support.
See `docs/validation-status.md` for the checks actually running.

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
- **MLX:** roadmap Phase 10 (post-`v1.0`, still solo), via `mlx-c`, as a second backend behind the same R API.
- **Pinned reference models** unchanged: synthetic ~2-layer GGUF in-repo for exact-value unit tests; Qwen2.5-0.5B-Instruct Q8_0 (~0.5 GB, Apache-2.0) for CI integration; Qwen2.5-1.5B-Instruct Q4_K_M (~1 GB) as demo model and 7B Q4 as quality option. Llama-family supported but not demo defaults (license gating).

---

## 4. Repository, build, CI, distribution (updated)

Current layout (D-005/D-009; later-phase crates remain planned):

```
r-ebirth/
├── rebirth/                 # R package, installed as relm
│   ├── R/, man/, tests/, vignettes/
│   └── src/
│       ├── rust/            # Cargo workspace: rebirth-llm + rebirth-ffi
│       └── llama.cpp/       # pinned engine and versioned patches
├── vendor/                  # provenance pointers
├── tests/                   # numerical references, demos, vision, Valgrind
├── docs/                    # design notes and validation status
└── DECISIONS.md             # append-only decisions
```

R-side unsafe belongs to `rebirth-ffi`; minimal SAFETY-commented C-side unsafe
belongs to the R-free `rebirth-llm` engine (D-009).

- **Build:** cargo invoked from the package's `src/Makevars`; vendored crates for CRAN compliance later; the llama.cpp patch set versioned in `rebirth/src/llama.cpp/patches/`.
- **Distribution: r-universe.** macOS and Linux binaries are published, so users of those binaries do not need Rust or a native compiler. Windows binaries remain a Phase-8 target. CRAN submission remains the later documentation/API-freeze milestone; Rust vendoring is planned for that submission.
- **CI harnesses:**
  - **Harness A (new meaning):** `R CMD check --as-cran` clean on {macOS arm64, Linux x86_64/arm64, Windows} × {R-release, R-oldrel}. The v0.1 harness A (upstream `make check`) is obsolete — nothing of R is modified, so there is nothing to break by construction.
  - **Harness B (unchanged, the crown jewel):** logits vs unpatched reference llama.cpp token-by-token on pinned models (documented tolerance per quantization); activations vs precomputed PyTorch/TransformerLens goldens in `tests/llm-golden/`. Per commit on the synthetic model; nightly on the 0.5B.
  - **Nightly:** ASAN/UBSAN, valgrind on Linux, long-session leak test (1,000 trace/generate cycles, flat RSS), both demos end-to-end.
- **RStudio:** nothing to verify beyond normal package behavior — it is just a package in the user's existing R. (The v0.1 drop-in machinery is gone.)

---

## 5. Decision log and AI-assisted workflow (unchanged)

- **`DECISIONS.md`** — append-only ADR-lite (`ID / date / decision / why / alternatives rejected`). D-002 (this pivot) is its first major entry; the v0.1 fork playbook is archived there for rung 3.
- **Spec-first rule:** no exported function before its `API-GRAMMAR.md` entry is accepted by the founder.
- **Golden-first rule:** the correctness golden exists before the feature it validates is merged.

---

## 6. Licensing and naming (major update — founder guideline now fully satisfied)

**Decision: everything original is dual-licensed `MIT OR Apache-2.0`. The GPL constraint of v0.1 no longer applies.**

- The GPL inheritance in v0.1 came solely from modifying GNU R's sources. A package does not derive from R's code — it is original work using R's public API, and the R ecosystem's settled practice (CRAN hosts MIT/Apache/BSD packages routinely) supports permissive licensing. Result: **the founder's "freest possible license" guideline is now met in full** — any person, lab, startup, or corporation can use, modify, embed, and redistribute, including in proprietary products.
- `relm` (R package), `rebirth-llm`, `rebirth-kernel`, `rebirth-ffi` (Rust crates): **MIT OR Apache-2.0**.
- Vendored llama.cpp: MIT — compatible; tracked in `NOTICE`.
- **Name protection unchanged (`TRADEMARK.md`):** the code is free, the name is not. Modified redistributions must rename (Rust/Firefox model). This remains the correct instrument for "my work must not be confused with someone else's fork."
- Project self-description: *"R-ebirth — reproducible model research in R"*. A hypothetical future fork would need separate branding and licensing review. No use of the R Foundation's logo or implied endorsement.
- Rung-3 note for the future: if/when the fork happens, *that repository* inherits GPL-2 | GPL-3 — but the crates stay permissive and simply get linked in, which is exactly why the permissive-core structure is right today.

---

## 7. Current non-goals and historical options

The historical term "plan Phase 1" means roadmap Phases 4–9 ending at v1.0;
it does not mean roadmap Phase 1. The active plan no longer promises delivery
of every original phase through 21. D-043 makes these exclusions explicit:

- No biology/protein/DNA vertical, `relm.bio` or biological Demo C.
- No separate topic-modelling satellite. Keep the existing ecosystem-based
  example and improve it only for demonstrated usability/correctness needs.
- No second inference engine, fine-tuning/RL/SAE product suite, general compiler,
  type language, OpenAPI framework, model export or general data engine scheduled
  as an automatic sequel. SAE analysis can be assessed separately if it serves
  the core research workflow.
- No GNU R fork, parser/JIT/GC work, bundled R distribution or mandatory team
  expansion programme. Maintain normal project documentation and contribution
  practices without turning them into new products.
- No multi-GPU, distributed or cloud platform added by this revision.
- No CRAN submission before the scheduled readiness stage; r-universe continues
  to distribute the package. Ordinary runnable documentation is active work.
- No implicit API/dependency/vendor approval, tolerance relaxation, deletion of
  supported functionality or rewrite of accepted numerical/ownership semantics.

Historical proposals remain attributable in DECISIONS and Git history. They are
not a task queue. A new request and concrete decision are required to reactivate
one; elapsed time or completion of the previous phase is insufficient.

---

## 8. Reference demos and the D-028 application

**D-028 addition:** retain Demos A/B and add a bounded public-document extraction
application under the [near-term plan](docs/structured-production-plan.md).
It starts from verified text, produces evidence-linked data, measures errors,
and becomes the first restartable batch example. It is not the parked thesis
and does not claim causal or clinical conclusions. Demos A/B being delivered
does not imply this new application's acceptance has passed.

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
- [ ] `install.packages("relm", repos = <r-universe>)` works on stock R 4.6.1 (macOS binary at minimum)
- [ ] `R CMD check` clean on macOS arm64 + Linux (Windows may lag until Phase 1)
- [ ] `llm()`, `llm_generate()`, `llm_embed()`, `llm_trace()` (filters + spill), `llm_steer()`, `llm_ablate()` working on GGUF models (Qwen + Llama families)
- [ ] Harness B green: logits vs reference llama.cpp, activations vs PyTorch goldens
- [ ] Demo A and Demo B pass as scripted acceptance tests on the Mac mini (RStudio)
- [ ] Seeded generation reproducible run-to-run
- [ ] `DECISIONS.md` in active use

**Focused v1.0 exit (historical plan Phase 1; D-043 revision):**
- [ ] Async generation integrated with the console event loop (session never blocks; `promises`-style API)
- [ ] Token streaming and bounded live observation/coefficient updates are usable with the console event loop
- [ ] F6c reusable visual comparisons, F6d model-bound direction construction/evaluation and F6e independently verified projection steering are accepted
- [ ] Phase 7 consolidation records justified simplifications, compatibility and distinct test coverage/cost
- [ ] An external researcher completes a bounded observe/intervene/evaluate/export workflow; actual assistance and failures are recorded
- [ ] Existing application service, topic examples and companion integration remain supported without requiring new general frameworks
- [ ] Windows binaries on r-universe; CUDA green (WSL2 first, then native Windows)
- [ ] CRAN submission of `relm` (Rust vendoring policy compliant)
- [ ] Docs site generated from runnable examples; `llm_*` API declared stable
- [ ] WP-T (thesis case study) — **parked, not blocking Phase 1 exit** (thesis assignment ≈ Q1–Q2 2027; see `THESIS-PLAN.md`)
- [ ] Full CI matrix green 30 consecutive days before declaring Phase 1 closed

---

## 10. Open questions routed to the next two documents

- `ARCHITECTURE.md` (document 2): `rebirth-ffi` unsafe-boundary design; tap-patch maintenance strategy against upstream llama.cpp releases; spill file format; async integration with R's event loop. Later-rung sketches are historical options under D-043.
- `API-GRAMMAR.md` (document 3): full signatures and defaults for every `llm_*` function; trace data.frame schema (`layer`, `token_pos`, `component`, `neuron`, `value`, `prompt_id`); condition class hierarchy; print formats.
- Historical backend/training/satellite ideas are not open inputs for the active work. Reopen one only through an explicit product decision.
