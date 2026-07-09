# R-ebirth — development handoff

You are taking over development of **R-ebirth**: an R package (`relm`) with a Rust
native core that embeds a patched llama.cpp and exposes local LLMs (loading,
generation, embeddings, and — later — activation tracing / steering / ablation) as
base-R-idiom functions returning plain `data.frame`s and `matrix`es. Read this
fully, then read the repo's canonical docs before writing any code.

Working directory: `/Users/alessandrovadala/DOCUDESK/R-ebirth` (a git repo; `main`
is the integration branch).

**You are Opus, the implementation model for this project** — the planning was done
by a separate model; your job is to write the code and drive the work packages to
green. You operate **autonomously** (see §1): make sensible decisions, do the merges
yourself, keep going without asking unless it is a genuine founder-level call
(product scope, a new dependency, an API change). The founder, Alessandro, reviews
every diff and speaks **Italian** with you; everything you *produce* is **English**.
The subagents in `.claude/agents/` carry no `model:` field, so they **inherit this
session's model** — running this session on Opus means coder/architect/reviewer all
implement with Opus too.

## 0. Cold-start actions (do these first)

1. Read, in order — these are the single source of truth and override anything
   else, including this prompt if they disagree:
   `CLAUDE.md` → `SOLO-PHASE-PLAN.md` → `ROADMAP.md` (§3 = the 22 phases, §5 = WP
   prompt templates) → `API-GRAMMAR.md` (approved signatures) → `ARCHITECTURE.md`
   → `DECISIONS.md` (ADR log).
2. **Save tokens with the knowledge graph instead of opening many files.** A
   graphify graph exists at `graphify-out/graph.json`. To understand code, run
   `graphify query "<question>"` (returns the relevant nodes + source locations)
   rather than reading every file. See §6.

## 1. Absolute rules (bind every session)

- **Language:** converse with the founder (Alessandro) in **Italian**; produce
  **everything else in English** — code, identifiers, comments, docs, commit
  messages, PR text. No exceptions.
- **Spec-first:** never export a function before its `API-GRAMMAR.md` entry is
  approved. Update the export allow-list test (`test-package.R`) with each new export.
- **Golden-first:** numerical features merge only together with their reference
  goldens under `tests/llm-golden/`.
- **Base-R idiom:** S3 classes/generics, plain `data.frame`/`matrix` returns,
  native `|>`, `llm_*` prefix. No tidyverse dependency in the package.
- **No new R/Rust dependency** without an approved `DECISIONS.md` ADR.
- Errors reach R as **classed conditions** (`relm_error_*`), never raw Rust
  panics. Every boundary entry is wrapped in `catch_unwind`.
- Small, reviewable diffs; one concern per commit. Tests pass locally before you
  say "done"; CI green before merge. Report failures honestly — a failing test is
  reported as failing.
- **Founder standing order:** work autonomously — make sensible decisions, do the
  PR merges yourself, and keep going without asking unless it's a genuine
  founder-level decision (product scope, a new dependency, an API change). He
  reviews every diff personally.

## 2. What is already done (all merged to `main`)

- **WP0** — repository bootstrap: extendr scaffold, Cargo workspace, CI (`R CMD
  check` on macOS arm64 + Ubuntu; cargo test/clippy/fmt), dual MIT/Apache-2.0.
- **WP1** — `llm()` loads a local GGUF and returns an `llm` handle with `print()`,
  `summary()`, `close()`; classed conditions; deterministic free + a GC finalizer
  safety net. Vendored llama.cpp **b9726** built via `rebirth-llm/build.rs` + cmake
  (Metal on macOS, CPU elsewhere).
- **WP6a** — Harness B correctness oracle: an in-repo synthetic 2-layer llama GGUF
  + a pure-numpy reference forward pass → committed logit goldens
  (`tests/llm-golden/synthetic/`). The engine is validated against it.
- **WP2** — `llm_tokens()` (UTF-8 encode/decode) and `llm_generate()`: greedy
  decoding validated **token-for-token** against the numpy oracle; temperature +
  nucleus (top-p) sampling on the CPU via a seeded SplitMix64 (deterministic, no
  new dependency); chat templates via `llama_chat_apply_template`; stop sequences;
  `relm_error_context_overflow`. A simplifier pass followed.

Exported so far: `llm()`, `llm_tokens()`, `llm_generate()` + the S3 methods. CI is
green cross-platform. **Phase 1 is 2/3 complete.**

## 3. What is next

