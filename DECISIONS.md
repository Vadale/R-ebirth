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

---

## Appendix A — Rung-3 fork playbook (archived from SOLO-PHASE-PLAN v0.1, 2026-07-03)

Preserved verbatim in substance for the day Phase 21 triggers fire (≥ 3 sustained external contributors + adoption signal + maintenance funding). If that day comes:

1. **Fork base:** the newest *patched* upstream release at fork time. **Patch-first rule:** never base on or adopt an `x.y.0`; adopt a new minor series only at `x.y.1+`; adopt upstream patch releases within ~4 weeks, only after differential CI is green; never track R-devel.
2. **Divergence registry:** every modification of upstream sources recorded in `PATCHES.md` (file, reason, date, revert plan); divergence kept minimal and mechanical so upstream merges stay cheap.
3. **Non-negotiable invariant:** the fork passes upstream's own `make check-all` (including recommended packages) on every commit to `main` — the machine-checkable definition of "we didn't break R".
4. **Versioning:** `R-ebirth X.Y (compatible with R x.y.z)` — the upstream compatibility level always stated, including in `R.version`.
5. **Scope reserved to the fork (nothing else justifies it):** speculative JIT in the evaluator; real surface syntax (type annotations, `async`/`await` keywords); base-default changes. All three stay function-based/API-level until then.
6. **Licensing at rung 3:** the fork repository inherits GPL-2 | GPL-3 (combined distributions effectively GPL-3 for Apache-2.0 compatibility); the permissive Rust crates (`rebirth-llm` etc.) remain MIT OR Apache-2.0 and are linked in — which is why they must stay R-free (see `ARCHITECTURE.md` §2).
