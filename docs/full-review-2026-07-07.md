# Full adversarial code review — `main` @ `6e1d565` (WP0–WP5 + llm_logits)

- **Date:** 2026-07-07 · **Reviewer:** Fable 5 (max effort) · **Status:** findings report — analysis only, no code changed.
- **Scope:** everything merged through `6e1d565`: `rebirth-llm` engine, `rebirth-ffi` boundary, the WP5 vendored patch, the R package surface, tests + goldens, build + CI. Checked against `API-GRAMMAR.md`, `DECISIONS.md` D-001..D-016, `ARCHITECTURE.md`, and the CLAUDE.md hard rules / honesty limits.
- **Verification performed while auditing:** `cargo fmt --check` clean; `cargo clippy -p rebirth-llm --all-targets -D warnings` clean; `cargo test -p rebirth-llm` all green (incl. all synthetic goldens); `cargo check -p rebirth-llm --no-default-features` builds; `verify_vendored_tree.sh` G4 + coherence OK; R `testthat` suite green (0 failures, 34 [MODEL]-gated skips — no Qwen path set in this shell); two empirical repros run for the H-1 and M-1 findings (numbers below).

**Bottom line.** The numerical core is in genuinely good shape: the oracle discipline (seeded weights recomputed independently **and** byte-checked against the committed GGUF), the adversarial no-op guards, the bitwise reversibility/compose-order tests, and the fails-loud arch/component gates are exemplary and caught nothing wrong. The defects that remain are concentrated in exactly two territories: (1) **resource-safety promises that measure the wrong quantity** (the trace budget), and (2) **recurrences of the already-paid-for `n_batch` / clamp / duplication lesson classes**. Nothing found invalidates a shipped golden or a shipped numerical claim.

---

## §1 Correctness findings, by severity

### HIGH

#### H-1 — The trace memory budget measures the wrong bytes: an "in-budget" `llm_trace()` can still kill the 16 GB session (~10× persistent, ~30×+ transient)

- **Where:**
  - `rebirth/src/rust/rebirth-llm/src/trace.rs:707-728` — `estimate_capture_bytes` counts `n_values × 4` (engine f32).
  - `rebirth/R/trace.R:296-304` — default budget `min(2 GB, 20% RAM)` compared against that same ×4 basis (`trace.R:334-369`).
  - `rebirth/src/rust/rebirth-ffi/src/lib.rs:598-640` — `trace_payload` expands every captured f32 into 7 parallel Rust vectors: 4×i32 + f64 + **a cloned `String` token per neuron** (`lib.rs:619`) + a `String` component per neuron ≈ 90–110 B/value, then extendr copies all of it again into R vectors.
  - `rebirth/R/trace.R:186-205` — the final long data.frame.
- **Measured:** a 1 M-row trace-shaped data.frame is **10.0×** its 4-byte estimate basis (38.1 MB vs 3.8 MB; `object.size`, run 2026-07-07). Transient peak (Rust payload + R copies alive simultaneously) is analytically ~30–35×.
- **Failure scenario (in-spec input, default settings):** any capture whose estimate lands in **[~300 MB, 2 GB]** — e.g. `positions = "all"` over a few thousand total tokens with all layers on a 0.5–1.5B model — passes the predictive check, stays in memory (`spill=TRUE` never triggers because the estimate is under budget), and then materializes 3–20 GB persistent + tens of GB transient on the 16 GB Mac. The session dies or thrashes with **no error raised** — the exact outcome §1.6 / ARCHITECTURE §6 exist to prevent. The defaults (`positions="last"`) are safe; the *documented* widening path is not.
- **Why it happened:** ARCHITECTURE §5 defined the estimate as f32 host-buffer bytes at design time; the same number was later reused as the session-safety gate for a 10×-larger materialization. Design-level gap → needs a short superseding ADR, not just a patch.
- **Fix direction (three parts):**
  1. Redefine the budget check as *materialized-object bytes*: compare `estimate × EXPANSION` (a named constant ≈ 10, measured and tested) against the budget, in **both** the R pre-check and the engine `Oom`/spill decision so the two stay symmetric.
  2. Kill the transient blow-up: stop cloning `token`/`component` per neuron in `trace_payload` — send one value per *CaptureRow* (or factor codes) and expand on the R side with `rep()`, which reuses R's interned CHARSXPs; this alone removes most of the peak.
  3. Add the regression test class: materialize a mid-size trace and assert `object.size(df) <= K × estimate_bytes`.
  Until merged, an honest stopgap is a much smaller default in-memory threshold (e.g. 256 MB estimate-basis ⇒ ~2.5 GB object), which makes big captures spill — the spill path is verified and cheap.

