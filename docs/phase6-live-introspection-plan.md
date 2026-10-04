# Phase 6 — Live introspection and steering contract

Updated: 2026-10-04. Status: **F6a APPROVED under D-041 and accepted at6877c4d.
F6b operational acceptance is complete: native, installed R, public updates,
remote checks at490c7f4 and actual foreground RStudio steering. Final
PR-head CI and PR59 integration remain separate.** The founder replied "ok. continua con F6a e F6b" to the
concrete proposal. F6a's contract below is now binding in API-GRAMMAR section11.
Continuation into F6b is authorized; section6 finalizes its reply/audit protocol
before that increment's implementation. No dependency or acceptance result is
created by this approval. It follows the completed
WP9/WP10/I1 and pre-Phase-6 maintenance work. PR57 integration is recorded by
the coordinating task; this design did not run remote checks. The historical
Mac timeout remains unexplained and is not claimed fixed by this proposal.

## 1. Deliver the observation boundary first

The first implementation, **F6a**, should let an R callback inspect the state
that selected each generated token, compute a concept-direction/probe score,
and request cancellation before another token is sampled. Deliver selected
activations as bounded `relm_trace` chunks, next-token logit summaries as a
plain data frame, and the existing final text promise. Include a base-R rolling
score demo and a threshold-triggered cancellation demo. These are research
instruments; they establish neither detector reliability nor a safety guarantee.

Choose a strict one-state acknowledgement boundary. The worker waits for the R
callback before continuing. This makes the causal delay intelligible and keeps
retained state bounded, at a measurable throughput cost. Lossy observation or
an unrestricted queue would make a threshold demo appear to react sooner than
it actually does.

**F6b**, a separate bounded increment after F6a acceptance, adds changes to
coefficients of already-declared steering directions, effective at the next
decode. It completes the adjustable-intervention portion of Phase 6. F6a alone
does not complete all Phase-6 scope. Multi-position delivery windows, native
probe evaluation, new directions/ablations during a job, image-bearing capture,
structured-generation logits and multi-prompt live capture are later work.
They are not prerequisites for the first useful instrument.

No new R/Rust dependency, worker framework, engine backend, vendor patch or
model download is proposed. Reuse `later`/`promises`, Arrow IPC/`nanoarrow`,
Rust standard synchronization, existing probes and the existing synthetic/Qwen
fixtures. Any newly necessary dependency or vendor change returns as a concrete
decision; this proposal does not pre-authorize one.

## 2. Baseline facts that constrain the design

Read-only navigation used the existing graph, with vocabulary
`generation trace intervention capture spill decode token context`, then
confirmed these facts directly in source. The graph predates WP9/WP10, omits R,
and is navigation evidence only. It was not rebuilt or updated.

| Existing contract/source | Consequence |
|---|---|
| D-037; `R/async.R`, `async_job.rs`, `async_boundary.rs` | One active native job per process; exclusive model/context transfer; callbacks and all R allocations stay on R's main thread. Reuse this ownership domain. |
| D-038; `docs/wp10-streaming-plan.md` | `on_token` receives ordered data-frame batches or writes the approved CSV. Callback returns are ignored. It cannot be redefined as `function(state)`. |
| `generate.rs::continue_generation_with_constraint` | Sampling precedes decode of the sampled token. Stop-string/context-full paths can finish without that token's decode; EOG is excluded from generated tokens. |
| `trace.rs::CaptureState` and `run_capture` | Current prompt tracing assumes full prompt-shaped tensors and creates a separate transient context. It cannot simply be called from an async callback or relabelled as generation tracing. |
| `engine.rs::create_trace_context`; b10828 `llama.h` | Eval callbacks are context-creation parameters. The inspected public interface offers an abort setter, but no eval-callback setter for an existing llama context. |
| D-016/D-021; `intervene.rs`, `R/intervene.R` | Handles are immutable from R's perspective; interventions sum/union and ablation follows steering. Existing prompt tracing rejects intervened handles. Live capture must prove what it observes on the actual generation context. |
| `spill.rs`, `spill_lease.rs`, `R/trace-spill.R` | Spill uses completed Arrow IPC streams, nonce/spec checks and managed lifetime leases. The existing writer's blocking bounded send/join is not by itself a cancellation-aware live protocol. |