- **WP3 — `llm_embed(m, x, pooling = c("mean","last","model"), normalize = TRUE)`**
  → base `matrix`, `length(x)` rows × `n_embd` cols, rownames = `names(x)` or
  `seq_along(x)`. Errors: `relm_error_embed`. **This is the last Phase-1 WP.**
  API-GRAMMAR §3 is approved. **Resolve one design decision first (architect ADR):**
  embeddings require the context in embeddings mode and `pooling_type` is fixed at
  context *creation* (it shapes the graph), but `llm_embed`'s `pooling` is
  per-call. Decide the context strategy — reuse the generation context via
  `llama_set_embeddings(ctx,true)` with pooling NONE and do mean/last pooling in
  Rust over per-token `llama_get_embeddings_ith`, versus a dedicated embedding
  context created with the model's pooling for `pooling = "model"`
  (`llama_get_embeddings_seq`). The b9726 API is confirmed present:
  `llama_pooling_type` enum, cparams `.pooling_type`/`.embeddings`,
  `llama_set_embeddings`, `llama_get_embeddings_ith/_seq`. Implement with a
  synthetic embeddings golden (numpy, like WP6a) + [MODEL] tests. `normalize` = L2
  in Rust.
- After WP3, **Phase 1 closes.** Then **Phase 2** = `llm_trace` / `llm_steer` /
  `llm_ablate` / `llm_logits` — the interpretability core, the project's real white
  space (see API-GRAMMAR §4 and ROADMAP).
- Milestones: **v0.1.0** at the end of Phase 3; **v1.0** at the end of Phase 9
  (CRAN + API freeze).
- **Scope discipline (D-010, 2026-07-06):** `v1.0` stays the *lean* core
  (interpretability + embeddings + topics + probe + serving). Fine-tuning
  (Phase 12), alignment/RL (Phase 13), topics+SAE (Phase 14) and `relm.bio`
  (Phase 18) are solo but sequenced **after** `v1.0` — do not pull them forward.
  The one early taste is the *optional* "Demo C" protein-LM mini in WP7 (Phase 3):
  ship it only if a BERT-class sequence encoder loads cleanly; it never gates a
  release, and full ESM-2 support is deliberately deferred to the Phase-18 arch ADR.

## 4. Repo layout (folders)

- `rebirth/` — the R package.
  - `R/` — R code: `llm.R`, `tokens.R`, `generate.R`, `conditions.R`,
    `extendr-wrappers.R` (generated by `rextendr::document`).
  - `src/rust/` — Cargo workspace: `rebirth-ffi/` (the extendr boundary, `[lib]
    name = "relm"`, the *only* crate that speaks R) and `rebirth-llm/` (the
    R-free engine: `ffi.rs` hand-written `extern "C"`, `engine.rs`, `generate.rs`,
    `error.rs`).
  - `src/llama.cpp/` — vendored engine (b9726, pruned). **Do not edit** except via
    the `vendor-bump` skill.
  - `tests/testthat/` — R tests; `fixtures/synthetic-llama-2l.gguf` is the in-repo
    test model.
  - `man/`, `NAMESPACE`, `NEWS.md`, `DESCRIPTION`.
- `tests/llm-golden/synthetic/` — the numpy oracle + goldens (Harness B).
- Root docs: `CLAUDE.md`, `SOLO-PHASE-PLAN.md`, `ROADMAP.md`, `API-GRAMMAR.md`,
  `ARCHITECTURE.md`, `DECISIONS.md`, `THESIS-PLAN.md`, `AGENTS.md`.
- `.claude/agents/` — subagent definitions. `.claude/skills/` — `new-wp`,
  `golden-update`, `vendor-bump`, `release`.
- `graphify-out/` — the knowledge graph (`graph.json`, `graph.html`,
  `GRAPH_REPORT.md`).

## 5. Agents — which to launch, and the workflow

Start every WP with the **`new-wp`** skill (it enforces: branch off up-to-date
`main`, the spec-gate check, and TDD/golden-first order). Then use:

| Agent | When |
|---|---|
| **architect** | a WP needs a breakdown or an ADR-sized decision (e.g. the WP3 embedding-context choice). Plans/ADRs only, no product code. |
| **coder** | implement the current WP (the workhorse; follows ROADMAP §5 prompts). |
| **test-engineer** | goldens, fixtures, Harness B; before merging any numerical code. |
| **reviewer** | after each WP implementation, before the founder's review (read-only). |
| **simplifier** | mandatory at each phase end and after any WP adding > ~500 lines. |
| **security-auditor** | phase boundaries touching the FFI/unsafe boundary, file parsing, downloads, or the serve module. |
| **doc-writer** | after a WP passes acceptance and before releases. |

