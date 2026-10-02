# WP9 — Native asynchronous generation

Updated: 2026-10-02. **Implementation and operational acceptance complete;
foreground RStudio and all nine checks at `8053bf8` passed. Final evidence-head
CI and integration remain open.** D-037 is
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
| R responsiveness fixture | A controlled two-second worker verifies prompt return and independent event-loop heartbeats. This is automated R event-loop evidence; the separate foreground result is recorded below. |
| Foreground RStudio | Actual cached-Qwen CPU generation lasted 17.788 s; submission took 105 ms. An independently submitted `1 + 1` returned 2 while generation was active, below 500 ms at the R clock resolution, with 322 independent heartbeats. Session/model/backend hashes and restoration receipts are retained. |
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

## PR CI: separate cold model setup from lifecycle execution

At `1bd29c07c9170d112ab1735bd33b625c9eb4fc6a`, seven of nine checks passed:
all five Rust/structural checks and both Linux R jobs, including Rust 1.85.0.
Both macOS R jobs failed the fresh-process synthetic-model close/GC test because
its child exceeded the unchanged 30-second deadline. macOS release recorded
2 failed expectations, 1 warning, 66 skips and 2,475 passes. macOS oldrel also
failed to settle the responsiveness fixture within ten seconds, followed by busy
conditions in subsequent tests (80 failures, 1 warning, 66 skips, 947 passes).
The pending job plausibly explains the later busy cascade; the reason for the
original stalls is **not yet established**.

The initial child log had no intermediate progress, so it could not distinguish
slow setup, deferred destruction or event-loop delivery. The next candidate adds
elapsed/CPU timestamps before and after each child expression, retains the child
script/log on failure, and reports native worker/terminal counters when promise
waiting expires. It changes no product code, timeout or acceptance assertion.
The two affected test files pass locally against the same installed library:
32 cases, 1,313 expectations, four explicit model skips, no failures.

Raw failed CI logs/check results and the local diagnostic-harness verification
are preserved in [the CI measurement directory](../tests/async/measurements/ci-2026-10-02/).
The diagnostic candidate `c8c7cff` again passed seven checks and failed both Mac
jobs, but identified the stalled phase: the first synchronous `llm(...,
backend = "cpu")`, before any async worker or deferred destruction exists. On
oldrel it returned after 37.561 seconds of elapsed time and about 0.135 seconds
of CPU time; the outer 30-second watchdog had already expired. The underlying
native/OS initialization wait is not diagnosed further. The earlier oldrel
responsiveness timeout did not recur under unchanged limits; its exact cause
remains unproven.

Only the real-model lifecycle fixture now separates preparation from execution:
90 seconds for fresh-process namespace/model setup, then the original 30 seconds
for lifecycle work, with the original ten-second promise-draining deadline.
Each phase checks its elapsed budget explicitly; the outer process watchdog is
their 120-second sum, bounding native calls that cannot be interrupted immediately.
Other subprocess tests retain their original total deadlines. Model setup is
still required and bounded; it is not a skipped acceptance gate. Product code,
worker behavior and all ownership assertions are unchanged. The two affected
test files pass locally against the existing binary (1,313 expectations, four
explicit model skips). All nine checks then passed on exact head
`8053bf83d6723dc30d9fee1ad8bf49446491d289`: [R matrix](https://github.com/Vadale/R-ebirth/actions/runs/36937676493)
and [Rust/structural checks](https://github.com/Vadale/R-ebirth/actions/runs/36937676492).
Both Mac versions confirmed the separated preparation/lifecycle budgets. This
does not establish the cause of the original native/OS initialization delay or
the isolated responsiveness outlier.

## Foreground RStudio acceptance

The [RStudio evidence](../tests/async/measurements/rstudio-2026-10-02/) records an
actual foreground console run on R 4.5.1 / RStudio 2025.9.1.401, using the existing
verified WP9 installation and cached Qwen 0.5B on CPU. Four seeded prompts ran
for 17.788 seconds. The promise returned after 105 ms, and an independently
submitted console probe returned 2 while generation remained active. Its R
expression elapsed time was below clock resolution (recorded as 0 s), below
the 500 ms gate; this excludes UI automation transport latency. There were 322
independent 50 ms heartbeat callbacks. The result retained seed 17.

The session had just started with only RStudio's hidden `.Random.seed` global.
The initial setup preflight rejected that hidden seed before loading relm; the
corrected preflight retained it for exact restoration. A separately launched
project could not be selected by the UI controller, so the fresh, otherwise
empty existing foreground console was used. The founder's editor documents
were preserved. Original globals, seed, library paths and search path were
restored after completion. The namespace/DLL remain mapped for safe finalization.
No background RStudio job, repeated package build or model download substituted
for this gate. Post-run hashes confirm all 55 recorded runtime inputs still
match the earlier verified installation's source manifest.

## Remaining integration

- Require all nine checks on the final evidence/documentation commit. The green
  product-source checks above do not automatically certify a later commit.
- Integrate the separate skill/planning PR #53 only after its pending explicit
  merge authorization; preserve D-037 approval when combining planning changes.
- Merge WP9 only after final checks and applicable founder merge authorization.

WP10 token streaming, I1 external-assistant integration and a release remain
outside this work package. No claim of new extraction accuracy or CRAN readiness
is made by this implementation.