#### H-2 — `logits_for_tokens` carries the exact `GGML_ASSERT(n_tokens <= n_batch)` abort class the llm_logits fix just paid for (latent, not yet R-reachable)

- **Where:** `rebirth/src/rust/rebirth-llm/src/generate.rs:403-418` — `check_fits()` guards `≤ n_ctx`, then `self.decode(tokens, 0, false)` submits the whole sequence as **one** batch. Same wrong-bound pattern as the pre-`b7e6528` `llm_logits`.
- **Failure scenario:** any caller passing > `n_batch` tokens (default 2048) with `n_ctx ≥` that: `llama_decode` trips `GGML_ASSERT` → `ggml_abort` → SIGABRT, uncatchable by `catch_unwind`, whole process gone. Today its only callers (golden tests, `intervene_kl.rs:138-148`) use short sequences and it is **not** exposed through `rebirth-ffi`, so nothing ships broken — but it is the designated "teacher-forced oracle path", `pub`, documented as such, and WP6b nightly tolerance runs / `llm_probe` are natural future callers with real-corpus lengths. Secondary hazard when exposed: all-positions logits allocate `seq × vocab` f32 (2048 × 152k ≈ 1.2 GB on Qwen) twice (engine output buffer + our copy).
- **Fix direction:** chunk inside `logits_for_tokens` by `n_batch`, harvesting each chunk's rows **after its own decode** (`llama_get_logits_ith` only addresses the last decode's buffer — that is why naive chunking wasn't done; the per-chunk copy is the correct form). If chunking is deferred, make it reject `tokens.len() > n_batch` with a classed error *now* so the abort is unrepresentable. Either way, add the `load_with_batch(Some(4))` regression test, mirroring `synthetic_logits.rs:304`.

### MEDIUM

#### M-1 — Duplicate explicit `positions` produce duplicated rows and a silently mis-assembled `as.matrix()` (wrong values under correct labels)

- **Where:** `rebirth/R/trace.R:265-292` (`validate_positions` — no dedupe); `rebirth/src/rust/rebirth-llm/src/trace.rs:88-94` (`Positions::Explicit::resolve` keeps duplicates → the capture loop at `trace.rs:436-455` emits N copies of the row); `rebirth/R/trace.R:571-577` (`as.matrix` reshape assumes `nrow(sub) == npts × n_neuron`).
- **Repro (run 2026-07-07):** `positions = c(1, 2, 2)` → the matrix row `"1.2"` comes back as `1,1,2,2` instead of `1,2,3,4` — interleaved halves of the duplicate rows. Base R emits only a generic `matrix()` length warning (and in some shapes none) and **still returns the wrong matrix**. This is in-spec input (validation passes) in the silent-mislabeling class the honesty limits target; it equally corrupts the spilled read-back path.
- **Fix direction:** dedupe (`sort(unique())`) explicit positions in `validate_positions` (and dedupe `components` in the same pass — `c("residual","residual")` is currently accepted and double-counts groups in the spilled `summary`); defensively dedupe in `Positions::resolve`; and give `as.matrix.rebirth_trace` the structural invariant check `nrow(sub) == nrow(pts) * n_neuron` → `rebirth_error_trace`, which also catches any *future* duplication source.

#### M-2 — The spill staleness fail-safe can be defeated: `trace_id` is the file basename and `spec_key` omits the prompts

