# Thesis Plan — Auditing a Medical LLM with R-ebirth

Standalone thesis document: the recommendation, the full study design, and everything needed to pitch and execute the master's thesis. Execution hooks live in `ROADMAP.md` (the thesis has its own phase there); binding project decisions live in `SOLO-PHASE-PLAN.md`.

- **Status:** v1.0 — **PARKED (2026-07-04):** thesis assignment expected in ~6–8 months (≈ Q1–Q2 2027); this plan resumes unchanged then. By that time the software will be ahead of the thesis's needs (only roadmap Phases 1–2 plus `llm_probe` are required).
- **Date:** 2026-07-03
- **Owner:** Alessandro (candidate)
- **Degree:** MSc Public and Health Economics, Università del Molise (UniMol) — taught entirely in English, member of the EMOS (European Master in Official Statistics) network
- **Language note:** the program is English-taught, so thesis, pitch, and all materials are in English by requirement, not just by project convention.

---

## 1. The recommendation (and the reasoning behind it)

Three options were considered for turning the R-ebirth project into a thesis:

**Option A — the software project alone as the thesis.** *Rejected.* The committee sits in an economics department and evaluates economic and statistical content. A software artifact, however impressive, is graded on someone else's rubric there. High risk, no fallback.

**Option B — an empirical audit study *using* the software (recommended).** The thesis is a policy-relevant empirical study; the `relm` package appears as the methodological contribution (a methods chapter plus a software appendix). This fits the degree exactly (see §2), keeps the empirical question in charge, and gives the thesis two original contributions instead of one: a novel open-source method *and* novel empirical results. The project and the thesis reinforce each other — every improvement to the package strengthens the thesis, and the thesis becomes the package's first published application.

**Option C — medical document understanding (plan B).** MedGemma 1.5 explicitly targets structured-data extraction from lab reports and medical documents. A thesis on the economics of administrative burden (extraction accuracy vs clerical cost in health systems) is viable and closer to public administration topics. Kept as fallback if the supervisor prefers it; it reuses the same infrastructure.

**Verdict: Option B.** The rest of this document specifies it.