Source paths above are under `rebirth/` and
`rebirth/src/rust/rebirth-llm/src/` unless otherwise stated. Binding background:
`SOLO-PHASE-PLAN.md` section 2, `API-GRAMMAR.md` sections 2/4/9/10,
`ROADMAP.md` Phase 6, and D-012/013/014/016/017/021/037/038.

## 3. Approved F6a public contract

Append arguments; preserve every existing positional argument and default:

```r
llm_generate(m, prompt, max_tokens = 256, temperature = 0.8, top_p = 0.95,
             seed = NULL, chat = TRUE, stop = NULL, images = NULL,
             schema = NULL, async = FALSE, on_progress = NULL,
             on_token = NULL, on_state = NULL, layers = integer(),
             components = "residual", top = 20L, spill = TRUE,
             spill_dir = NULL)
```

This signature amendment is approved under D-041. It adds no new function name. The extra arguments belong to live observation only:

- `on_state = NULL` preserves current generation. Nondefault capture arguments
  without a callback are rejected, avoiding silently ignored capture requests.
- A non-NULL `on_state` must be a function and requires `async = TRUE`, exactly
  one prompt, `max_tokens <= 1024`, `schema = NULL`, and no image input. A
  projector-equipped handle with text-only input is not inherently excluded.
  Existing ordinary/structured/vision calls without `on_state` keep D-037/038.
- `layers = integer()` captures no activations; `NULL` explicitly selects all
  blocks; otherwise use unique, valid 1-based block indices. This makes default
  observation logits-only and full capture an explicit request. `components`
  is a nonempty subset of the three existing components. Reject duplicate or
  invalid indices at both boundaries rather than clamp them.
- `top` is one integer from 0 through `min(128, vocabulary_size)`; 0 disables
  logit summaries. At least one of activation capture or logits is required.
  Pre-submission metadata validation must not tokenize or touch an active
  context outside the execution permit.
- `spill` and `spill_dir` retain the meaning and ownership rules of
  `llm_trace`, applied to each state chunk. A spilled chunk is a completed
  zero-row `relm_trace` proxy; ordinary indexing does not read its values.
- Callback execution is synchronous on R's main thread. F6a requires its return
  value to be `NULL`; use `invisible(NULL)` explicitly. Promises, continuations
  and arbitrary reply objects are rejected. This reserves a precise later
  command protocol without changing an existing ignored-return contract.

Keep `on_token` callback batches, CSV schema, queue bounds, stable UTF-8 rules,
and ignored callback return exactly as approved. Both callbacks may be supplied.
The resolved value remains the same named character vector with seed; there
is no automatically accumulated all-generation trace attached to it. Retaining
chunks or appending them to a caller-owned analysis is the caller's choice.

Extend the declared side-effect rule explicitly: `llm_generate(on_state = ...,
spill = TRUE)` may create the same managed/custom trace spill artifacts as
`llm_trace`. A state callback cannot be a connection; token CSV remains token
CSV, with no activation columns added.

### State payload and the off-by-one contract

`on_state(state)` receives a base named list with exactly `step`, `logits` and
`trace`. `step` is a one-row plain data frame, in this order:

| Column | Type | Meaning |
|---|---|---|
| `state_id` | integer | Contiguous 1-based state sequence in this call. |
| `prompt_id` | integer | 1 in F6a; retain the existing input-index meaning. |
| `token_pos` | integer | Generated-token position `k`, matching WP10. |
| `token_id` | integer | Sampled native vocabulary ID + 1. |
| `context_pos` | integer | Position the sampled token would occupy: `P + k`. |
| `source_pos` | integer | Position whose forward pass supplied this distribution: `P + k - 1`. |
| `source` | character | `prompt` for `k = 1`, otherwise `generated`. |
| `elapsed` | double | Monotonic seconds since submission at state production. |

`P` is the actual tokenized prompt length after special tokens/chat templating,
not the length of the user's raw string. All R positions are 1-based. At context
exhaustion `context_pos` can be one beyond the available window: the existing
generator can sample this last token but does not decode it. The state still
describes the valid preceding source position; it invents no activation for the
undecoded token.