- **Where:** `rebirth/R/trace.R:154` (`trace_id <- basename(spill_path)` — e.g. `"trace-1.arrow"`); `rebirth/R/trace.R:245-261` (`trace_spec_key` = model path|layers|positions|components — **no prompts**, and the "model SHA" of ARCHITECTURE §6 is actually just the path); `rebirth/R/zzz.R:41-51` (the counter restarts at 1 each session); `spill.rs` `File::create` truncates an existing file.
- **Failure scenario:** user passes `spill_dir = "~/traces"` (supported argument) in session A, saves the trace object; session B with the same dir and same filters (different prompts!) writes `trace-1.arrow` again → footer `trace_id` and `spec` both match → `verify_spill_integrity` **passes** → object A's `as.matrix()` silently returns session B's activations for different prompts. The managed session directory is immune (unique per session); only user-supplied `spill_dir` is exposed — but that is precisely the persistent-files workflow.
- **Fix direction:** make `trace_id` a real nonce (session token + counter + timestamp — one line in `next_spill_path`/`llm_trace`); include a digest of `prompts` (and the model file size/mtime or SHA) in `spec_key`. Zero format-version impact; the footer strings are opaque to the writer.

#### M-3 — CI never executes `rebirth-ffi`'s tests: the §4 index-conversion property tests are dead in CI

- **Where:** `.github/workflows/rust.yaml:50` runs `cargo test -p rebirth-llm` only; `.github/workflows/R-CMD-check.yaml:56-58` runs clippy for `rebirth-ffi` but never its tests.
- **Consequence:** `engine_index_round_trips_over_the_valid_range` and `tensor_name_layer_surfaces_as_one_based_api_layer` (`rebirth-ffi/src/lib.rs:806-829`) — the tests for the project's self-declared canonical defect class — run only on dev machines. A regression in `to_engine_index`/`from_engine_index` would merge green.
- **Fix:** add `cargo test -p rebirth-ffi` to `R-CMD-check.yaml` right after its clippy step (R is already on PATH there; that is the whole reason the step lives in that workflow).

#### M-4 — `to_engine_index` clamps in release builds; through `rebirth_intervene` an out-of-contract index becomes a *different valid* index instead of an error

- **Where:** `rebirth/src/rust/rebirth-ffi/src/lib.rs:100-106` (`(one_based - 1).max(0)`, `debug_assert!` only — inert in release), consumed at `lib.rs:694-709` for steer/ablate layers **and neurons**.
- **Failure scenario:** only out-of-contract (R validates first), but the failure mode is the bad kind: a future R-validation slip passing `layer = 0` ablates **layer 1**; `neuron = 0` ablates **neuron 1** — a plausible wrong intervention rather than a loud error, i.e. the D-012 "fails-silent" class applied to the intervention core. The F-4 comment calls the clamp a memory-safety floor; for the intervene/trace entries, wrongness is strictly worse than a caught panic.
- **Fix direction:** a fallible `to_engine_index_checked() -> Result<u32, RebirthError>` (raising `rebirth_error_internal` — a `≤ 0` here means R validation broke and we want to hear it) used by the intervene and trace entries; keep the round-trip property test. See P-4 for the general rule.

#### M-5 — `DESCRIPTION` still claims "no modelling functionality is available yet"

- **Where:** `rebirth/DESCRIPTION`, Description field ("The package is in early development (repository scaffold): no modelling functionality is available yet.").
- Eight exported functions later this is simply false — in the one metadata surface every CRAN/r-universe listing shows. The honesty rules cut both ways: the stated scope must match reality. **Fix:** rewrite the sentence now; add "DESCRIPTION scope text is current" to the release skill checklist.

### LOW