Practical advice attached to the recommendation:
1. **Talk to the supervisor early**, with the one-page pitch in §12 — before writing more code aimed at the thesis. The design below is adaptable; supervisor buy-in is not.
2. **Radiology stays, images go.** The radiology theme is preserved through radiology *report text*. The vision variant of MedGemma (actual image interpretation) is deliberately out of scope: it multiplies engineering risk and adds nothing to the economics content. It is named in "future work."
3. **Binding framing rule** (inherited from the project's honesty limits): this is an *audit and investigation* — the thesis never claims to have "removed bias" from a model. Investigating whether and where bias exists, quantifying it, and pricing its consequences is defensible science; claiming to fix it with neuron surgery is not.

---

## 2. Degree fit

The program's own structure (verified on public UniMol sources, 2026-07-03):
- Year 1: economics, statistics, mathematics, public policy.
- Year 2: **public policy evaluation**, **data analysis applied to health economics**, **predictive analysis techniques**; mandatory internship; EMOS-grade statistical rigor.

Mapping of the thesis onto that profile:

| Thesis component | Degree competence it demonstrates |
|---|---|
| Perturbation audit with effect sizes, CIs, multiple-testing control | data analysis / predictive techniques |
| Misclassification-cost and screening-policy analysis | health economics, policy evaluation |
| Local-vs-API deployment economics, GDPR considerations | public economics, digital health policy |
| Reproducible open-source pipeline | EMOS-style methodological transparency |

---

## 3. Working title and research questions

**Working title:** *"Opening the black box of medical LLMs: an open-source statistical audit framework in R, with an application to demographic sensitivity in radiology-report triage."*

- **RQ1 (behavioral):** Does an open medical LLM (MedGemma 1.5 4B, run locally) change its triage priorities and differential-diagnosis outputs when demographic cues (sex, age; optionally socioeconomic markers) vary while clinical content is held fixed?
- **RQ2 (internal):** Where and when is demographic information encoded in the model's internal representations (probe decodability by layer), and does it causally influence outputs (steering/ablation as robustness checks)?
- **RQ3 (economic/policy):** What are the consequences for health systems — asymmetric misclassification costs (the canonical case: under-triaged myocardial infarction in women), equity in AI-assisted screening, and the deployment economics of local open models versus cloud APIs for public healthcare (cost, privacy/GDPR, vendor lock-in)?

RQ1 alone is a publishable audit; RQ2 is the novel methodological layer only `relm` makes convenient; RQ3 is what makes it an economics thesis. The three stack — if RQ2 runs late, RQ1+RQ3 already carry the thesis (built-in de-risking).

---

## 4. Study design

**Core design: perturbation audit with minimal pairs.**

1. **Stimuli.** A bank of clinical vignettes and radiology-report texts in matched pairs/tuples: identical clinical content, systematically varied demographic cues. Two sources: (a) templates derived from real de-identified reports (§5), (b) a synthetic vignette bank, generated and *manually validated* — needed anyway for controlled coverage and statistical power.
2. **Outcome measures (RQ1).** Constrained generation → structured outputs: triage level (ordinal), urgency score, top-k differential diagnoses, recommendation strength. Paired comparisons across demographic variants; effect sizes with confidence intervals; multiple-testing control (e.g., Benjamini–Hochberg across vignette families); pre-registered analysis plan style (write the analysis code against the pilot, freeze it, then run the full bank).
3. **Internal measures (RQ2).** `llm_trace()` on the same stimuli → per-layer probe decodability of the demographic attribute (`llm_probe`, cross-validated AUC with CIs — "at which layer does the model *know* the patient is a woman, and when does that knowledge start moving the triage output?"); representation-similarity comparisons between matched pairs.
4. **Causal robustness (RQ2).** Steer along / ablate the identified demographic direction and measure whether output disparities shrink — reported as *evidence about mechanism*, not as a fix (framing rule, §1).
5. **Economic layer (RQ3).** A misclassification cost model: plug disparity estimates into published cost/outcome parameters for the chosen clinical scenarios (e.g., missed-MI costs, unnecessary-workup costs); sensitivity analysis over parameter ranges. Deployment economics: total cost of ownership of a local 4B model (hardware amortization, energy) vs per-token API pricing at realistic hospital volumes, plus the GDPR/data-locality argument for local inference — itself a policy result the thesis demonstrates by construction (everything runs on one desktop machine).
6. **Reproducibility.** Pinned model file (SHA), pinned seeds, scripted pipeline in the repo, Quarto manuscript. An examiner can re-run the entire study.

**Statistical honesty guards:** matched random-perturbation controls (change an irrelevant token instead of the demographic cue) to calibrate the null; power analysis on the pilot to size the vignette bank; report *distributions* of effects, not cherry-picked prompts.

---

## 5. Data plan

- **Primary (no bureaucracy): OpenI / Indiana University chest X-ray collection** — ~3,900 de-identified radiology reports, openly downloadable from NLM Open-i. Used as the source of realistic report language and case templates. No DUA, no delay, publicly citable.
- **Synthetic vignette bank:** generated (with any strong model) and manually validated minimal pairs; this is the workhorse of the perturbation design and is fully shareable in the thesis repository.
- **Upgrade path (optional): MIMIC-CXR reports** via PhysioNet — requires CITI training + a data use agreement, typically weeks. **If desired, start the application at the beginning of the thesis semester**; the thesis must not depend on it (OpenI + synthetic bank suffice).
- Not used: any non-public or identifiable patient data. (See §10.)

## 6. Model plan

- **Model:** `google/medgemma-1.5-4b-it` — MedGemma 1.5, announced 2026-01-21, sizes 4B and 27B, text and vision-language variants; state-of-the-art or near-SOTA on 20+ medical benchmarks; open for research and commercial fine-tuning under the Health AI Developer Foundations terms (accept once on Hugging Face).
- **Format/runtime:** GGUF Q4_K_M (≈2.5 GB) or Q8 on the Mac mini M4 16 GB via `relm`'s vendored llama.cpp (Metal). Fully local = the privacy/deployment argument of RQ3 demonstrated live.
- **Fallbacks:** if community GGUF quantizations of 1.5 are missing, quantize locally with llama.cpp's conversion tools; if the 1.5 architecture is not yet supported by the vendored llama.cpp tag, fall back to MedGemma 1.0 4B-it (GGUF quants exist — bartowski et al.) and note the version in the thesis.
- **Out of scope:** the 27B (does not fit 16 GB); the vision variant (future work — roadmap Phase 11, "Multimodal models", which would extend this audit to actual radiology images).

## 7. Chapter map

1. **Introduction** — AI adoption in health systems; the black-box problem as an economic and policy problem (accountability, liability, equity).
2. **Methods I — the audit framework:** the `relm` package (architecture summary, the trace→probe→steer workflow), positioned against Python-based interpretability tooling; why local open models matter for health-data governance.
3. **Methods II — study design:** §4 in full.
4. **Results** — RQ1 behavioral disparities; RQ2 internal localization and causal checks.
5. **Economic and policy analysis** — RQ3: cost model, screening equity, deployment economics, GDPR.
6. **Discussion** — limitations (quantization effects, single model, vignette externality), ethics, future work (vision variant, more models, SAE-level analysis).
7. **Software appendix** — the package, reproducibility instructions.

## 8. Timeline hooks

Depends on one missing input: **the thesis deadline** (§13). Anchors (see `ROADMAP.md` phase table):
- Supervisor pitch: as soon as possible — the design is adaptable *before* code is aimed at it.
- Pilot study: possible right after the anatomy-lab phase (traces + steering working) — probe API (`llm_probe`) is scheduled immediately after the first public release precisely for the thesis.
- Full runs + writing: after the probe phase; manuscript in Quarto from day one (methods sections can be drafted while phases complete).

## 9. What the thesis needs from the software (dependency list)

| Thesis step | Needs from `relm` | Roadmap phase |
|---|---|---|
| Vignette generation + output extraction | `llm()`, `llm_generate()` (chat templates, seeds) | Phase 1 |
| Embedding-based report exploration | `llm_embed()` | Phase 1 |
| Internal analysis | `llm_trace()` with filters + spill | Phase 2 |
| Causal checks | `llm_steer()`, `llm_ablate()` | Phase 2 |
| Layer-decodability analysis | `llm_probe()` formula API | Phase 4 (pulled early for the thesis) |
| Everything else (stats, plots, cost model) | plain R: `glmnet`, `pROC`, `ggplot2`, base | already available |

## 10. Ethics and framing

- Public, de-identified data (OpenI) and synthetic vignettes only; no patient-level decisions; no clinical deployment claims.
- MedGemma terms: research use permitted; the model is explicitly not a medical device — the thesis audits it, it does not practice medicine with it.
- Language discipline throughout the manuscript: *audit, investigate, quantify, localize* — never *fix, debias, certify safe*.
- If the department has an ethics-review step for AI/data studies, the OpenI + synthetic design should pass trivially; confirm with the supervisor.

## 11. Thesis-specific risks

| Risk | Mitigation |
|---|---|
| Supervisor prefers a different angle | RQ3 framing is adjustable (equity → costs → governance); Option C (§1) as plan B; pitch early |
| Effect sizes too small on chosen scenarios | pilot-based power analysis; enlarge vignette bank; scenario families chosen where literature documents disparities (cardiac, pain management) |
| MedGemma 1.5 GGUF/runtime gap | quantize locally or fall back to 1.0 (§6) |
| Software phase slips against academic calendar | RQ1 needs only Phase 1 features; RQ2 degrades gracefully (trace-only, no probe API — manual glmnet as in Demo A) |
| Reviewer skepticism about LLM audits | reproducible pipeline + matched-control calibration + conservative claims (§4, §10) |

## 12. Supervisor pitch (ready to adapt, ~1 page when formatted)

> **Auditing medical LLMs for demographic sensitivity: an open statistical framework with an application to radiology-report triage**
>
> Health systems are beginning to deploy large language models for documentation and decision support, but these models are black boxes: when a triage suggestion differs between two otherwise identical patients, we currently cannot say whether, where, or why patient demographics entered the decision. This is an accountability problem, an equity problem, and ultimately an economic one — misclassification has asymmetric costs, and the literature documents systematic under-recognition of, for example, cardiac events in women.
>
> This thesis develops and applies an open-source statistical audit framework. Using a new R toolkit developed by the candidate, which exposes the internal activations of locally-run open models as ordinary data frames, the study (1) measures behavioral disparities in triage outputs of Google's MedGemma 1.5 (4B) across demographically-varied but clinically-identical case vignettes, built from openly available de-identified radiology reports; (2) localizes where demographic information is encoded in the model's layers using cross-validated probes, with steering-based robustness checks; and (3) translates the measured disparities into policy-relevant quantities: expected misclassification costs under published parameters, implications for AI-assisted screening equity, and the deployment economics (cost, privacy, GDPR) of local open models versus commercial APIs for public healthcare providers.
>
> The entire pipeline runs on consumer hardware and is fully reproducible; the software framework is released as open source and constitutes the methodological contribution of the thesis.

## 13. Open inputs

1. **Thesis deadline / graduation session** — paces everything (§8).
2. **Supervisor** — name, and whether the pitch lands as-is or needs the Option C pivot.
3. **Scenario families** — cardiac triage is the default (best-documented disparities); confirm 1–2 more (e.g., pain management) after the literature pass.
4. **MIMIC-CXR** — decide early whether to start PhysioNet credentialing (optional).
