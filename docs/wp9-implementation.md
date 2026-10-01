# WP9 — Native asynchronous generation

Date: 2026-10-01. **Implementation and local automated verification complete;
foreground RStudio acceptance and final PR CI remain pending.** D-037 is
approved. This development change follows relm 0.3.0; it is not a new release.
The [approved contract](wp9-async-plan.md) and API-GRAMMAR remain binding.

**Acceptance (roadmap):** long generation never blocks RStudio; async result
equals seeded sync result. The automated event-loop and parity checks below
cover part of that obligation. They do not substitute for an actual foreground
RStudio session.

## Behavior

`llm_generate(m, prompt, async = TRUE, on_progress = callback)` returns a standard
`promises` promise immediately after validation/submission. A Rust worker uses
the already loaded model and context. The promise resolves to the existing named
character vector with its seed attribute; synchronous calls retain their existing
behavior. `later` and `promises` are optional and required only for async use.

`llm_cancel(m)` requests cooperative cancellation. The handle becomes reusable
after native completion. Closing a busy handle marks it closed immediately and
releases its native resources after work finishes. Progress callbacks receive a
coalesced one-row data frame on R's main thread. They are neither token streaming
nor a record of every native event. Callback failures reject with the original
condition preserved as `parent`.

Only one native operation owns the process-wide execution permit at a time;
there is no job queue. Other R computations remain available, while competing
native operations fail with a classed busy condition. No R object, callback or
R RNG access occurs on the worker. Namespace shutdown joins native work and
releases resources but retains the DLL for surviving extendr finalizers. Forced
DLL unmapping with live pointers is unsupported and unverified.

Admission and output bounds are defined in the contract. The 8 MiB output-text
limit is not an RSS limit. Tests separately account for retained descriptors,
input copies, token buffers, conversion buffers and materialized R objects;
model/context, vision and allocator memory remain outside that scoped estimate.
The delivered D-034 service still supplies process isolation and durable recovery.

## Automated evidence

Local host: Mac mini M4, macOS arm64, R 4.5.1. Cached Qwen0.5 and Qwen2-VL model/
projector files were reused; no model was downloaded. The local testthat package
emits a built-under-R-4.5.2 warning, retained in the raw log.

| Gate | Actual result and scope |
|---|---|
| Native ownership and numerical behavior | Workspace clippy, debug/release async tests, the full default engine/golden suite and FFI tests passed. Existing goldens were unchanged. Ownership assertions also execute in optimized builds. |
| Native vision boundaries | Six real cached-VLM cases passed with `ASYNC_VLM_BOUNDARIES_PASSED`: cancellation/recovery and terminal-owner destruction around multimodal ingest and sampled-token boundaries, including a surviving shared projector. These are boundaries around synchronous C calls, not interruption inside the image encoder. |
| R promises, lifecycle and memory | 35 cases, 1,355 passing expectations, zero failures/errors/skips. Includes seeded sync/async parity, structured/intervened and vision paths, callback errors/reentrancy, one seed draw, cancellation, real deferred destruction, fresh-process shutdown, foreign-pointer refusal and full-size materialized result bounds. |
| R responsiveness fixture | A controlled two-second worker verifies prompt return and independent event-loop heartbeats. This is automated R event-loop evidence, not the pending real RStudio gate. |
| Remaining package tests | 251 cases: 1,177 passing expectations, 48 explicit skips, zero failures/errors. The skipped cases require opt-in models, network or other environment conditions; see the retained log. Async cases were excluded because the preceding suite had already executed them. |
| Package integration | Fresh installation and source build passed. The scoped check ran examples, R analysis, help and namespace checks with zero errors and two warnings about absent rendered vignettes. It deliberately used `--no-install --no-tests --no-vignettes --no-manual`; the PR matrix retains full package/vignette checks. This is not a clean CRAN check. |
| Formatting and review | Final workspace formatting and explicit included-FFI formatting passed. One integrated independent review completed; its missing checkpoint, real-resource and memory acceptance cases were added and executed. No repeated broad review was needed. |

The [measurement directory](../tests/async/measurements/macos-arm64-2026-10-01/)
contains stage receipts, raw logs, per-case counts, scripts, session information,
source hashes and checksums. Scripts there describe this machine's executed
commands; the portable regressions live in the package/Rust test suites.

The source manifest was captured **after** verification. It byte-matches 132
final package inputs to the integration source archive; DESCRIPTION fields agree
after DCF whitespace normalization, with the usual build-added metadata recorded.
It is not a pre-run snapshot. The initial full Rust suite preceded the additive
`cfg(test)` VLM checkpoint instrumentation; the later clippy and targeted real-VLM
run cover that addition. The only later runtime correction was in R settlement,
followed by fresh installation and the complete R async suite. Earlier failed
executions are not relabelled with final-source hashes.

## Retained failures and correction

The first native compilation found an ambiguous FFI tuple type; an explicit
`(&str, Robj, Robj)` annotation fixed it. The initial installed R suite then failed:
its final progress-callback error was lost during settlement, and five Metal
contexts could not initialize inside the command sandbox.

The callback failure was a real defect: R's lazy `error` argument referred to
`job$callback_error`, which cleanup cleared before evaluation. Settlement now
forces `value` and `error` before clearing roots. The regression verifies both
the class and the original parent message. Metal was diagnosed separately:
the same installed binary and tiny model failed to create a command queue in
the sandbox and loaded successfully with GPU access. The corrected suite ran
with that access; no Metal case was replaced with CPU to hide a failure.

The raw failed compiler/R results remain in the measurement directory. The
successful rerun neither erases them nor changes any numerical tolerance.

## Remaining acceptance and integration

- Run the prepared foreground RStudio check in a separate fresh session after
  the founder unlocks the Mac, preserving the existing workspace. Record a real
  generation lasting at least five seconds, an independent `1 + 1` response below
  500 ms while generation is active, and at least ten event-loop heartbeats.
- Require all nine checks on the final PR commit, including the Mac/Linux R
  matrix, Rust default/no-spill checks and existing goldens. A workflow definition
  is not a passing result.
- Integrate the separate skill/planning PR #53 only after its pending explicit
  merge authorization; preserve D-037 approval when combining planning changes.

WP10 token streaming, I1 external-assistant integration and a release remain
outside this work package. No claim of new extraction accuracy or CRAN readiness
is made by this implementation.
