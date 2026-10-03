# F6b integrated implementation review

Date: 2026-10-03. Base: `6877c4dc4bca3eb08d8eeb06f02b71cebc0601d7`.
Scope: the authorized coefficient-only extension in D-041, API-GRAMMAR section 11
and `docs/phase6-live-introspection-plan.md` section 6. This is one independent
source review of R admission/delivery, FFI conversion, native command ownership,
steering arithmetic/restoration, allocation accounting and the new tests. The
accepted F6a implementation and unrelated repository code were not reopened.

No builds, tests, models, reference generation, network operations or product
edits were performed by this reviewer. The native owner supplied its source
freeze before conclusions. The parent subsequently reopened only the concrete
corrections below. Source inspection is not functional acceptance.

## Material findings

### P1 — Initial-zero capability probes omitted owned allocation from the peak

In the reviewed native freeze, `rebirth/src/rust/rebirth-llm/src/live_steering.rs`
lines 170–198 allocated the candidate dense buffer and scaled vector before
calling `verify_steering_layers()`. For an uncached layer with an initially-zero
coefficient and a nonzero direction, `probe.rs` lines 322–330 retained full base
rows while allocating another dense `InterventionSpec`, a sentinel vector and
the current captured row. `probe.rs` lines 357–390 also owned capture descriptors
and tree storage. The F6b ledger in `live_state.rs` lines 273–285 charged only
`8*H*D + 4*H` for the original/candidate/scaled buffers. The probe adds at least
`4*H*D + 4*H*unproven_layers + 8*H`, before its metadata and cache allocations.
These are relm-owned allocations, not excluded model/KV/backend memory.

This is an allocation-contract defect even if a small fixture happens to remain
below the total conservative envelope. The native/R twins agreeing with each
other does not prove completeness. The existing initial-zero test exercises the
path but does not establish the missing peak.

The parent authorized a bounded correction: retain the existing sentinel,
shape checks, tolerance and fresh-context semantics, but capture one scalar for
one layer at a time; charge the sentinel dense buffer/vector and compiled
descriptors explicitly. Capability-cache storage must have a known capacity,
and the live probe must not silently add an uncharged `todo` vector or opaque
tree allocations. A named additional probe component must reach the native
estimate, FFI, independent R sum and memory contract. This finding remains open
until that correction is frozen and its capacity/initial-zero controls execute.

### P2 — R workspace grew with ablations although the ledger counted steers

The initial `live_payload_state()` rebuilt its original steering audit by
calling `live_steering_table(job$model$interventions)` every state. That helper
allocated a logical vector of all intervention entries. `live_reply()` likewise
allowed that larger entry count before its vectorized validation and steering
membership check. The ledger uses only `S`, the number of original steers; an
ablation-only handle has `S=0` but could allocate arbitrarily larger workspace.
Admission used the same all-entry vector, so caching alone did not close the
complete bound.

The parent corrected this during the same review. Current
`rebirth/R/live-state.R:79` uses two scalar walks and an `integer(S)` index;
`live_prepare()` caches the original audit and includes its measured size in
`F`; `live_payload_state()` uses that cache; `live_reply()` checks both column
lengths and row count against `S` before vector operations, then checks membership
against cached steer IDs. `live_deliver()` supplies the cache without forcing
the original metadata. The associated helper regression covers an index after
1,000 ablations, `S=0`, an unforced metadata argument, no rescan and oversized
reply rejection. **Corrected in inspected source; execution pending.**

## Semantic conclusions from source inspection

- Commands remain partial and atomic. All indices, duplicate detection,
  coefficient bounds, scaled products and summed buffers are checked before the
  native setter. Rebuilding uses original entry order, f64 multiplication, each
  entry's f32 conversion and ordered f32 addition. Invalid commands cannot
  partially commit coefficients or revisions.
- Zero coefficients reach the full-buffer setter, clearing previous steering
  contributions. The separate ablation adapter is preserved. Identical/empty
  replies keep the revision; omitted entries retain their current coefficients.
- `generate_live_tokens()` publishes the worker's current coefficient audit and
  revision before accepting the next command. The observer runs after sampling
  token k and before decoding it; the next state reports source P+k for an
  update after state k. No historical tokens are decoded again.
- The command setter shares cancellation arbitration, while state/stream drains
  use `try_lock`. R callbacks execute outside these native locks. The mutexed
  setter can delay cancellation acceptance; its actual update/reservation cost
  therefore still needs measurement, rather than a claim of free updates.
- Cancellation/close suppress an unapplied reply. The dirty flag precedes the
  setter, and `Drop` restores the original adapter on ordinary failure, success
  and unwinding. A restoration failure invalidates and closes the native model;
  FFI refuses to return it to the R handle. Existing callback-error precedence
  and classed reply errors are retained.
