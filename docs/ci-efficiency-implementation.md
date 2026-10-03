# CI efficiency refinement

Date: 2026-10-03. Local verification and one independent review are complete;
remote verification of this candidate is pending. No package runtime, approved
API, dependency, vendor code, model pin or numerical tolerance changes.

## Baseline and reason

Maintenance PR57 was merged into `main` at
`daee903f8bca53715b658fae148828d769f45081`. Its tree exactly matches accepted
`d0ff6f1682ae08a7f726d4067a5945a8c953ffb7`. The accepted sanitizer and Linux/Mac
vision evidence retain their individual source scopes and historical failures.
This follow-up neither reruns nor relabels those results.

The successful Mac vision run [37119814132](https://github.com/Vadale/R-ebirth/actions/runs/37119814132)
took about 41 minutes. The combined R vision/async step consumed 21.32 minutes,
candidate installation 4.03, model download 0.52, pristine reference 2.07,
native async/VLM boundaries 5.57 and engine goldens 4.60. The old filter repeated
generic async tests already covered by the four ordinary R legs. Job-level
timing does not identify the slowest individual test; real VLM inference remains
substantial work. No new end-to-end speedup has yet been measured.

## Changes

- **Conservative documentation routing:** compare verified event commits and
  complete changed-file sets. Only explicitly allowlisted external Markdown can
  avoid R/native builds. Every uncertain or non-allowlisted change runs fully.
  Nine check names remain stable; three lightweight golden/contract, vendor and
  supply-chain jobs always execute. Each routed job explains applicability.
- **Separate shared helpers and actual vision coverage:** move three async
  helpers to `helper-async.R` and the existing async/VLM case to
  `test-llm-vision-async.R`, without changing any expression or assertion.
  Ordinary R CI still discovers all files; optional models remain explicit skips.
- **Fail earlier:** the installed-package lifecycle preflight executes before
  model download. The later model phase selects vision cases and requires four
  named actual-model results, including async equality and over-batch prefill.
  Existing native vision gates and reference binding stay intact.
- **Measure individual work:** save per-test elapsed/CPU time, counts, skips,
  failures, session and source scope before enforcing the phase result. A failed
  phase cannot become accepted merely because it wrote an artifact.

The routing candidate itself changes workflow and test code, so it must run the
full ordinary matrix. No heavy job is launched just to benchmark unchanged
model bodies. Runtime acceptance from PR57 remains parent-source evidence;
these changes do not claim that the revised nightly has already run remotely.

## Verification and limits

Local receipts are in `tests/ci/evidence/2026-10-03/`:

| Check | Result and scope |
|---|---|
| Routing controls | 15 Python tests passed, including actual push/PR Git histories, shallow/missing baselines, merge-parent mismatch, renames, deletion, malformed events, newline and invalid-UTF8 paths. |
| Workflow structure | Parsed R/Rust/vision YAML; job identities/triggers unchanged; routed steps guarded; all eight vision shell blocks pass `bash -n`. `actionlint` was unavailable and was not installed. |
| Test relocation | All 27 original top-level R expressions occur exactly once across the three resulting files. No model rerun was used to establish this equivalence. |
| Vision runner controls | 23 base-R checks passed: required names/selection, missing/duplicate/skipped gates, failures/errors, empty or incomplete results, and invalid phase. A missing model was separately rejected before suite execution. |
| Installed preflight | 24 passing expectations, one explicit missing-Qwen skip, zero failures; all three mandatory lifecycle cases executed. |
| Focused async discovery | 24 cases, 1,292 passing expectations, three explicit missing-model skips, zero failures. |
| Review | One independent combined review found no material blocker; no runtime or assertion weakening found. |

The installed tests reused the already verified D040 library; no native rebuild,
model download or repeated model acceptance occurred. Local R was 4.5.1; the
testthat-built-under-4.5.2 warning is retained. The initial runner-control filename
fixture incorrectly retained `.R` while testthat strips it; the fixture was
corrected. The first classifier invalid-UTF8 fixture was also corrected to build
the Git tree directly. These were local test-fixture failures, not runtime fixes.

The historical Mac lifecycle timeout remains of unknown cause. Moving the
preflight earlier makes a future failure cheaper and better diagnosed; it does
not establish or fix that cause. This refinement provides neither a broad
changed-code dependency solver nor reuse of machine-specific float references.

## Next milestone

The next feature is Phase 6. Its concrete F6a proposal is
[live introspection](phase6-live-introspection-plan.md): observe selected model
state during generation and cancel at an explicit boundary. The proposal keeps
WP10 `on_token` unchanged and reserves live coefficient updates for F6b. It is
not an approved API amendment or implemented capability. Phase 7 follows;
hardware expansion and CRAN retain their later scope.