`logits` has the existing `llm_logits` columns/order/types
(`prompt_id, rank, token_id, token, logit, prob`), containing at most `top` rows.
It represents the **raw model logits before temperature/top-p sampling**;
`prob` is the full-vocabulary softmax at temperature 1, not a renormalized top-k
share or the sampler's final probability. Ties use ascending token ID. It is
empty with the same schema for `top = 0`. No full-vocabulary R vector or entropy
definition is added. These values do not require a second forward pass.

`trace` retains the seven approved `relm_trace` columns and methods. Its
`token_pos` is **`source_pos` in the actual model input sequence**, not generated
position `k`; the token column is that source token's display piece and never
the reconstructed output string. Introduce explicit attributes
`position_space = "model_context"`, `prompt_token_count = P`, and `state_id` on
these live chunks. The model/prompts/spill metadata remains as specified. A
matching spill metadata version/key must bind the live coordinate convention;
an old prompt-trace proxy must not accidentally validate a live artifact.
With no requested layers, return a zero-row, non-spilled trace with that schema.

Each chunk covers one source position and all selected layer/component vectors.
The first chunk captures only the last prefill position; it does not publish a
full prompt trace. Later chunks capture one-token incremental decodes. The
selected `residual` must be the post-intervention residual actually used by the
generation context; `attn_out` remains post-projection and `mlp_out` keeps its
existing tap meaning. This semantic claim requires independent fixtures,
especially on statically steered/ablated handles.

There is one state for each sampled non-EOG token on a successful call,
including a token participating in a removed stop suffix. There is none for
EOG itself, including immediate EOG. If EOG is sampled, discard the otherwise
unused captured source state without delivering a synthetic generated token.

### Ordering and stop latency

For token `k`, the worker samples using the captured source logits, publishes
state `k`, and waits for its acknowledgement **before** enqueuing the WP10
token event for `k`, publishing any newly committed text, or decoding `k`.
The R dispatcher drains any earlier token events first, invokes `on_state`,
validates its reply, and acknowledges. Thus both consumers have an explicit
order without changing the internal WP10 event ordering. With `on_token = NULL`
there is no token queue to drain.

Calling `llm_cancel(m)` inside `on_state` requests D-037 cancellation; it rejects
the promise with `relm_error_cancelled`. Token `k` has already been sampled and
appears in cancellation's generated count, but its token/text events have not
yet been delivered. No token `k + 1` is sampled. Previously delivered data
remains caller-owned. This is a cancellation mechanism, not successful partial
text recovery or guaranteed suppression of every unsafe string.

## 4. Native ownership, acknowledgement and cancellation

Keep the WP9 exclusive execution permit across prefill, capture, callback waits,
token delivery, and native outcome collection. R callbacks never call the engine
directly: `llm_trace`, `llm_logits`, `llm_steer` and another generation from a
callback still raise busy. Pure R probe prediction, matrix operations and
bounded lazy spill reads remain possible. Do not move an R object, function,
connection or RNG access onto the worker.

Add one outstanding state slot and a one-reply acknowledgement slot to the
existing control state. Use `(job identity, state_id)` for correlation, reject
stale/double/wrong-job replies, and share the existing cancellation mutex and
condition-variable discipline. State capacity is one; no state coalescing or
drop on success. Do not hold a native lock or R-side borrow while user code
runs. Preserve the reentrant-poll guard when callbacks call `later::run_now()`.
No second inference worker or task queue is needed.

Cancel, close, callback failure, writer failure and shutdown wake every wait
without needing free queue capacity. Native terminal and delivery terminal stay
distinct. Preserve WP10's first-consumer-error precedence, discard undelivered
data after an observed native failure, return/destroy ownership once, and invoke
final progress only after release. Successful final progress can still close
the model without retroactively changing success. As in WP10, close during
delivery abandons an otherwise successful native result under `stream_closed`;
an already failed/cancelled native outcome is preserved. Closing while the
worker awaits a live acknowledgement therefore requests native cancellation.

Use the existing error families: admission errors are `relm_error_argument`,
capture/schema/I/O failures `relm_error_trace`, predictive limits
`relm_error_oom`, internal protocol violations `relm_error_internal`, and user
callback failures `relm_error_callback` with `callback = "on_state"` and
original `parent`. An invalid callback reply is a callback failure with
`reason = "state_reply"` and an argument condition as parent. Add relevant
job/state/prompt fields to these proposed errors. No raw callback panic crosses
C or reaches R unclassed.

