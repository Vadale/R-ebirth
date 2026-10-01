# WP9 — Native asynchronous generation proposal

Date: 2026-10-01. Decision: D-037. **Status: proposed; founder approval required before product
implementation.** This document is an option analysis and executable work plan,
not an approved API amendment or evidence that asynchronous generation works.
The baseline is relm 0.3.0, main `82fcf134` (the release receipt in `CLAUDE.md`
remains authoritative for the full SHA).

## 1. Recommended decision

Implement WP9 as native Rust background generation on the already loaded model,
with R-side `later` scheduling and a standard `promises` result. Start with **one
active native inference job per R process and no queue**. Other R computations
remain available. A competing native model operation fails promptly with a
classed busy condition. This is concurrency between R and inference, not parallel
inference across models.

Approve the exact API in section 3, optional dependencies and their scoped
transitive exception in section 4, and the native ownership/lifecycle amendment
in section 5. These are one proposed WP9 decision; the owner records its ADR ID
and copies approved entries into `API-GRAMMAR.md` before implementation.

The existing D-034 service remains the choice for process isolation, durable
tickets, deadlines and restart recovery. WP9 adds no server, request queue,
authentication, persistent job store or replacement service worker.

## 2. Options and source findings

| Option | Cost and consequence | Recommendation |
|---|---|---|
| Native worker plus R event loop | Reuses the current model/context and intervention state; requires a real ownership transfer, cooperative cancellation and safe finalization. Native process crashes remain process crashes. | **Choose for WP9.** This implements the roadmap's local interactive contract and supplies WP10's engine hook. |
| Existing process tools (`callr` or `mirai`) | A child must load its own model from paths/configuration; an external pointer cannot be transferred. Keeping both parent and child models resident adds memory, startup and state-reconstruction costs. Hard child termination is a useful isolation feature. | Retain the delivered callr service for this need; do not introduce a second process-worker framework into core generation. |
| Permanent native actor owning every model from load to close | Clear fixed-thread resource ownership, but all existing load/token/embed/trace/intervention/generation operations need dispatch and marshalling through it. | Defer the broad rewrite. Reconsider only if the bounded ownership-transfer gate fails. |

Focused source inspection confirms the critical constraints:

- `rebirth/src/rust/rebirth-ffi/src/lib.rs`: `LlmHandle` contains
  `RefCell<Option<LoadedModel>>`; `with_model()` assumes the R thread and
  constructs R payloads there. Sending this wrapper to a worker is incorrect.
- `rebirth/src/rust/rebirth-llm/src/engine.rs`: `LoadedModel` owns one `Context`;
  the context shares `Arc<Model>` with derived intervention handles. `Model`
  and `Context` currently assert creator-thread access/destruction and have
  asserted `Send`/`Sync` implementations. Those assertions are a predecessor to
  WP9, not a nuisance to remove. Backend initialization/free is process-global.
- `rebirth/src/rust/rebirth-llm/src/vision.rs`: one mutable projector context is
  shared through `Model`, including derived handles. Distinct context pointers
  therefore do not establish independent thread safety.
- `rebirth/src/rust/rebirth-llm/src/generate.rs`: prompt ingestion has a shared
  `n_batch`-chunked path; ordinary, constrained and vision continuations share
  the sampler loop. Extend these paths rather than create an async sampler.
- `rebirth/R/generate.R`: R draws an omitted seed once per call and reuses it
  for each prompt. Async submission must preserve that behavior and the result's
  names/seed attribute. Structured output remains all-or-error for the vector.

The curated graph was queried for `generate model context handle decode sampler
loaded vision`; relevant locations were confirmed in source. Its R/docs/vendor
exclusions prevent using it as a complete dependency or threading proof.