- The independent three-layer NumPy fixture uses incremental K/V arrays and a
  wrong-replay control. Its native consumer checks 3,360 activation/logit values,
  token-event ordering, worker audit, zero/sign changes, ablation precedence and
  fresh baseline reproduction. This addresses a real historical-KV boundary;
  a two-layer final-block-only fixture would not establish it.

No further material semantic defect was identified in the scoped pass. This
statement does not close the allocation finding or substitute for execution.

## Remaining acceptance obligations

1. Finish and execute the targeted probe/capacity correction and its native/R
   twin controls, including an uncached initially-zero direction and the
   cache-hit path. Verify the compiled charge covers actual retained capacities.
2. Preserve the failed first pipeline: the parent reported clippy stopped on
   the enlarged `AsyncStartFailure` error variant before any test executed.
   The authorized boxing correction must preserve sole ownership and account
   for its heap allocation; this is a build gate, not a numerical failure.
3. Execute the frozen native arithmetic, independent history golden, command
   protocol, invalid-reply, cancel/close, setter/reset/panic ownership and
   initial-zero cases, plus the affected FFI/R tests. Formula equality alone is
   insufficient: keep actual materialized-object and capacity assertions.
4. Execute the installed public R cases using the cached model, including
   partial replies, ablation, callback/reply failures and close after an applied
   update. Retain unchanged seeded generation and unchanged metadata evidence.
5. Measure coefficient-update and scheduler-reservation latency on the supported
   backend scope and complete the planned focused interactive demonstration.
   Earlier F6a capture-only CPU/Metal timings do not measure a changing adapter.
6. Run the affected ordinary Mac/Linux gates and the scoped steering sanitizer
   selection. Harness controls validate selection/provenance, not execution of
   these new product paths. Do not label F6b accepted until those results exist.

These obligations permit targeted correction verification; they do not request
another broad review or any unapproved API, dependency, tolerance or vendor change.

## Targeted correction status — same review, 2026-10-03

The native owner froze the correction in
`/private/tmp/relm-f6b/revision-ready.json`. The reviewer independently checked
all nine listed SHA256 values against the current files; all matched. The
corrected probe is `a4c006e8980057dfd36327828e4e933379f7cd45699a90cfbf2210f6ce01ba3d`
and the native ledger is
`07ecab01a3fbeefb77498ae55aecb370c6d6d463eb2a0a08ed870a58c09a9126`.
Only the already identified corrections and their propagation were inspected.

**P1 is corrected at source level; execution acceptance remains pending.**
`probe.rs:241` now has a fixed scalar capture descriptor. The callback selects
the same residual name/layer, checks the full row element/byte shape and reads
only the existing sentinel coordinate. `verify_steering_layers()` iterates
requested layers without a new `todo` allocation. Each uncached layer uses two
sequential fresh contexts, the unchanged sentinel and `steer_shift_ok()`; it
retains no full-row maps and does not touch generation KV. The steering cache is
`Box<[bool]>` of exactly D elements, initialized at model load. Lookup and marking
do not allocate; the ablation cache is unchanged.

For `S>0`, the separate charge is now:

```
steering_probe_bytes = 4*H*D + 4*H + D*sizeof(bool)
                       + steering_probe_fixed_bytes
```

Both new fields are zero for `S=0`. The compiled fixed charge in
`probe.rs:318` contains `InterventionSpec`, the sentinel vector and fixed-cache
descriptors, and twice the scalar-capture/context/batch descriptors plus the
single-token batch backing allocations. The latter were checked against
`llama-batch.cpp:945`: four i32 values, two sequence pointers and one i8 flag per
batch. Counting both sequential contexts is conservative. `live_state.rs:295`
adds the component to `transient_bytes`; FFI `live_boundary.rs:418` exports both
fields; R `live-state.R:415` independently reconstructs the variable terms and
includes the result in the checked total. The memory contract names the same
component. The native initial-zero and shape controls now assert its formula
and fixed cache size, but this reviewer did not execute them.

**The startup-error boxing correction preserves ownership in inspected source.**
Every failure return owns `Box<AsyncStartFailure>` with the model, permit and
error. Its existing `Drop` still destroys an unreturned model while bound to the
permit; the FFI failure arm takes the same model back before releasing ownership.
`async_job.rs:248` adds `sizeof(AsyncStartFailure)` to the compiled live control
charge even though startup failure and a running worker cannot coexist. The
original clippy failure remains historical evidence; a clean corrected build
and startup-ownership executions are still required.

P2 remains corrected as described above. No additional source-level blocker was
identified in this targeted closure. The parent reports corrected pipeline
PID 14632 running 23 affected outcomes; no outcome is asserted here. Actual
capacity, installed-model, update-latency, interactive and sanitizer acceptance
remain pending until their execution receipts exist.
