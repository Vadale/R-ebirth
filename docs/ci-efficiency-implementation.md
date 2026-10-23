# CI efficiency refinement

The original 2026-10-03 report is retained below as historical evidence. The
[current PR-check audit](#pr-check-audit-and-platform-deferral-2026-10-23) records
the subsequent platform priority and verification scope.

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


## PR-check audit and platform deferral (2026-10-23)

Scope: all three workflows triggered by `pull_request`, their expanded jobs,
explicit commands, and the current run's step metadata. This is an orchestration
and targeted redundancy audit, not a claim that every individual package/Rust
assertion has been proved minimal. No model, accepted native suite or historical
nightly was rerun for this audit. The owner performed the analysis and protection
review; those passes are not independent reviews.

### Current support priority

The founder deferred Windows ARM64 and WebAssembly. Remove those two automatic
jobs and retain the twelve existing desktop routes. Do not replace a failure
with `continue-on-error`, weaken an assertion, or call a skipped/retired platform
accepted. Windows x86_64 remains required, including its current source-verifier
correction. Linux ARM64/macOS ARM64 are not Windows ARM64 and are not retired by
this decision. The ordinary matrix does not by itself test every published binary.

The historical experimental workflow is recoverable at
[commit f2eb537](https://github.com/Vadale/R-ebirth/blob/f2eb537a948b4b4744ec5dee022cf75f241fd2fb/.github/workflows/cran-portability.yaml).
It records `windows-11-arm`/Rtools Clang and the immutable rwasm image plus the
SHA-256-pinned webR Node frontend. Existing target configuration, wrapper helpers
and focused target fixtures remain in the repository; they are not new active
platform commitments. The observed Wasm job status on that commit is successful,
but this audit did not independently accept its payload/runtime or browser
inference. Its status does not make stock r-universe builders supported: the
explicit `RELM_WEBR_RUNTIME` Node frontend prerequisite still applies. Resume
these targets only with a new product priority and platform-specific acceptance.

### Complete route disposition

| Route | Distinct protection | Disposition |
| --- | --- | --- |
| Linux/macOS × R release/oldrel (4) | Real R C API/version, FFI, package tests/examples/vignettes and OS process behavior; Linux oldrel also uses Rust 1.85 | Retain all four. R-version and platform coverage are not identical executions. |
| Rust engine (1) | R-free crate, ordinary/no-spill feature branches, release async ownership, compiler lints and native boundary controls | Retain. Debug/release and spill/no-spill exercise different paths. |
| Golden/security tooling (1) | Independent references, provenance/corruption refusals and actual patched Python/HF environment | Retain. Testing the reference, checking retained bytes and comparing product results are different protections. |
| Vendored engine integrity (1) | Exact committed source and reverse-patch coherence | Retain. This is not the packaged archive/offline-source check. |
| Deterministic supply chain (1) | Dependency license/source/ban policy | Retain. Small, and distinct from advisory discovery/nightlies. |
| Intel-mac cross-link (1) | x86_64 architecture and link libraries on an ARM runner | Retain. Native Mac package jobs do not cover Intel linking. |
| Windows x86_64 production package (1) | Actual Rtools/GCC, newline/path behavior, default package surface | Retain. The current failed newline verifier demonstrates why Linux mocks are insufficient. |
| R-devel production package/manual (1) | Forward R compatibility, no selftest hooks, source archive, PDF/HTML/manual | Retain. Ordinary release-R selftest builds do not replace it. |
| R without a shared library (1) | Actual production installation without linking/mapping libR.so | Retain. Normal Linux R provides a different linking environment. |
| Windows ARM64 + rwasm (2 former routes) | Additional experimental architectures/runtime | Deferred by explicit product-priority decision; former successes/failures retain their scopes. |

### Removed repetition: old case to surviving protection

| Previous invocation | Protected behavior | Surviving execution |
| --- | --- | --- |
| Standalone `source("tests/demos/demo-utils.R")` followed later by Demo B sourcing, on each R cell | 41 hand-computed numeric identities | Demo B unconditionally sources the same file before its B1-B4 plot checks. The combined command explicitly clears `RELM_DEMO_SKIP_SELFTEST`; all assertions and all four platform/R cells remain. Eight helper invocations become four, with the plot checks retained. |
| `python3 tests/docs/check.py` before build on each of four R cells | Public example/source-file/link/privacy assertions over identical checkout bytes | One pre-build Linux-release invocation; the generated-site invocation still checks rendered pages/scripts/anchors. The R-based API/formals inventory remains on all four R cells. Four source-only invocations become one. |

No product test body or test fixture is removed. A focused corrupted numeric
identity must still fail through the combined Demo B route; normal numeric and
plot checks must both execute. Workflow comparison must show the same twelve
retained route identities, events and unaffected command bodies.

### Reviewed candidates deliberately retained

- **Source bundle and extendr corruption checks:** real archive checks and
  injected corruption cases are different. Host newline and path behavior
  matters; retain the Windows source check and native R lookup/unwind controls.
- **CPU backend isolation:** the Linux engine suite and R matrix overlap, but
  the latter includes Metal-capable Mac and Rust-minimum environments. No further
  removal without a feature/build-environment equivalence case.
- **Application service and interruption tests:** repeated across R/OS cells,
  but cover process death, filesystem persistence and library compatibility.
  High cost alone does not prove semantic duplication. Retain all assertions,
  timeouts and per-platform execution in this change.
- **Service contract labelled “planning only”:** the live application still reads
  `tests/service-contract/contract.json`; the verifier checks limits, ownership,
  dependency provenance and corruption refusals. Keep it and clarify the CI label.
  Frozen planning statuses inside that artifact are not current runtime results.
- **Documentation-only routing:** already fail-closed for allowlisted external
  docs in the R/native workflows. Portability still runs fully. Extending routing
  to production packaging is a separate possible optimization, not silently
  introduced here while repairing a packaging failure.

### Cost evidence and limits

Current [R job metadata](https://github.com/Vadale/R-ebirth/actions/runs/39945990797)
shows completed package-check steps of 401–623 seconds across the four cells;
the completed Linux-oldrel service step takes 244 seconds. In the current
[portability run](https://github.com/Vadale/R-ebirth/actions/runs/39945990848),
R-devel setup alone takes 872 seconds and non-shared R installation 496 seconds.
These observations include running/failed jobs and are timing evidence only,
not final candidate acceptance. The [Rust run](https://github.com/Vadale/R-ebirth/actions/runs/39945990795)
shows 9/10-second vendor/supply-chain jobs, 69-second golden/security tooling,
113-second Intel-mac link and a 226-second engine job.

Thus the duplicate short source/demo checks are not the dominant delay. The
main avoidable operational cost is repeated full matrices after small pushes;
prepare and verify related corrections together. Jobs overlap, so summing these
seconds does not estimate user wait time, billed cost or the new critical path.
No before/after speedup or external-user adoption percentage is claimed. More
aggressive removals need concrete missing/redundant-path evidence, not test age.