Cancellation is still cooperative. A running decode, storage operation, or R
callback can delay it; there is no hard wall-clock deadline. The acknowledgement
guarantee is a token-order guarantee. Poll at a proposed 5 ms target while live
observation is active, leaving ordinary WP9/WP10's 50 ms target unchanged. Each
R dispatch runs at most one state callback. A slow callback intentionally slows
generation and can itself block R.

### Context integration feasibility gate

Prefer a stable, owned, dormant eval-callback dispatcher installed when each
generation context is created. It returns no requested tensors outside an
active live job. Enable its bounded capture state only while the owning worker
holds the permit; detach the job state on every exit and free callback storage
only after the native context. A moved context retains a stable callback address.
The dispatcher and copied buffers stay R-free. Audit the actual scheduler thread
and callback lifetime rather than retaining the current trace comments that
assume R-thread decoding.

This reuses the loaded generation context and avoids a second KV cache. It
requires proof that toggling the owned capture target works with cached graphs,
does not leave stale tensor-selection state, and has acceptable disabled-path
cost. Refactor only the common tensor-name/copy validation needed by prompt
tracing and generation; do not route full live generation through the current
prompt-shaped `TraceContext`. Keep all prompt ingestion on the existing
`n_batch`-chunked chokepoint. For first-state prefill capture, prove the correct
last output row under pruning/microbatching rather than flagging every prompt
token as output or copying a full prompt tensor by default.

If the dormant hook cannot satisfy parity/lifetime/overhead gates, stop that
milestone with the specific evidence. A permanent second context, private
llama.cpp layout access, or vendor setter patch is not an implicit fallback.

## 5. Memory, spill and retention

Budget against R materialization and transient copies, not merely f32 values.
For hidden width `H`, selected layers `L` and components `C`, one state contains
`N = H * L * C` activation values. Estimate the seven-column R trace as at
least `44 * N` bytes **plus explicit fixed vector/string/attribute overhead**;
the existing factor 11 alone underestimates very small chunks. Include the
logit table, native rows/capacities, tensor scratch, FFI conversion, drained
state, acknowledgement metadata, writer buffers, and existing WP10 transport
allocations. Check products and sums for overflow on both boundaries.

Approved F6a limits:

| Resource | Bound / policy |
|---|---|
| Outstanding state | One, with no second produced state until acknowledgement. |
| In-memory state materialization | `min(getOption("relm.trace_budget", existing_default), 32 MiB)`, including fixed overhead; over-budget activates spill or rejects with `spill = FALSE`. |
| One layer/component activation vector | At most 1 MiB f32; larger dimensions fail preflight, because a single unsplittable callback vector must fit. |
| Capture/writer transport | At most 8 MiB of native allocated capture payload plus bounded scratch; byte accounting, not only a row count. |
| Live metadata | At most one prompt / 1024 states; no retained full-call activation index in relm. |
| Spill | Preflight a conservative full-call bound against 2 GiB of serialized data and 1024 completed files; enforce actual bytes before each write as well. Refuse before submission if the conservative bound exceeds the limit. |

The conservative **complete transient allocation formula** is frozen in
`phase6-memory-contract.md` before public implementation. Its runtime twins and
actual allocation/serialization checks remain required acceptance evidence. The limits
above are not a total process RSS promise. Model weights, KV/backend buffers,
allocator behavior, and chunks retained or copied by user code remain separate.
Report them separately in acceptance measurements. Narrowing filters is the
default response to a refused request; do not silently truncate captures.

Complete one Arrow IPC stream before publishing its proxy. Never expose a
partially written stream to the R reader. On spill, stream selected rows through
a byte-bounded writer queue so the entire oversized state is not accumulated
first. Reuse exclusive file creation, nonce/spec checks and managed leases from
maintenance; custom `spill_dir` remains caller-owned. A delivered proxy remains
readable after the job/model finishes, until managed session cleanup or caller
deletion. Already delivered chunks may survive a later cancelled job; they are
observations, not evidence of a successful final result.

