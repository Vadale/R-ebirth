# WP10 — Token streaming as R data

Date: 2026-10-02. Decision: **D-038 proposed; founder approval pending**.
Baseline: merged WP9, `b16e2c0ab74371825562f71c1f9a2f1cfcf58898` (PR #54).
Branch: `codex/token-streaming`. This is a design, not implemented behavior or
acceptance evidence. D-037 remains the approved API until D-038 is approved.

## 1. Deliverable and scope

Roadmap acceptance, verbatim: **live token stream feeds a growing data.frame;
live token-statistics demo.**

Extend WP9's existing native worker with a bounded, ordered event stream. A
caller receives batches as plain R data frames or writes them to an already-open
binary file connection. The same promise still resolves to the ordinary named
character vector with its recorded seed. A small base-R demo shows generated
text, token counts, throughput and rolling token frequencies while R stays usable.

No new exported function, R/Rust dependency, model download, native inference
backend, vendor patch, server, job queue or general streaming framework is
proposed. This reuses `later`/`promises` under D-037. Logits, live activations and
intervention changes during generation belong to Phase 6; I1 follows WP10.

## 2. Proposed public API

Append one argument, preserving all existing positions and defaults:

```r
llm_generate(m, prompt, max_tokens = 256, temperature = 0.8, top_p = 0.95,
             seed = NULL, chat = TRUE, stop = NULL, images = NULL,
             schema = NULL, async = FALSE, on_progress = NULL,
             on_token = NULL)
```

- `NULL`: WP9 behavior, without allocating a stream queue or decoding for it.
- `function(batch)`: receives one nonempty plain data frame per dispatch on the
  R thread. Its return value is ignored. No promise-returning consumer protocol.
- An already-open, writable **binary base `file()` connection**: receives the
  event CSV described in section 4. The caller owns its lifetime and location.
- A non-NULL value requires `async = TRUE`. Reject invalid sink/type/mode before
  drawing an omitted seed, starting the worker or writing a header. Empty
  callback batches are never emitted.

The final value, names, seed, sampling algorithm and existing stop/schema/image
rules remain unchanged. `on_progress` remains a separate coalesced progress
callback. Streaming is opt-in; a slow consumer may slow generation through
backpressure. User callbacks and file writes execute synchronously on R's
thread, so arbitrarily slow consumer code or storage can block R. No hard
responsiveness or disk-durability guarantee is made for them.

### Event schema (exact column order and types)

| Column | R type | Meaning |
|---|---|---|
| `event_id` | integer | Contiguous 1-based sequence across the call. |
| `event` | character | `token`, `text` or `prompt_end`. |
| `prompt_id` | integer | 1-based input position, even with duplicate prompt names. |
| `token_pos` | integer | Generated-token position for `token`; otherwise `NA_integer_`. |
| `token_id` | integer | Native ID + 1 for `token`; otherwise `NA_integer_`. |
| `text` | character | Nonempty committed UTF-8 delta for `text`; otherwise `""`. |
| `elapsed` | double | Nonnegative monotonic seconds since submission, recorded at production. |
| `finish_reason` | character | `length`, `stop`, `stop_string` or `context_full` on `prompt_end`; otherwise `""`. |
| `validated` | logical | `NA` for ordinary generation; `FALSE` for structured token/text rows; `TRUE` for a successful structured `prompt_end`. |

Token events correspond exactly to the existing `Generation.tokens`, including
tokens contributing to a removed stop suffix and the final sampled token on
context exhaustion. They exclude EOG. Token IDs are vocabulary indices, not
display strings. Text events are separate because tokens can split UTF-8 or
participate in whitespace cleanup. No false one-token/one-text-piece mapping is
promised. Within a prompt, a sampled token event precedes any text it makes
publishable; all final text precedes `prompt_end`. Prompts remain sequential.

On successful completion, concatenating each prompt's text events exactly
reconstructs its final returned string. Each successful prompt has one
`prompt_end`, including an ordinary zero-token result from immediate EOG.
An empty prompt vector and `max_tokens = 0` remain invalid arguments, rejected
before submission with no events or header. Structured text is provisional until that prompt's independent
JSON/schema validation succeeds. This validates format, not facts. A successful
earlier prompt does not make a later failure or consumer failure a successful
vector result. No `prompt_end` is emitted for a failed/cancelled prompt.

Batch boundaries and elapsed times are not deterministic across executions.
Event order, IDs, token content and concatenated final text obey the existing
seed/build/backend determinism scope. Consumer side effects are not rolled back
on failure; already delivered prefixes remain with the caller. Lossless delivery
and final equality are success guarantees, not a partial-result recovery API.

## 3. Text correctness before performance

The pinned source has two distinct text authorities:

1. Ordinary output: whole-vector `llama_detokenize(false, false)` followed by
   Rust lossy UTF-8 conversion (`generate.rs::decode_tokens`). The pinned
   `llama-vocab.cpp` removes a leading space and performs punctuation/apostrophe
   cleanup. A later token can revise a previous decoded suffix. Existing
   `token_piece()` instead uses different special-token handling and converts
   pieces independently; concatenating it is not a valid implementation.
2. Structured output: raw token bytes with `special=false`, independently
   validated against the schema, then converted as strict UTF-8
   (`structured.rs::GenerationConstraint`). Do not apply ordinary cleanup to it.

Streaming must publish only a prefix that future input cannot revise. Keep an
incomplete UTF-8 suffix until it becomes complete or reaches the authoritative
terminal conversion. Ordinary malformed-byte replacement retains existing Rust
lossy semantics. Do not change when the existing generator checks stop strings:
it examines the full current decoded snapshot, including provisional U+FFFD,
after each token. Check that authority **before** publishing a new text delta.
Hold text that could still complete a stop string across tokens. Flush only the
remaining authoritative `Generation.text` at success, verifying the published
prefix agrees byte-for-byte; invariant failure rejects, never silently edits
already delivered data. Embedded NUL, which cannot be an R string, rejects the
stream with the encoding condition below rather than reaching an FFI panic.

Implementation feasibility gate: establish the stable-prefix rule against
vendored b10828 before wiring public delivery. A read-only review identified
cleanup passes with unresolved right-context tails of 1, 2 and 3 bytes; a
conservative six-byte post-cleanup suffix is a **candidate, not an accepted
proof or public constant**. Verify a compositional proof and exhaustive reduced
alphabet fixtures against the pinned decoder, or use exact bounded per-pass
transducers. Adjacent-snapshot longest common prefixes are insufficient: empty
pieces can precede later revisions. Neither terminal-only text delivery nor a
changed final decoder is an acceptable silent fallback. Revisit the design if
the invariant cannot be established without those changes.

Keep the decoder pin and adversarial fixtures with the implementation so vendor
updates must revalidate this assumption. Token sampling, RNG, prompt ingestion
and the existing `n_batch` chokepoint are not duplicated or changed.

## 4. Connection ownership and CSV

V1 accepts a live connection object, not an integer descriptor or pathname.
Require base connection class `file`, binary writable mode, a seekable regular
local file, initial position zero and an empty file. Check actual connection
identity, retaining its `conn_id`; a closed and reused integer slot must never
redirect output. Reject text/raw/compressed connections, sockets, pipes, FIFOs,
devices, URLs and append/nonempty destinations. The caller must not independently
seek, write, truncate or replace the destination while a job owns its stream.
The regular-file check is input validation, not a defence against concurrent
malicious filesystem replacement or a guarantee about storage latency.

`relm` neither opens nor closes this connection and never chooses a pathname.
Write one header, then batches, with UTF-8 bytes, LF record delimiters, comma
separator, decimal point and no row names. Quote every character field; double
embedded double quotes. Missing numeric/logical fields are empty unquoted
fields; logical values are `TRUE`/`FALSE`. Format elapsed doubles with sufficient
precision for numeric round-trip, independent of R print/locale options.
Flush after each batch and before successful settlement. No `fsync`, atomic
commit, locking, retry, resume or rollback protocol is implied. Failed calls may
leave a valid prefix or an incomplete last record; successful file completion
is established by the promise, not merely by seeing some `prompt_end` rows.

The documented base-R reader fixes types and preserves literal text `"NA"`:

```r
events <- read.csv(
  path, fileEncoding = "UTF-8", check.names = FALSE,
  na.strings = character(),
  colClasses = c("integer", "character", "integer", "integer", "integer",
                "character", "numeric", "character", "logical")
)
```

This is a narrow proposed amendment to API-GRAMMAR rule 9: opt-in
`llm_generate(on_token = con)` writes to the caller's supplied connection.
It creates no relm-managed file. A callback's own writes remain caller code.
Base R provides the required file, byte-write and CSV facilities; no JSON
serializer or external transport dependency is introduced.

## 5. Bounded transport and lifecycle

| Boundary | Proposed limit / behavior |
|---|---|
| Queued events | At most 256 rows and 256 KiB allocated text payload. No coalescing or loss on success. |
| Producer text chunk | At most 16 KiB, split only at UTF-8 boundaries; at most one pending chunk outside the queue. |
| R dispatch | At most 64 rows and 64 KiB text per poll; one consumer invocation. Retain WP9's 50 ms scheduling target. |
| Final result / inputs | All D-037 limits remain, including 8 MiB final output, 128 prompts and 8,192 requested tokens per prompt. |
| Slow consumer | Producer waits on a condition variable, not a spin loop. Cancellation and terminal/error state do not consume queue capacity. |

Use checked capacity arithmetic. Queue payload is not total transport memory:
account additionally for descriptors/capacities, pending producer chunk, the
drained native batch, stable-text/stop suffixes, decoder scratch, final result,
R columns/strings and CSV escaping/conversion buffers. Stable text and decoder
scratch must stay bounded by existing text/output limits and be charged even
when duplicated. Do not build an unbounded full-call token table inside relm.
Before acceptance, record the implementation's conservative allocation formula,
verify materialized `object.size()` against it and pin any duplicated R/Rust
constants. Allocator/backend/model memory and data retained by user code remain
outside this scoped estimate; report that limitation, not an invented RSS cap.

Extend the existing active job, control mutex and execution permit; do not create
a second worker. The wait predicate and cancellation change must synchronize
through the same mutex so cancel/close/shutdown cannot lose a wakeup. Wake the
producer before joining. No R object, callback, connection or R RNG access is
allowed on the worker. No native lock/RefCell borrow spans R consumer execution.
Guard reentrant polling (including callbacks that call `later::run_now()`).

Distinguish **native terminal** from **delivery terminal**:

1. Drain stream batches while retaining the execution reservation. A native
   completed outcome occupies the existing bounded result slot until delivery
   finishes; it cannot bypass queued rows.
2. On successful delivery/flush, restore or safely destroy the model and release
   the reservation. Then call final `on_progress` and settle as in WP9.
3. Thus native calls from every `on_token`, including the last batch, see busy;
   final `on_progress` retains WP9's released-ownership behavior. Callbacks may
   request `llm_cancel(m)` or close the submitting model using D-037 semantics.
4. `llm_cancel()` retains native-terminal arbitration: it returns FALSE once
   native completion was published even if delivery is still draining. It is
   not retroactively accepted cancellation. Explicit model close **during
   stream delivery, before ownership release** abandons remaining delivery and
   prevents later token callbacks. Dispose of ownership safely; native success
   with abandoned delivery rejects as `relm_error_cancelled` with reason
   `stream_closed`. Closing the model inside final `on_progress`, after release,
   keeps WP9 behavior: a successful callback does not change the resolved value.
5. Callback failure, interrupt or sink closure stops further delivery, discards
   undelivered rows, requests cancellation if still possible and wakes the
   worker. Continue nonblocking scheduled terminal polling, collect ownership,
   then reject. Blocking join remains limited to shutdown/emergency paths.
   A delivery failure can reject after native success.
   Suppress subsequent callbacks once a consumer fails. Preserve the original
   consumer condition as `parent`. Detect sink closure at each scheduled poll,
   including during prefill when no token has arrived; never write to a reused
   connection identity.

Settlement precedence is explicit: the first recorded R consumer failure
(token/progress callback, connection or representation failure) rejects with its
original condition after ownership returns. This preserves WP9's callback-error
precedence over a cancellation/error subsequently returned by the worker.
Otherwise retain the native failed/cancelled outcome; native control still
arbitrates cancel versus completion as in D-037. Only an otherwise successful
native result abandoned by model close during delivery becomes `stream_closed`.
With none of those failures, final progress and settlement follow WP9. Once a
native failure is observed, discard queued events instead of invoking new
consumers. No later error overwrites an already recorded consumer failure.

Cancellation is cooperative around synchronous engine calls, including vision
ingestion. A busy consumer/blocked filesystem operation cannot be preempted from
R by this worker. Namespace shutdown cancels/wakes/joins; it retains the DLL for
live finalizers as WP9 does. Forced DLL unmapping stays unsupported.

### Proposed conditions

- `relm_error_argument`: invalid `on_token`, missing `async = TRUE` or invalid
  connection admission; synchronous, with no submitted job or header.
- Existing `relm_error_callback`: failing `on_token`/`on_progress`, with
  `callback` identifying the callback and the original `parent` condition.
- New `relm_error_stream`: delivery/representation failure, with `reason` in
  `closed`, `write`, `encoding`, `invariant`; known `prompt_id`/`event_id` (or
  typed NA) and original `parent` where available. Class hierarchy follows
  API-GRAMMAR rule 8. File write/flush errors and failure warnings reject;
  no silent retry. Settlement follows the explicit precedence above; consumer
  failures cannot masquerade as a successful result.
- Existing busy, closed, generation, schema, cancellation and memory conditions
  otherwise retain their meanings. No new `llm_cancel()` return state.

## 6. Acceptance and efficient execution

These are **planned gates, not results**. Use one coherent WP10 implementation
and one integrated independent review. Local commits may separate native
transport from R delivery/docs; push complete review milestones. Long builds,
CI and actual model jobs use detached execution and the existing sparse monitor.

| Gate | Evidence and execution site |
|---|---|
| Stable text | Native Rust CI, deterministic fixtures plus pinned-decoder comparison: leading spaces, punctuation, all cleanup contractions, empty pieces, special tokens, split/malformed UTF-8, U+FFFD stops, overlapping/multi-token stops, EOG/context exhaustion and zero output. Compare streamed text and token IDs with unchanged generation authority. |
| Bounded ownership | Native CI: fill both row/byte limits, slow consumer, cancel/close/panic/shutdown while producer waits, lost-wakeup stress with a finite deadline, terminal publication race and exactly-once restoration/destruction. Check allocator capacities and absence of unbounded accumulation. |
| R API / sinks | All R CI legs: exact types/1-based IDs/names/seed, invalid admission before RNG/IO, callback failure/interrupt/reentrancy, final callback ordering, file closure/reused descriptor, quoting/newlines/Unicode/literal NA, partial write/flush failure, empty input and all-or-error vector semantics. Verify materialized memory and cross-language constants. |
| Numerical parity | Relevant existing native golden/FFI gates once on the final runtime; seeded sync/async/stream equality on in-repo tiny fixtures. Do not regenerate expected values to accommodate a mismatch. |
| Real-model paths | One bounded cached-Qwen run for ordinary/structured streaming and one cached VLM boundary case; record model/source/backend. No new large download or repeated WP9 full model matrix. Windows/CUDA remain deferred. |
| User acceptance | One foreground RStudio streaming demo on a real cached model: at least 5 s generation, token batches delivered before native completion, independent `1+1` under 500 ms while active, at least 10 event-loop heartbeats. Growing data-frame/text reconstruction plus fixed-window token statistics and final CSV parity. Separate cold model preparation from measured runtime. |
| Final integration | Relevant package check and all nine required PR checks on final head; runtime unchanged while documentation receipts finish. No receipt-only commit loop. |

The demo keeps only a fixed last-128-token window for live statistics. A bounded
small example may also collect the full event table to demonstrate the roadmap
acceptance; label it caller-retained memory. Calculate token rates from token
events' production times and show delivery lag separately; do not call text
chunks tokens or claim a backpressured rate is unconstrained engine throughput.
Use base R, runnable examples and a short vignette; no dashboard framework.

Update roxygen, NEWS, README/quickstart and validation/implementation reports
when behavior exists. Reuse WP9's accepted evidence for unchanged paths while
testing the new queue/terminal boundaries. Do not repeat WP12b stress, release
0.3 demos or the WP9-only RStudio gate.

## 7. Source basis and decision required

Reviewed source: `rebirth/R/async.R`, `rebirth/R/generate.R`, native
`async_job.rs`, `async_boundary.rs`, `generate.rs`, `structured.rs`, and pinned
`rebirth/src/llama.cpp/src/llama-vocab.cpp`. Graphify supplied navigation; actual
source is authoritative. One read-only native design review identified decoder
revision and delivery-terminal hazards. No product changes/tests are claimed.

Primary references: [R connections](https://stat.ethz.ch/R-manual/R-patched/library/base/html/connections.html),
[R CSV writing](https://stat.ethz.ch/R-manual/R-patched/library/utils/html/write.table.html),
[later scheduling](https://later.r-lib.org/reference/later.html),
[Rust condition variables](https://doc.rust-lang.org/std/sync/struct.Condvar.html).
Tiny model-free R probes confirmed binary-file metadata/identity and the reader's
literal-NA/missing-field behavior; they are design checks, not stream acceptance.

**Founder decision:** approve D-038's `on_token` signature, event/CSV schemas,
connection side-effect exception, bounded delivery and condition/lifecycle
contract. No new dependency approval is requested. After explicit approval,
promote API-GRAMMAR section 10 and implement the native text/queue gates first,
then R delivery and the end-to-end demo within this same work package.