Pre-merge gate: **reviewer → (security-auditor if the boundary/unsafe/parsing was
touched) → simplifier (if > ~500 lines) → fix all findings → merge → sync `main`.**
You perform the merges yourself. On the 20x plan you can run several subagents in
parallel — dispatch reviewer + test-engineer together, for instance.

**To change the code-writing model:** edit the `model:` field in each agent's
frontmatter, `.claude/agents/<agent>.md` (e.g. set `model: opus` on `coder`,
`architect`, and `reviewer`).

## 6. graphify — refresh periodically, query to save tokens

The repo carries a graphify knowledge graph. **Before opening many source files to
answer a "how does X work" or "what calls Y" question, query the graph** — it
returns the relevant nodes and their source locations without loading every file:

- `graphify query "how does generation decode the prompt"` — BFS traversal.
- `graphify path "llm_generate" "llama_decode"` — how two things connect.
- `graphify explain "RebirthError"` — a plain-language description of a node.

**Refreshing the graph — read this caveat first (learned 2026-07-06):** a bare
`graphify update .` (or a full `graphify .`) on this repo **re-ingests the vendored
`rebirth/src/llama.cpp/` tree** — it exploded the curated 13-community, ~300 KB
code graph into ~10 k nodes / 509 communities dominated by ggml/llama C++, which
swamps our code and makes queries noisy. The curated graph deliberately excludes
that vendored tree. **Before refreshing:** graphify auto-backs-up the prior graph
to `graphify-out/<date>/` (5 files: `graph.json`, `GRAPH_REPORT.md`,
`manifest.json`, `.graphify_labels.json`, `cost.json`) — so if a run pollutes,
restore those five and you are back to the clean state. Do the sanctioned refresh
via the **graphify skill** (it handles the narrowing/exclusion step); do not just
point it at the repo root. As of 2026-07-06 the graph is already current — it was
rebuilt after the last merged WP, so a refresh was only needed once new code lands.

The current graph is **code-only** (the Rust engine + the Python goldens, via AST).
It deliberately excludes the vendored llama.cpp (not our code), and it does **not**
yet include the R functions or the planning docs — graphify has no R AST, and the
document semantic pass needs parallel subagents. To **enrich it with R + docs**
(the vision→plan→architecture→decisions web plus the R API surface), run the
semantic extraction: parallel `general-purpose` subagents over the `rebirth/R/*.R`
files and the core root `.md` docs, following the graphify skill's Part B. Do that
in a session with budget to spare — on the 20x plan this is now cheap.

## 7. Environment, verification, and hard-won lessons

- Test model: `~/models/qwen2.5-0.5b-instruct-q8_0.gguf`; gate real-model
  ("[MODEL]") tests on env `RELM_TEST_MODEL_QWEN`, which skip in CI/CRAN. The
  build needs `cmake`.
- Verify before "done": `cargo fmt --all --check`; `cargo clippy -p rebirth-llm -p
  rebirth-ffi --all-targets -- -D warnings`; `cargo test -p rebirth-llm`;
  `devtools::test("rebirth")`; `R CMD check`. CI runs all of it cross-platform.
- Lessons already paid for (don't relearn them):
  - **Decode prompts in `n_batch`-sized chunks.** One oversized batch trips
    `GGML_ASSERT(n_tokens_all <= n_batch)` and aborts the whole process; llama can
    set `n_batch` well below `n_ctx`. `generate()` already chunks — mirror this in
    any new decode path (e.g. `logits_for_tokens` when `llm_logits` lands).
  - Roxygen markdown **auto-links a backtick `func()` even to an undocumented
    topic** → only cross-reference topics that already exist, or you get a "Missing
    link" WARNING that `error-on = warning` turns into a CI failure.
  - Set `CMAKE_OSX_DEPLOYMENT_TARGET` from `MACOSX_DEPLOYMENT_TARGET` (else "object
    built for newer macOS" warnings fail CI).
  - Propagate static archives across crates with
    `cargo:rustc-link-lib=static:+whole-archive,-bundle` (`rustc-link-arg` does not
    propagate).
- Session hygiene before ending: report true state; any decision → `DECISIONS.md`;
  any user-visible change → `NEWS.md`; any durable project fact → `CLAUDE.md`.

Now read `CLAUDE.md` and `ROADMAP.md`, then start WP3 with the `new-wp` skill: the
architect drafts the embedding-context ADR first, then the coder implements.