Make live writer waits cancellation-aware; do not copy the existing blocking
`SyncSender::send` blindly. A writer owns only buffers and filesystem state,
never model/R pointers. On cancel, stop new rows, wake the producer, finish or
abandon the current file safely, and report failures before settling. Joining
writer cleanup belongs off the R polling path. Ordinary OS writes may still
block. Remove unpublished files on normal failure when ownership is proven;
never delete a delivered proxy's file or claim rollback of caller artifacts.

The demo keeps a fixed 64-score rolling window. It computes one direction score
per state from a single selected layer using `as.matrix(state$trace, layer=...)`;
it never repeatedly `rbind`s full hidden-state history. Users who retain all
in-memory chunks intentionally take responsibility for that extra memory.

### Bounded spill implementation and validation

To avoid buffering earlier microbatches or the entire spilled state, use the
exact `attn_norm-0` ask callback as a microbatch marker. The currently recognized
builders place it before attention/pruning; inspect its shape without requesting
a copy. Checked cumulative row counts must reach the current decode call's row
count before any selected tap is copied. Only the final microbatch may emit
selected rows. Reset first-`ffn_out` occurrence latches per layer at the marker;
the second identically named llama residual-add node must not substitute for raw
MLP output. At decode completion require exact row totals, every requested tap
emitted once, no pending copy and no error. Fail classed on missing/duplicate
markers, unsupported ordering or unexpected shape; never publish such a file.

This relies on the approved single-sequence monotone path and the existing
KV `split_simple` order. Other splitters require explicit verification rather
than assuming that a row-count sum proves token order. Exercise a short final
microbatch, final n_batch chunk and pruned last layer before promoting this
design. Capture needs bounded descriptors and at most one temporary f32 vector
outside its sink; an EOG result abandons its unpublished file safely.

The live writer splits within an activation vector and retains absolute neuron
offsets. The frozen Arrow formula in `phase6-memory-contract.md` replaces the
preliminary 4096-byte margin: encoder-derived metadata framing and aligned
numeric/string/offset/bitmap buffers determine fragment size and whole-call
bytes. Records have at most4096rows, target1MiB or the accounted minimum for one
row. Producer/writer rows, builder, encoded buffers and the byte-bounded queue
are counted simultaneously. The lazy reader checks record lengths and buffer
sizes/capacities before R conversion. These checks remain unverified until the
new resource gates run; requested output matrices and user retention are separate.

The implemented writer and public memory/spill measurements are recorded in
`phase6-implementation.md`. Remote sanitizer acceptance remains pending.

## 6. F6b steering extension, authorized continuation

Do not call existing `llm_steer()` from a live callback. It creates a new handle
and is correctly forbidden while another context owns the domain. The F6b
reply is exactly `list(steer = data.frame(intervention = ..., coef = ...))`, with
unique 1-based indices into the submitting handle's existing `interventions`
list; only `kind = "steer"` entries may be addressed. All coefficients must be
finite and representable by the native contract; reject overflow in summed
per-layer buffers. `NULL` continues unchanged. No new direction, layer,
ablation, position filter or R handle mutation is allowed in this increment.
The founder authorized this continuation together with F6a. The following
details finalize that bounded protocol before implementation; no new dependency,
export, direction or same-pass intervention is introduced.

- Reject extra elements/columns, duplicate indices, non-steer indices and
  nonintegral indices. Normalize valid indices to integer and coefficients to
  double. An empty table equals NULL. Omitted indices retain their current
  coefficients; an identical reply does not increment the revision.
- Validate the entire reply, f32 conversion and all summed layer buffers before
  applying any update. Rebuild from original directions in original order,
  preserving the existing f64 multiplication followed by f32 conversion rather
  than accumulating incremental floating-point deltas. Copy immutable original
  directions once per job. Internal `(job_id, state_id)` correlation rejects
  duplicate/stale acknowledgement; callers do not supply correlation IDs.
- Invalid user content raises `relm_error_callback`, callback=`on_state`,
  reason=`state_reply`, preserving the original condition as parent. Internal
  stale acknowledgement is an internal protocol error. Cancel/close takes
  precedence over any command not yet applied.
- Append integer `steering_revision`, `applied_after_state`, and
  `effective_source_pos` columns after `elapsed` in `state$step`. Baseline values
  are 0L,0L,1L. A changed reply from state k increments revision by one, records
  k, and takes effect at source position P+k. A subsequent state reports the
  revision that actually produced its activations/logits.
