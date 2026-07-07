# Simplifier upgrade — assessment of past passes + Phase-2-boundary punch-list

- **Date:** 2026-07-07 · **Author:** Fable 5 · **Status:** scoping document — no product code changed in this pass.
- **Companion change:** `.claude/agents/simplifier.md` rewritten from "behavior-preserving complexity reduction" to a full **maintainability & refactoring engineer** mandate (six first-class goals: structure/clarity refactoring, measured optimization, dependency reduction, real-reuse helper extraction, leak/resource hygiene, clean coding). This document answers two questions: did the old, narrow simplifier already do that fuller work (§1), and what should the upgraded simplifier tackle at the Phase-2 boundary (§3)?
- **Scope surveyed:** `rebirth-llm` (all 9 modules), `rebirth-ffi`, the R surface (all 10 files), both `Cargo.toml`s + `DESCRIPTION`. The vendored `rebirth/src/llama.cpp/` tree is out of scope by standing rule.
- **Cross-reference:** the 2026-07-07 full audit (`docs/full-review-2026-07-07.md`). Its findings H-1, H-2, M-1, M-2, M-4 and D-017 are **already fixed and merged** (PRs #10–#13, verified in the current tree: `n_batch` chokepoint in `generate.rs`, position/component dedup, spill nonce + prompts digest, reject-not-clamp `to_engine_index`, payload interning + `TRACE_MATERIALIZED_EXPANSION` twin pins). Nothing below re-lists a merged fix.

---

## §1 Did the past simplifier passes already do the fuller work? — No.

All prior simplifier output, from `git log --grep Simplify` plus the WP1 fixture commit:

| Commit | What it did | Category | Size |
|---|---|---|---|
| `9dfa4a5` | factor duplicated close-test fixture into `empty_handle_llm()` | test dedup | +17/−16 |
| `240bf7a` | funnel `catch_unwind` results through one `resolve()` | dedup | +21/−21 |
| `576a7f7` | name the two repeated engine precondition guards | naming | +29/−27 |
| `a460310` | collapse the two-pass FFI sizing loop into `sized_buffer()` | dedup | +56/−58 |
| `e8e9281` | collapse argument-validation aborts into `abort_argument()` | dedup | +40/−46 |
| `cc5a417` | share one context-fit guard between generation and trace | dedup | +4/−16 |
| `8297b02` | drop the unused `trace_token_batch` entry point | dead code | +1/−12 |
| `e320d30` | drop dead `InterventionSpec::is_empty()` | dead code | +4/−7 |
| `5a0ebfa` | inline the one-caller `new_llm_derived()` wrapper | inlining | +3/−10 |

**Verdict (honest):** every pass was genuine, correct, and worth keeping — `abort_argument()` and `sized_buffer()` are exactly the "small internal library with real reuse" pattern the new mandate wants more of. But the work is uniformly **surface dedup + dead-code removal + naming**, each commit under ~60 changed lines. Across all nine commits there is:

- **zero optimization** (no benchmark was ever run in a simplifier pass; the old charter said "performance neutrality");
- **zero dependency work** (neither `Cargo.toml` nor `DESCRIPTION` was ever touched);
- **zero indirection/layer reduction** (no hop in the R → `rebirth-ffi` → `rebirth-llm` → C chain was ever examined);
- **zero god-function decomposition** (no function was split; the largest functions in the tree were never visited);
- **zero leak/lifetime fixes** (the old charter never mentioned resources). Fairness note: the tree's resource handling is broadly RAII-clean (`Drop` on `Batch`/`Model`/`Context`/`SpillSink`, the `Reclaim` guard in `run_capture`) — but that discipline came from the coder and the security-auditor, not from any simplifier pass, and the simplifier never looked.

So the founder's judgment is confirmed: the old agent did the narrow job it was chartered for, and only that. The upgraded charter is a real expansion, not a rename.

---

## §2 What the upgraded mandate adds

See `.claude/agents/simplifier.md` (rewritten today) for the binding text. In one line: "behavior-preserving" now bounds *how* the agent works, not *what* it improves — structure, speed, dependency weight, resource hygiene, and readability are all goals, with the old invariants (green suites + zero golden changes, untouchable public API, no new deps ever, no vendored-tree edits, no repo reorg, no unmeasured perf claims, one concern per commit) fully retained.

---

## §3 The punch-list (ranked)

Ranking: **Gain** (1–5, maintainability or measured-performance value) ÷ **Risk** (1–5, chance of behavior change / review burden). Every item is behavior-preserving; items marked **[bench]** must ship with before/after numbers per the new charter. "Goal" = which of the six mandate goals it serves.

| # | Item | Where | Goal | Gain | Risk | Score |
|---|---|---|---|---|---|---|
| 1 | One owned context-creation helper (kills 4 duplicated init blocks + 2 manual error-path frees) | `engine.rs:461-505, 552-598, 610-641, 731-749` | extract + leak-hygiene | 4 | 1 | 4.0 |
| 2 | HashMap-based label interning in the trace payload (linear scans are O(rows × distinct tokens)) | `rebirth-ffi/src/lib.rs:684-703` | optimization **[bench]** | 3 | 1 | 3.0 |
| 3 | Stop-string check re-decodes the whole output every token — O(n²) detokenize on the generation loop | `generate.rs:790-800` | optimization **[bench]** | 4 | 2 | 2.0 |
| 4 | Resolve trace positions once per prompt (currently up to 3× per prompt) | `trace.rs:747-750, 858-866, 668` | structure/clarity | 2 | 1 | 2.0 |
| 5 | Replace `.max(0)` clamps on `n_embd`/`n_layer` with rejection at the boundary | `rebirth-ffi/src/lib.rs:769, 782` | clean coding (rule 8b) | 2 | 1 | 2.0 |
| 6 | Gate `rebirth_selftest_*` behind a non-default `selftest` cargo feature (already deferred-tracked) | `rebirth-ffi/src/lib.rs:814-868` | clean coding | 2 | 1 | 2.0 |
| 7 | Split `R/trace.R` (847 lines, ~8 concerns) into `trace.R` + `trace-spill.R` | `R/trace.R:673-847` | module boundaries | 2 | 1 | 2.0 |
| 8 | Single-pass `summary.rebirth_trace` (per-group full-column rescans today) | `R/trace.R:521-529` | optimization (minor) | 2 | 1 | 2.0 |
| 9 | Hoist per-token allocations out of the sampling loop (`to_vec` per token + 2 vocab-sized Vecs + full-vocab sort per sampled token) | `generate.rs:408-421, 645-687` | optimization **[bench]** | 3 | 2 | 1.5 |
| 10 | Unify the three `Generation` exit constructions in `generate()` | `generate.rs:740-829` | structure/clarity | 2 | 2 | 1.0 |
| 11 | Move (not clone) prompt pieces into the capture path | `trace.rs:669, 973` | optimization (minor) | 1 | 1 | 1.0 |
| 12 | Trim the production-unused `pub` surface of `rebirth-llm/src/lib.rs` | `rebirth-llm/src/lib.rs:51-100` | clean coding | 1 | 1 | 1.0 |
| 13 | Reuse `is_count()` for `llm_generate`'s inline count checks | `R/generate.R` (max_tokens/seed) vs `R/llm.R:333` | clean coding | 1 | 1 | 1.0 |
| 14 | Twin-pin (or waive in writing) the duplicated byte-formatting formula | `R/llm.R:354-365` vs `error.rs:180-193` | clean coding (rule 8f) | 1 | 1 | 1.0 |

### Item detail

1. **Context-creation helper** — `create_embedding_context` (`engine.rs:461-505`), `create_trace_context` (`:552-598`), `clone_with_fresh_context` (`:610-641`), and `load_impl` (`:731-749`) all repeat: default params → tweak → `llama_init_from_model` → `NonNull` check → per-call error message; the first two additionally duplicate an `n_embd <= 0` check whose error path calls `unsafe { ffi::llama_free(ptr) }` **manually** (`engine.rs:492`, `:589`). Extract a small owned guard (`fn init_context(model: &Arc<Model>, cparams, on_fail) -> Result<OwnedCtx>`) whose `Drop` frees the raw context until ownership transfers into `EmbeddingContext`/`TraceContext`/`Context`. Four real uses (well past the ≥2 bar); deletes the two manual frees, making any *future* early return between init and struct construction leak-proof by construction. This is the flagship item: extraction, dedup, and error-path resource safety in one ~40-line diff.
2. **Interning HashMap** — `trace_payload` finds each row's token/component level with `Vec::position` linear scans. Rows = positions × layers × components; distinct token levels grow with total tokens, so a wide capture (e.g. `positions = "all"` over a few hundred tokens, all layers) does O(rows × levels) `String` compares in FFI marshalling — one of the four named hot paths. A `HashMap<&str, i32>` (std, no dep) makes it O(rows). Bench: time `rebirth_trace` payload construction on a synthetic all-positions capture before/after.
3. **Stop-string O(n²)** — with `stop` set, every generated token triggers `decode_tokens(&out, ...)` over the *entire* accumulated continuation (`generate.rs:791`), so a 500-token generation detokenizes ~125k cumulative tokens. Fix: keep a decoded rolling tail no shorter than `max(stop len) + UTF-8 slack` (stop strings can span token boundaries — that is why the naive per-token piece check was not used). Must keep byte-identical truncation semantics: the existing stop-string tests plus a new boundary-spanning regression test gate it, and the bench is greedy 0.5B generation with a non-firing stop string, before/after. Risk 2 (semantics subtle), gain 4 (removes a quadratic term from the flagship loop).
4. **Positions resolved once** — `spec.positions.resolve(ids.len())` is recomputed in the estimate (`trace.rs:747-750`), again twice in `capture_spilled`'s metadata (`:858-866`), and again per prompt in `run_capture` (`:668`). Compute `Vec<Vec<u32>>` once in `trace_capture_planned` and pass it down; removes the "which resolution does this branch use?" question and makes the estimate/capture agreement structural.
5. **Reject-not-clamp `n_embd`/`n_layer`** — `rebirth_intervene` shapes out-of-contract metadata with `.max(0)` (`lib.rs:769,782`) — the same family the audit's M-4 eliminated for indices. Today a mismatch is caught downstream by `derive_with_interventions`' dimension check, so this is consistency, not a live bug; route both through a `checked_count`-style guard so the boundary has exactly one convention.
6. **`selftest` feature gate** — three test-only entry points (`rebirth_selftest_new_handle`, `_panic`, `_trace_tokens_spill`) ship in every build. Already on the deferred list; it is simplifier-shaped (dead-scaffolding control). Requires the R tests that call them to skip when the feature is off — coordinate with test-engineer on the CI matrix.
7. **Split `R/trace.R`** — one file holds the user entry, two constructors, budget logic, spec-key/digest, three print/summary methods, `as.matrix`, and the entire spill read/integrity layer. Moving `read_spill_slice`/`verify_spill_integrity`/`spill_schema_ok`/`summary_spilled_trace` to `R/trace-spill.R` is a pure file move (R packages are flat — this is not a repo reorg), leaving each file one describable concern.
8. **Single-pass summary** — the in-memory `summary.rebirth_trace` rescans full columns once per `(layer, component)` group. `tapply`/`aggregate` over an interaction does it in one pass and reads shorter. Minor, but summaries of big in-memory traces are interactive-latency surface.
9. **Sampling-loop hoist** — per sampled token: one vocab-wide `to_vec` (`logits_ith`, `generate.rs:420`), a fresh `order` Vec + full `sort_unstable_by` over the whole vocab (152k on Qwen), and a `probs` Vec (`sample`, `:645-687`). Reuse buffers across iterations; **do not** change the algorithm or reduction order — the determinism contract (same seed ⇒ same tokens) pins outputs, so only allocation strategy may move. Bench sampled (T>0) 0.5B generation. Greedy path (`argmax`) is already allocation-light apart from the `to_vec`.
10. **`generate()` exits** — stop-string returns early with its own `Generation` literal (`:793-799`) while EOG/context-full/max-tokens fall through to a second literal (`:823-828`), plus the `max_tokens == 0` literal (`:747-752`). A single construction point (or a small `finish(out, reason)` closure) makes the four stop reasons read as one table. Borderline: the function is 90 readable lines; do it only if it genuinely reads better.
11. **Pieces moves** — `trace_texts_spill` clones every prompt's pieces (`trace.rs:973`) while `encodings` stays alive, and `run_capture` clones again per prompt (`:669`). Restructure to move ownership. Small absolute bytes next to activations; take it only as a rider on item 4's plumbing.
12. **`rebirth-llm` pub surface** — `backend_init`/`backend_free`/`system_info`/`supports_mmap`/`supports_mlock`/`max_devices` have no production caller (only the linkage-gate test; `supports_gpu_offload` is the exception, used by `engine.rs`). Keep the linkage test, drop or `pub(crate)` the rest so the crate's API states what is actually load-bearing.
13. **`is_count()` reuse** — `llm_generate` re-spells the whole-number check inline for `max_tokens` and `seed` while `llm_logits` uses the shared `is_count()`. One validator, one message style.
14. **Byte-format twin** — `format_bytes()` (R) and `human_bytes()` (Rust) implement the same formula for the two halves of the OOM message (R pre-check vs engine). Divergence is cosmetic-only, but Hard rule 8(f) asks for a twin-pin test or an explicit waiver; a 5-line testthat/`#[test]` pair comparing a few sentinel values closes it.

---

## §4 Honest negatives (surveyed and *not* found)

- **No collapsible indirection hop.** The R wrapper → `rebirth-ffi` → `rebirth-llm` → C chain was walked end-to-end for every exported function: each hop carries a real contract (R: validation + classed conditions; ffi: 1↔0-based conversion, panic catching, payload shaping; engine: RAII + engine-native types). The thin `activations`/`trace_token_batch_spill` wrappers are golden-test entry points, not needless hops. Today's answer to "reduce layers" is: the layers are each paid for; item 1 is the only extraction-shaped win inside them.
- **No live leak found.** Every error path in the surveyed tree either owns via `Drop` or (the two `engine.rs` sites in item 1) frees manually and correctly today. The R side's finalizer/close interplay is take-once and idempotent. This matches the security-auditor's WP5 verdict. The systematic proof stays with **F-1** (ASan/LSan CI job — already tracked, owner: test-engineer), which the simplifier does not replace.
- **No removable dependency.** Rust: `extendr-api`, three pinned `arrow-*` crates already `default-features = false` behind the default-on `spill` feature (transitive chrono/num/half documented as non-removable without forking arrow), `cmake` as build-dep. R: `Imports: nanoarrow` only. Considered and **recommended against**: demoting nanoarrow to `Suggests` (spill-read-only use) — `spill = TRUE` is the default, so a lazy failure at first big trace is worse UX than the one small Import; it would also be a user-visible install-surface change needing the founder/ADR anyway. Dependency reduction here is a *watch brief*: re-verify the arrow feature trim at every `vendor-bump`/arrow bump.
- **Trace decode single-batch is safe by construction** — `TraceContext` sets `n_batch = n_ubatch = n_ctx` (`engine.rs:552-598`), so `decode_all`'s one-shot decode cannot trip the `n_batch` assert; same for embeddings. Verified, not a finding.

## §5 Process notes for the executing pass

- **Benchmarks without new deps:** `#[ignore]`d `std::time::Instant` tests in the relevant Rust module, `system.time()` harnesses in R, or `hyperfine` as an external CLI. Numbers go in the commit message (charter requirement). Items 2/3/9 do not merge without them.
- **Where the guards live:** items 3 and 9 sit inside golden-pinned behavior (greedy goldens, stop-string tests, determinism contract) — the suites must be green before/after with zero golden changes; item 3 additionally ships a stop-string-spanning-token-boundary regression test.
- **Docs to sweep when items land** (Hard rule 8(g)): the CLAUDE.md agents-table row for `simplifier` still reads "anti-entropy / complexity reduction" and should be updated to the new mandate in the same commit series that adopts the rewritten agent file.