- **L-1 — Recycling-warning semantics deviate (mildly, defensibly) from API-GRAMMAR §4.** Grammar: warn "if lengths differ"; implemented (`trace.rs:96-110`): warn only when a position was actually dropped. The implementation is arguably better; record the deviation (roxygen note or a one-line grammar amendment through the normal change protocol) so it is not rediscovered as a bug.
- **L-2 — A second 1↔0-based conversion site outside `rebirth-ffi`.** `rebirth/R/trace.R:603` and `:649-655` shift the 0-based on-disk indices in R, contradicting §1.3 / ARCHITECTURE §4 ("conversion at the FFI boundary and nowhere else"). Pinned by the round-trip test, so accept — but tag both sites with a grep-able `# INDEX-SHIFT (ARCH §4 exception: spill files are engine-native)` marker and note the exception in ARCHITECTURE §4, or move to 1-based on disk at the next format-version bump.
- **L-3 — The `--no-default-features` (no-spill) build is never compiled in CI.** The `#[cfg(not(feature = "spill"))]` arm (`trace.rs:781-791`) can rot. Add `cargo check -p rebirth-llm --no-default-features` to `rust.yaml` (seconds).
- **L-4 — `cargo audit` / `cargo deny` still absent** (D-008 G4 second half; already tracked). Now that arrow-rs brought a real dependency tree, wire it.
- **L-5 — Patch hygiene: `llama_adapter_intervene::apply` failure paths leave a stale `layer_start/layer_end` alongside partially rebuilt `masks`** (patch `0001-…-intervene.diff`, `apply()` early `return false` after `masks.assign`). Unreachable in rebirth's usage (fresh context per derivation; failure drops the handle), but the symbol is public C API: reset `layer_start/layer_end = -1` on every failure path at the next patch touch.
- **L-6 — One shared `seed` across a vectorized `llm_generate(prompt)`** (`generate.R:83-113`): `llm_generate(m, rep(p, 10))` at temperature > 0 returns 10 *identical* strings. Consistent with the per-call seed contract, but it silently degenerates the obvious "sample several continuations" idiom — document it explicitly in the roxygen ("to sample distinct continuations, vary `seed` or call repeatedly"); a per-element derived seed (`seed + i - 1`) would be an API-behavior change requiring founder sign-off.
- **L-7 — `llm_tokens()` (add_special=FALSE) vs every forward-pass path (add_special=TRUE):** on BOS-adding models, trace `token_pos` is shifted by one relative to `llm_tokens()` output. Spec-conform (both documented), but it is an alignment trap for exactly this package's audience — add a roxygen note in `?llm_trace` ("the `token` column, not `llm_tokens()`, is authoritative for positions").
- **L-8 — Grammar §6 "raised by" column is now incomplete:** `llm_logits()` also raises `rebirth_error_tokenize` (no-tokenizer model — asserted by `test-llm-logits.R:54`) and `rebirth_error_context_overflow`; `llm_embed`/`llm_trace` raise their classes from the intervened-handle guard. Sync the table (doc-only).
- **L-9 — Cosmetics, no action required now:** `available_backends()` init/frees the whole llama backend when no model is loaded (`engine.rs:80-88`; correct per contract, just churn); `quiet_log` writes ERROR text to Rust stderr rather than `REprintf` (invisible in some GUI sinks; revisit with the Phase 5+ logging story); `HANDOFF.md` is a stale pre-WP3 snapshot ("WP3 is next") — refresh or delete at the next doc pass.

### Audited clean (explicitly, so nobody re-audits blind)

- **The WP5 vendored patch:** F-2/F-3 bounds and null checks hold; the un-intervened graph is node-identical to unpatched (verified by the passing pre-patch goldens + G4/coherence hashes recomputed during this audit); `sched_need_reserve` mirrors the cvec path; pointer-compare graph reuse mirrors cvec exactly.
- **The eval-callback tap:** panics cannot cross the C ABI (`trace_trampoline` catch_unwind, `trace.rs:465-492`); the `Box::into_raw`/`Reclaim` state lifetime is sound (ctx declared after the guard → drops first on every path); tap errors take precedence over the decode status; the shape check (`nelements == n_tokens × n_embd`) makes a broken all-tokens-flagged assumption fail loudly, never capture wrong rows.
- **The spill thread (first background thread, D-008 G2):** bounded channel; join on `finish` *and* on `Drop`; a writer panic surfaces as `rebirth_error_internal` via the join; failed captures remove the partial file; only owned `CaptureRow`s cross the boundary — no handle, no SEXP. Thread discipline holds.
- **Every other decode path is `n_batch`-safe by construction:** generation and `llm_logits` chunk via `prompt_last_logits`; embed and trace contexts are created with `n_batch = n_ubatch = n_ctx = longest input`, so their single-batch decodes fit by construction (and the trace shape check would catch a violation).
- **Intervention numerics:** steer row/native-view alignment (unit test + oracle), compose order (bitwise ablate-overrides-steer), reversibility (bitwise base reproduction after derivations), effect-size floors, no-op ceilings, matched-random control — all present and passing.
- **Goldens are not gameable in what they check:** the oracle recomputes weights from the seed *and* byte-compares the committed GGUF (`gguf_weights_match_source`); ATOL 1e-2 is justified against observed 2–4e-3 with the ≥ ~5e-2 argmax margin and the top-k `> 2×ATOL` gap self-guard, so a value shift or rank scramble beyond F32 noise fails. The planned WP6b mutation test (layer off-by-one must fail the harness) remains the one still-missing formal proof — keep it in WP6b.
- **Index conversions:** all inbound/outbound sites enumerated and consistent (tokenize +1 out; detokenize −1 in with engine-side range rejection; logits token_id +1; trace layers/positions −1 in exactly one helper; payload/spill-report +1; intervene −1). Only M-4 (clamp semantics) and L-2 (the disk-reader site) qualify findings.
- **Error mapping:** every `RebirthError` variant ↔ one grammar §6 class, fields populated, `rebirth_check`/`rebirth_abort` single funnel, panic → `rebirth_error_internal` proven by a self-test.