- Add `attr(state, "steering")`, a plain data frame with integer intervention,
  integer layer and double coef columns, sorted by original intervention index
  and containing all current steering entries. This worker-produced snapshot
  follows successful adapter application. The three named list elements remain
  step/logits/trace; final text/seed returns remain unchanged. No separate receipt
  is promised for a terminal reply when no later decode occurs.

The worker validates a copied command after state `k`, updates its job-local
copy of the original intervention specification, and applies it before decoding
the sampled token `k`. It first affects that decode's activations/logits and
therefore sampling of `k + 1`. It cannot revise token `k`, the already computed
state, or prior KV entries. Prefill used the original coefficients. Preserve
steer-sums and ablate-after-steer; resetting a coefficient to zero must actively
clear the previous adapter contribution. A final-token reply can have no later
sampling effect. Record the applied coefficient/revision and effective source
position in the next state's proposed metadata, not merely an echoed command.

Live updates are history-dependent: restoring the initial coefficient does not
undo effects already stored in KV. Before returning the handle on success or
failure, restore its original adapters and clear per-job state; a fresh seeded
generation on that handle must reproduce its original baseline. If restoration
fails, close the affected handle safely and reject. Other handles and their
metadata never change. Verify nonzero updates, zero-removal, unchanged replies
and ablation precedence with an independent autoregressive oracle. Existing
zero-coefficient handles may have skipped a nonzero capability sentinel; test
the requested nonzero directions before enabling live changes, never infer
support solely from construction of such a handle.

The pinned `llama_set_adapter_cvec` marks scheduler reservation dirty. Measure
the re-reservation cost; do not promise coefficient updates are a free scalar
assignment. Mid-pass/intermediate-layer intervention, same-token resampling,
KV replay and automatic native thresholding remain later, separately specified
capabilities.

## 7. Golden-first acceptance and efficient milestones

This proposal ran no builds, model jobs, tests or benchmarks. The following are
future gates, not results. Reuse accepted WP9/WP10/maintenance evidence for
unchanged code; do not rerun historical acceptance merely to gather a new date.

| Milestone | Concrete output and decisive gates | Execution |
|---|---|---|
| F6a.0 — approve and prove the hook | Approved signature/side effects/error/resource contract; owned dormant callback spike; correct last-prefill row; complete memory formula; disabled-hook cost and same-context parity. No public live API until these succeed. | Native synthetic tests, one local cached Qwen CPU/Metal comparison. |
| F6a.1 — independent numerical reference | Extend the existing seeded numpy synthetic reference with incremental prefixes: source activations, raw logits/top probabilities, token IDs and position mapping. Pin reference/model/artifact bytes before comparing implementation; regenerate through the existing golden workflow. | Download-free native CI. |
| F6a.2 — bounded live delivery | Owned state/ack protocol, R payloads, same-context capture, completed spill proxies, classed failure paths and both-consumer ordering. | Synthetic native/R tests plus focused sanitizer tests for new unsafe ownership. |
| F6a.3 — one integrated acceptance | Runnable score/cancellation examples; unchanged seeded final text/token stream with a no-op observer; resource/latency receipts; docs and one integrated review. | Existing macOS/Linux ordinary gates and one foreground M4 RStudio demo with cached Qwen. |
| F6b — authorized steering | Implement the finalized reply/audit fields; independent changing-coefficient golden; adapter reset/reuse and measured update latency. | Same bounded fixtures, affected CI and one focused interactive demonstration. |

Numerical/reference gates must catch a plausible wrong implementation:

1. Compare first-state capture with the final prompt position and later states
   with their full-prefix oracle positions, including `chat = TRUE` versus raw
   prompt offset and a prompt longer than `n_batch`. Verify last-layer pruning,
   all three components, multiple selected layers and post-intervention capture.
   An intentional one-position shift must fail.
2. Check full-softmax top probabilities, rank/tie rules, greedy and seeded
   sampling. A no-op observer must preserve sync/async token IDs, final strings,
   names and seed on the same build/backend. Do not claim cross-backend token
   identity beyond existing evidence. Do not introduce a new tolerance to hide
   a streaming discrepancy.
