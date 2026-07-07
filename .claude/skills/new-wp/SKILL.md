---
name: new-wp
description: Start a new R-ebirth work package correctly - spec check, branch, TDD order, acceptance criteria. Use at the beginning of every WP, before writing any code.
---

# Starting a work package

Follow these steps in order. Do not skip the gates.

1. **Locate the WP** in `ROADMAP.md` §3. Confirm it is the *next* WP in the current phase and no other WP is in flight (one-WP rule). If the phase itself has no WP breakdown yet (Phases 10–18), stop: that is the `architect` agent's job first.
2. **Gate 1 — spec check:** every function this WP will export must have an approved entry in `API-GRAMMAR.md`. Missing or `status: proposed` entries → stop and report to the founder. Never invent or "temporarily" export.
3. **Gate 2 — decision check:** grep `DECISIONS.md` for entries touching this WP's area. If the WP needs a new dependency or an unsettled choice, the ADR comes first (architect agent), then the code.
4. **Branch:** `git checkout -b wp<ID>-<short-slug>` from up-to-date `main`.
5. **Copy the acceptance criteria** from the WP verbatim into the working notes / PR description. They are the definition of done — restate them, never paraphrase them weaker.
6. **Plan the test order:** write the failing tests first where practical (testthat/cargo). For numerical work, plan the goldens now (see the `golden-update` skill) — golden-first rule. **Rule-8 tests (plan up front if this WP touches these):** a new decode path → an over-`n_batch` regression test (state which CI job runs it); a new memory/size budget → an `object.size ≤ K×estimate` test on the materialized object; a constant duplicated across R and Rust → a twin-pin equality test.
7. **Implement** per the `coder` agent rules (small steps, verify each, honest reporting).
8. **Before handing over:** `devtools::test()`, `R CMD check`, `cargo test && cargo clippy && cargo fmt --check` all green locally; `NEWS.md` updated if user-visible; grep the docs this diff touches for any statement it falsifies and fix it in the same PR (rule 8g); then run the `reviewer` agent, then the founder reviews.
9. **After merge:** if this WP added > ~500 lines or closes a phase, schedule the `simplifier` agent before the next WP starts (mandatory, per `CLAUDE.md`).