---

## §2 Systemic patterns and the preventive rule for each

**P-1 — Decode guards check the wrong bound (`n_ctx` when the engine asserts `n_batch`).**
Instances: the shipped `llm_logits` SIGABRT (fixed in `b7e6528`); `logits_for_tokens` today (H-2). Root cause: the engine's real precondition lives in a llama.cpp `GGML_ASSERT`, invisible to our types — `check_fits()` *sounds* sufficient and reads as sufficient in review.
**Prevent:** (a) one decode chokepoint — move the `n_batch` chunk loop into `LoadedModel::decode()` itself (or a `decode_checked`) so an unchunked over-batch submit is unrepresentable; single-batch contexts (embed/trace) assert `len ≤ n_batch` there. (b) Standing test class: *every new decode path lands with a `load_with_batch(Some(small))` over-batch regression test* (the pattern `synthetic_logits.rs:304` established). (c) `new-wp` checklist line: "list each engine assert (`GGML_ASSERT`/abort) reachable from your new path, and name the guard".

**P-2 — Session-killing engine contracts are discoverable only by reading vendored C++.**
Same root as P-1, plus D-008 G1 (GGUF parse aborts). **Prevent:** a one-page `ENGINE-CONTRACTS` section (in ARCHITECTURE or `src/llama.cpp/patches/README.md`) listing the audited abort points and their guards — `n_tokens ≤ n_batch` per decode; whole-sequence-in-one-ubatch for non-causal; `get_logits_ith` debug-abort semantics; GGUF parse asserts (G1) — updated at every `vendor-bump`. New FFI entries must cite which contracts they honor.

**P-3 — Predictive safety estimates that measure a different quantity than the one that kills the session.**
Instance: H-1 (budget counts engine f32; the session dies on the 10× R object + ~30× transient). Root cause: a design-time formula (ARCH §5, engine buffers) silently repurposed as the end-to-end safety gate.
**Prevent:** standing rule — *a memory budget is always stated against the peak resident cost of what the user receives*, with a measured expansion constant and a test asserting `object.size(result) ≤ K × estimate`. Phase 6 streaming traces and Phase 14 SAE datasets inherit this rule verbatim.

**P-4 — Clamp-instead-of-reject at the boundary, on top of R-side-only validation.**
Instances: `to_engine_index .max(0)` (M-4); `context_length.max(1)` (`lib.rs:269`); `max_tokens.max(0)` (`:375`); `top.max(0)` (`:404`); `budget_bytes.max(0.0)` (`:486`). Each is individually "defensive"; collectively they convert contract violations into *plausible different requests* — worst in the intervention path.
**Prevent:** standing rule — *at the FFI boundary, out-of-contract input raises `rebirth_error_internal` (it means R validation broke and we want the bug report); silent clamps are allowed only where provably semantics-preserving.* Convert the five sites; reviewer checklist line: "grep the diff for `.max(0`/`.max(1` on boundary arguments".

**P-5 — Semantic knowledge duplicated across languages drifts (R ↔ Rust ↔ disk).**
Instances: the intervention arch list (R `intervene.R:12` vs Rust `intervene.rs:30` — already protected by twin pin-tests: the good pattern); trace component names; the budget formula (R `check_trace_budget` vs Rust `estimate_capture_bytes` — **no cross-check today**); the index shift (ffi helpers vs the R spill reader, L-2).
**Prevent:** make the twin-pin-test pattern a standing rule — *any constant, enum, or formula duplicated across the R/Rust/disk boundary gets a pin test on each side in the same commit that creates the duplicate* — and close the one open gap (a test asserting R's estimate equals the engine's for a fixed spec).