3. Exercise immediate EOG, ordinary max length, stop strings split over tokens,
   context-full final sample, and invalid UTF-8/representation behavior. Confirm
   state/token/text ordering and explicit exclusion of EOG. Reuse WP10 decoder
   goldens rather than writing a different text decoder.
4. With tiny deterministic queue capacities, force cancellation while waiting
   for a state acknowledgement, token space, and writer space; force callback
   failure, recursive event-loop entry, close, GC and shutdown. Verify no lost
   wakeup, no new state after failure, exact terminal precedence, deferred frees,
   and reuse of the domain after ownership returns. Use barriers/latches rather
   than long sleeps and preserve diagnostic boundary receipts on failure.
5. Force spill with a low budget. Compare every lazy matrix slice to the same
   in-memory capture and independent reference; exercise stale nonce/coordinate
   metadata, truncated file, disk error, custom directory and a delivered proxy
   retained after cancellation/model close. Mutation/no-op guards must fail if
   capture, nonce/schema validation or cancellation wakeup is disabled.
6. Verify `object.size` against the formula for both tiny fixed-overhead-heavy
   chunks and real-width chunks; validate counted peak allocations with a slow
   consumer and writer. Pin duplicated limits across R/Rust. Measure RSS as
   contextual evidence, not as a substitute for materialized-memory accounting.

Each test documents the CI job or explicit `[MODEL]` gate. Synthetic tests and
required optional packages are mandatory in their CI legs; no whole-feature
skip because `later`/`promises` was absent. The Qwen acceptance uses the existing
small pinned model; no 4B/7B download or Windows/CUDA claim is introduced.

For overhead, record source/model/backend, token count, filters, warm-up,
callback body, seed, capture copies, callback waits and spill time separately.
Use one warm-up and three interleaved measured runs per mode on the same
machine. Proposed gate: dormant observation costs at most 5% in median versus
the unchanged baseline; one residual layer plus top-20, no-op callback, no spill
has median elapsed time no greater than `1.5 * baseline + 0.010 * tokens`
seconds. These are engineering go/no-go budgets, not product performance claims
or CI wall-clock assertions. A failure is reported and investigated once; do
not silently relax it or rerun until green. Report all-layer/spill throughput
separately without an invented universal overhead ceiling.

The foreground demo must show state arrival while native work is active,
independent `1 + 1` and event-loop heartbeats, bounded rolling scores, and the
exact cancellation token boundary. Preserve user globals, RNG, libraries and
editor documents as WP9/WP10 did. A detector crossing a threshold is a mechanism
demonstration, not validation that the threshold detects harmful content.

Use coherent local milestones and one integrated review. After the last native
edit run appropriate fmt/clippy/tests, then one final CI milestone. Run long
work in the background with completion events or an existing sparse monitor;
continue independent work and end waiting turns. Re-run only affected gates
after a material edit or a diagnosed failure. A documentation-only approval
change does not warrant a native rebuild.

## 8. Original decision request and remaining engineering uncertainty

The original request below is retained as history. D-041 records the founder
approval of F6a and authorization to continue into F6b; do not repeat F6a approval.

Recommended founder decision: approve **F6a only**, including the appended
arguments, separate `on_state` payload, source-position convention, strict
one-state acknowledgement, cancelled rather than successful partial result,
spill side effect and bounded first-delivery limits. Preserve `on_token` in
full. Leave F6b's exact steering reply/audit amendment for the demonstrated
F6a boundary; its direction is prepared here, not implemented or approved.

The material tradeoff is explicit: per-token control certainty costs callback
round trips and some throughput, and the first delivery covers one text prompt
with existing model support. Approval does not claim the feasibility gates
passed. Routine implementation choices above need no separate menu of decisions.

Technical uncertainties to resolve in F6a.0 are: dormant eval-callback overhead
and cached-graph behavior; safe callback ownership/thread execution on CPU and
Metal; correct selected last-prefill tensors under microbatching; and a complete
copy/spill allocation bound. The later F6b blocker is proof that coefficient
updates and reset work on a populated KV context with correct observed residual
semantics. If any requires a changed public contract, dependency or vendor
patch, bring back that specific evidence and proposal. Spark activation tracing,
unaccepted hardware, the deferred independent text-logit comparator and the
historical Mac timeout are not silently promoted by this plan.