`later` runs callbacks on R's event loop; scheduled callbacks normally wait for
the top-level prompt or an explicit `run_now()`. Its native scheduling interface
is available but would require `Imports` and `LinkingTo`. WP9 instead uses its
R interface, avoiding a new native package ABI and C++ shim. This choice is an
engineering tradeoff, not a claim that polling is the only integration route.
See [later's official documentation](https://github.com/r-lib/later).

The promises constructor must return quickly and route asynchronous failures to
`reject()`. Merely wrapping synchronous generation in `promise()` or
`later()` would still block R. See the
[promise constructor contract](https://rstudio.github.io/promises/reference/promise.html).
Process alternatives are supported by
[callr's persistent-session interface](https://callr.r-lib.org/reference/r_session.html);
[mirai cancellation](https://mirai.r-lib.org/reference/stop_mirai.html) explicitly
does not guarantee interruption of compiled code.

## 3. Proposed API amendment

```r
llm_generate(m, prompt, max_tokens = 256, temperature = 0.8, top_p = 0.95,
             seed = NULL, chat = TRUE, stop = NULL, images = NULL,
             schema = NULL, async = FALSE, on_progress = NULL)

llm_cancel(m)
```

`async = FALSE` retains the current synchronous return and behavior.
`async` must be one nonmissing logical. `on_progress` must be `NULL` or a
function; a non-NULL callback requires `async = TRUE` in WP9. Do not add a second
generation function, a job class, a custom await function or `on_token` here.

With `async = TRUE`, return an ordinary `promises` promise. Amend the global
base-return rule explicitly for this pending computation object; its resolved
value remains a base-R result. It resolves to the
same named character vector, with the same `seed` attribute, that synchronous
generation produces for the admitted input. Chat templates, interventions,
stop sequences, structured-output validation and image handling keep their
existing semantics. A vector is one job: prompts execute in input order and no
partial vector is presented as a successful result.

R-side type/range/dependency/closed/busy checks fail synchronously before
submission. Native execution errors reject the returned promise with the
existing class and structured fields. An omitted seed is drawn on R's thread
once, after admission checks; completion order never drives R's RNG. No R RNG,
callback, allocation, condition construction or SEXP access occurs on a worker.

`on_progress(state)` receives a fresh one-row base `data.frame`, with columns in
this exact order:

| Column | Type | Contract |
|---|---|---|
| `prompt_id` | integer | Current 1-based prompt index. |
| `prompts_completed` | integer | Fully completed prompts, from 0 to the input length. |
| `prompts_total` | integer | Input length. |
| `generated_tokens` | integer | Sampled non-EOG tokens in the current prompt; may include a stop-string suffix removed from final text. |
| `max_tokens` | integer | The requested per-prompt bound. |
| `phase` | character | `"prefill"`, `"generate"` or `"complete"`. |

Progress is a coalesced snapshot, not an event log, token stream or percentage.
Intermediate snapshots may be skipped; counters never regress within one prompt.
A successful job delivers one final `complete` snapshot before resolution when a
callback is present. The callback runs only on R's main thread, outside native
locks; its return value is ignored. A callback error stops further callbacks,
requests cancellation if still running, then rejects with
`relm_error_callback` carrying the original condition as `parent`. It must not
leave an unobserved running worker or an indefinitely pending promise. A callback
that blocks R can still block the UI; inference does not make arbitrary R code
concurrent.

`llm_cancel(m)` requests cancellation of the active async job submitted through
that exact handle and returns an invisible logical: `TRUE` only for the first
accepted request, `FALSE` when idle, already cancelling or native-terminal.
An invalid handle raises `relm_error_argument`; a closed handle raises
`relm_error_closed`. Cancelling a derived handle does not cancel its parent or
siblings. Cancellation leaves an open handle reusable after native completion;
it does not immediately free its model or return a successful partial result.

New conditions proposed for the grammar:

- `relm_error_busy`: native engine access while another operation owns the
  process-wide execution permit; includes `operation` and `reason`.
- `relm_error_cancelled`: accepted cancellation, with `reason`, `seed`,
  `prompt_id` and `generated_tokens`; no partial text attached.
- `relm_error_callback`: progress callback failure, with `parent`.

Missing optional packages use `relm_error_generation` with
`reason = "async_dependency"`, required package/version fields and an actionable
installation message. Native worker startup failure uses the same existing
class with `reason = "async_start"`. Caught internal failures use the existing
implemented `relm_error_internal`; add its missing explicit grammar-table row
while documenting the boundary rather than inventing another internal class.

**Bounded admission proposed for async only:** at most 128 prompts, 1 MiB of
UTF-8 prompt text per prompt, 16 MiB of copied text arguments in aggregate
(prompts, names, stop strings, schema and image paths), and 8,192 requested
tokens per prompt. Count/check bytes before native copying. Async holds at most
8 MiB of final UTF-8 output per call; enforce this during generation and stop
with `relm_error_oom` before exceeding it. This extends that condition's grammar
entry to async output budgets. Existing stricter structured-output bounds and
image decode/pixel limits still apply. Input limits raise `relm_error_argument`.
There is no truncation or implicit retry. These fixed limits make retained work
reviewable on the 16 GB target; expanding them is a later API decision. They do
not cap model/context memory or change synchronous limits.

## 4. Proposed dependencies

Add exactly these direct R entries to `Suggests`:

```text
later (>= 1.4.8),
promises (>= 1.5.0)
```

Use `requireNamespace()` with version checks only when async is requested.
Ordinary synchronous operation must work without either optional package.
Required async CI legs install both and fail if absent; tests must not silently
skip the whole feature because its optional packages were omitted by CI.
Add no Rust dependency, `LinkingTo`, Rcpp usage in relm, process framework,
public native routine or vendor patch. Rust standard threads, synchronization,
atomics and bounded channels suffice for this proposal.

Read-only inspection of the local R 4.5.1 installation found `later 1.4.8` and
`promises 1.5.0`. Their non-base recursive dependency closure currently contains:

| Package | Observed local version |
|---|---|
| cli | 3.6.6 |
| fastmap | 1.2.0 |
| later | 1.4.8 |
| lifecycle | 1.0.5 |
| magrittr | 2.0.4 |
| otel | 0.2.0 |
| promises | 1.5.0 |
| R6 | 2.6.1 |
| Rcpp | 1.1.0 |
| rlang | 1.2.0 |

These observations are not a package-wide lockfile or compatibility test.
The ADR must explicitly permit this optional transitive closure, including
rlang/lifecycle/magrittr, as a narrow exception to the no-tidyverse-dependency
rule. relm continues using base data structures and `|>` and does not call those
packages directly. A hard-import exception is not requested. The existing
application-only D-034 approval does not authorize these core package entries.

## 5. Native ownership and lifecycle contract

Implement one process-wide native execution domain, acquired without waiting.
It owns an exclusive execution permit. Every native model operation, including
load, tokenization, metadata access that reaches C, inference, interventions,
projector work and backend lifecycle, must be covered. Read-only R metadata
printing, cancellation and progress/result collection need no inference permit.
Calls that only manipulate ordinary R data remain available.

At submission, move the existing `LoadedModel` out of its R-thread wrapper into
an owned task payload. Mark that wrapper busy with a unique job identity. Keep
the R object and promise/callback closures rooted in an R-only job registry.
The worker receives owned Rust inputs, the model, execution permit and plain
control state. No borrowed R string or external-pointer wrapper crosses threads.
Reuse the context and weights; do not reload the GGUF or allocate a second
generation context merely to make async work.

The R-facing wrapper must be explicitly `!Send` and `!Sync`. Replace creator-
thread assumptions with an audited ownership-domain check that permits an
explicit main-thread-to-worker handoff and return. A permit records the active
thread and generation; stale or missing permits cannot reach raw pointers.
Enforcement must remain effective in release builds. `Context` needs exclusive
transfer, not concurrent `Sync`; remove that unnecessary guarantee. Shared
`Model`/projector access is safe only under the domain permit. Private raw access
and narrowly documented `Send`/`Sync` implementations must reflect this actual
restriction. Do not silence `assert_r_main_thread()` or replace it with a comment.
Inspect direct pointer uses as well as existing getters so no path bypasses the
permit. This supersedes only the native confinement mechanism in D-008 G2 and
`ARCHITECTURE.md` sections 3/10, never the R-main-thread invariant.

Use these logical states, with terminal publication and cancellation arbitration
under one short-held lock:

```text
idle -> running -> completed | failed | cancelled -> idle
              -> cancellation_requested ---------^
closed is terminal for the R handle, including while native cleanup is pending.
```

A cancellation accepted before terminal publication wins over a subsequently
computed successful result. A cancellation arriving after terminal publication
returns `FALSE`, even if R has not delivered the promise yet. Never settle twice.
Check cancellation before/after prompt-ingest chunks, between generated tokens,
between prompts, and around image preprocessing/encoding. A currently executing
native decode/encoder call may have to finish; do not claim a hard deadline or
attempt to kill a thread. Where an existing upstream abort callback can be used
without changing numerics, its use needs an ABI/behavior test; it is not assumed
in the base cancellation guarantee.

Successful/ordinary-error/cancelled tasks return their native ownership to R
before releasing the permit or admitting another job. Normal error/cancellation
must clear request-specific sampler/grammar/KV state through the existing reset
path. An unexpected worker panic rejects as `relm_error_internal` and closes the
affected handle after controlled teardown; do not reuse potentially poisoned
context state. Handle the panic hook as well as `catch_unwind`: a caught worker
panic must not print an unclassed raw panic to the console, and unrelated threads'
panic behavior must not be suppressed globally.

`close(m)` remains idempotent and returns `invisible(NULL)`. When `m` is busy it
marks the handle closed immediately and requests cancellation; native memory
is released after the worker finishes. Closing another model during a job marks
that handle closed and defers native destruction until the execution permit is
available. All GC finalization obeys the same rule, including sibling contexts
sharing a model/projector. This deferred-free exception must be included in the
approved `close.llm` entry. A pending job keeps its own handle alive; removing R
variables alone does not silently cancel computation. Teardown queues hold only
already existing resources; they cannot spawn jobs or increase native allocations.

On package unload/session shutdown, stop scheduling callbacks, request
cancellation, join the native worker, then free resources before DLL unload.
Shutdown may wait for an in-flight native call; this is outside interactive
submission latency. Never detach a thread that can execute an unloaded library,
call R after teardown, or claim safe forced termination. Upstream aborts/segfaults
are not catchable Rust errors; process isolation remains the service's benefit.

## 6. Event loop and bounded transport

One R-owned timer per active job checks native state at a 50 ms target interval
through `later::later()` on the global event loop. The check is nonblocking:
copy one progress snapshot and/or take a completed result, then return. R-side
collection uses a try-lock and reschedules on contention. Native mutexes protect
only short state copies/publication, never decode or R callbacks.
There is no timer when idle, no nested `run_now()` inside package callbacks, no
busy-wait and no R-thread `join()` before completion except controlled shutdown.
Document explicit event-loop pumping for noninteractive scripts; a long-running
R expression can delay callback delivery while native work continues.

Progress occupies one replaceable snapshot. Completion has its own single
terminal slot; cancellation has an independent atomic/control path. A stalled R
event loop therefore does not accumulate progress events or prevent worker
cancellation/completion. Release result/native task storage after delivery and
clear timers, callback roots and registry entries on every terminal path.

The 8 MiB output-byte limit is not a claim of 8 MiB RSS. Budget and test peak
retained native text/token storage, input copies, result transfer and materialized
R character-vector overhead. The acceptance helper must calculate a conservative
bound for those objects and verify `object.size(result)` against it; duplicated
R/Rust limits need twin-pin tests. A bounded progress channel alone does not
prove bounded job memory.

## 7. Work sequence and acceptance

Keep one WP in flight and one reviewable implementation milestone. Work is
estimated as one WP of at most two weeks; failure of the ownership feasibility
gate produces a revised proposal, not silent expansion into an actor rewrite.

1. After approval, amend API/ADR/architecture and implement the owned task/domain
   skeleton with a controllable R-free worker fixture. Prove main/worker handoff,
   busy behavior, cancellation races, drop order and shutdown before moving real
   inference. Native calls on the current main-thread-only types are forbidden.
2. Extend shared generation with optional R-free control/progress hooks. Reuse
   the existing chunked prefill and sampler in sync/async paths. Preserve existing
   goldens before adding promise integration; no golden regeneration for a
   scheduling change.
3. Add R promise/timer/callback handling, cancellation, optional-dependency checks
   and examples. Add adversarial lifecycle tests and complete platform acceptance.
4. One integrated independent review covers native ownership, numerical parity,
   memory and callback lifecycle; fix material findings and run final checks.

The following are **planned gates, none executed for this proposal**. Introduce
the named test files during implementation; they do not yet exist.

| Gate | Executable evidence and pass criterion | Run location |
|---|---|---|
| Ownership | `cargo test --locked -p rebirth-llm async`; controlled worker pauses prove no overlapping native access, stale permit use, off-thread R wrapper access, double free or leaked permit. Cover close/GC of parent, derived and unrelated handles. Test debug and release behavior. | Rust PR job; native-boundary cases in R check. |
| Numerical | Existing synthetic token/logit/intervention goldens pass unchanged through worker execution. Sampled sync/async token IDs, bytes and seeds are identical on the same model/build/backend; named vector results also compare with `identical()`. Include ordinary/chat/stop/structured/intervened paths and prompt lengths exceeding `n_batch`. | Rust PR goldens; cached Qwen `[MODEL]` local + existing Qwen nightly. |
| Responsiveness | A deterministic worker fixture held for 2 s returns its promise within 250 ms after packages are loaded, while at least ten independent 50 ms R heartbeat callbacks run before settlement. A real cached-model RStudio generation lasting at least 5 s allows submitted `1 + 1` commands to return within 500 ms, recorded with session/model/backend provenance. | Model-free R PR tests; local M4 RStudio acceptance. Timing failures are investigated, not relabelled as passes. |
| Promise contract | New `test-llm-async.R`: success, zero-callback mode, typed native errors, schema errors, callback failure/reentrancy, NULL-seed draw timing, preserved names, one settlement, and missing dependency behavior. Synthetic tokenizer failure tests run without downloads; success fixture is explicitly synthetic engine control, not claimed text-generation evidence. | R PR matrix, with async dependencies required. |
| Cancellation | Force cancellation before ingest, between prefill chunks, during sampling, between prompts, before/after terminal publication and from progress callbacks. Next uncancelled seeded call matches sync. Completion follows the next cooperative checkpoint; no fixed bound asserted for uninterruptible C calls. | Rust/R PR tests; cached-model local acceptance. |
| Lifecycle | New `test-llm-async-lifecycle.R` runs child R processes for forced GC, repeated close, dropped promise references, worker startup failure/panic, cancellation/error recovery and unload/shutdown. Assert exit status, exactly-once release counters and absence of raw panic text. | R PR matrix; no new process package required (`Rscript` subprocess harness). |
| Bounded memory | Stall R draining while the controlled worker publishes 100,000 progress updates: retained snapshot count stays 1, terminal slots stay 1, queued jobs stay 0. Test output/input boundaries and materialized R size estimate. Run 100 tiny completion/cancel/error cycles after warmup: job/root/thread counters return to baseline; record RSS as supporting evidence, not allocator-sensitive proof. | Rust/R PR tests; M4 acceptance. |
| Vision | Seeded synchronous/async image generation agrees for an existing pinned model/projector; cancel/close during encoding and later text generation preserve ownership and recovery. No new image model download in PR CI. | Existing vision nightly / cached local fixtures, with unchanged machine-bound reference rules. |
| Integration | Existing `R CMD check` matrix, golden jobs, `cargo fmt --all --check`, clippy, default/no-spill Rust tests and required CI pass on the final candidate. Tests/examples document their gates and skips. | Final local relevant suites and existing CI. |

Run long builds/tests in the background and use completion events or the existing
same-chat monitor; do not poll unchanged output. This planning pass runs no build,
native test, model download or generation and establishes no performance result.

## 8. WP10 compatibility and boundary

Keep the engine hook able to produce an owned event for a sampled token, but do
not expose tokens in WP9 progress or freeze a token schema here. WP10 adds its
own approved callback/connection contract. A lossless token queue must have both
count and byte limits, separate completion/cancellation controls and cancellable
backpressure. Unlike progress snapshots, tokens cannot be coalesced or silently
dropped. A full token queue must never stop cancellation or resource teardown.

WP10 must specify UTF-8 fragments, stop strings spanning tokens, EOG inclusion,
prompt boundaries and how concatenated published text equals the final result.
Structured partial tokens cannot be labelled validated JSON before the final
independent validator succeeds. Define connection close as cancellation of its
consumer/job according to that later contract. Windowed statistics consume the
resulting data stream; no plotting or window-aggregation framework belongs in WP9.
Phase-6 activation callbacks and live intervention changes remain separate.

The requested I1 work follows WP9 and WP10; this plan does not pull it into async
acceptance or approve any I1 API or dependency.

## 9. Decision and exact next action

The founder must approve or amend the combined WP9 proposal: existing-function
async arguments plus `llm_cancel(m)`, optional later/promises and their explicit
transitive exception, bounded job limits, one native job without a queue, and
deferred close semantics during active work.

On approval, the owner records the ADR and approved grammar entries, then starts
step 1's ownership/lifecycle feasibility implementation. Until then, this remains
a planning artifact and the shipped API stays synchronous.