**P-6 — Integrity tokens derived from colliding user-visible values.**
Instance: M-2 (`trace_id` = basename; `spec_key` without prompts). Root cause: the fail-safe was designed for the managed-directory threat model and silently weakened by the user-`spill_dir` path.
**Prevent:** standing rule — *any on-disk integrity/uniqueness token is a nonce or content digest, never a filename, counter, or filter echo*; checklist line for every feature that writes files.

**P-7 — Tests and gates that exist but do not run where it matters.**
Instances: `rebirth-ffi` tests absent from CI (M-3); the no-spill build never compiled (L-3); `cargo audit`/`deny` unwired (L-4); the cargo golden suite runs Linux-only in CI (macOS engine coverage is founder-local — acceptable, but undocumented).
**Prevent:** a small "what runs where" matrix (test class × CI job × local-only) kept at the top of `rust.yaml` or in ARCHITECTURE; `new-wp` checklist line: *"state where each new test executes in CI; if nowhere, wire it in this PR"*.

**P-8 — Docs and specs trailing merged reality.**
Instances: `DESCRIPTION` (M-5); stale `HANDOFF.md`; the grammar §6 raised-by column (L-8); the §4 wording (L-1); historically ARCHITECTURE §2.2 needed D-009. Root cause: doc-sync is a session-hygiene habit, not a merge gate.
**Prevent:** a merge-checklist line — *"grep the repo docs for statements this diff falsifies (DESCRIPTION, HANDOFF, CLAUDE.md status, grammar tables) and fix them in the same PR"* — and run doc-writer at WP close (the existing process; enforce it).

**Patterns to KEEP (recognized as house standards, verified effective here):** golden-first with an independent oracle *plus* committed-artifact byte-verification; adversarial no-op guards (effect floors, no-op ceilings, matched-random controls, kept-mass < 1); fails-loud gates for unsupported arch/component (never a silent empty capture or no-op); twin pin-tests across the language boundary; one regression test per paid-for bug (the chunked-decode test).

---

## §3 Adopt now — highest-leverage, in order

1. **Fix H-1** — budget redefined on materialized bytes (small superseding ADR: expansion constant, symmetric R/engine check, `object.size ≤ K × estimate` test) + de-duplicate the `token`/`component` strings in `trace_payload`. Interim: drop the default in-memory threshold to ~256 MB estimate-basis so large captures spill (the spill path is proven).
2. **Fix H-2** — chunk (or explicitly reject > `n_batch`) in `logits_for_tokens`; move the chunk loop into the single decode chokepoint; adopt the P-1 rule: every new decode path ships its `load_with_batch` over-batch regression test.
3. **Fix M-1** — dedupe positions/components in R validation + engine-side dedupe + the `as.matrix` structural invariant error.
4. **CI gates (M-3, L-3, L-4)** — add `cargo test -p rebirth-ffi` (R-CMD-check job), `cargo check --no-default-features` (rust job), and `cargo audit`/`cargo deny`; add the "what runs where" matrix comment.
5. **Boundary rule (P-4/M-4)** — reject-never-clamp at the FFI: convert the five clamp sites, checked variant for `to_engine_index` on the intervene/trace entries.
6. **Fix M-2 (P-6)** — nonce `trace_id` + prompts-digest in `spec_key`.
7. **Standing rules into CLAUDE.md / new-wp / reviewer checklists (P-1..P-8)** — the seven one-liners above: engine-assert inventory per new FFI path; budget = materialized bytes; reject-never-clamp; twin pin-tests for cross-language duplicates; nonce/digest integrity tokens; "where does this test run in CI"; docs-falsification grep at merge. Plus fix M-5 (DESCRIPTION) immediately — it is a one-line diff.

Deferred-but-tracked items reconfirmed open (no change): WP6b mutation test + HF-Qwen activation golden; `selftest` cargo feature gate for the `rebirth_selftest_*` entries; the `[MODEL]` 4B-spill/Qwen acceptances on the founder's Mac; D-008 G1 subprocess isolation before untrusted downloads (Phase 3).
