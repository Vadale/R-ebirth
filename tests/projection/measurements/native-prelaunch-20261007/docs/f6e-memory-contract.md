# F6e native ownership, memory and feasibility plan

Date: 2026-10-07. D-046 is approved. This document specifies the next private
implementation; it is **not executed feasibility or memory acceptance**. Native
implementation starts only after the independent projection reference has been
checked and frozen in a separate commit and the owner authorizes that step.
No build, test, model run, vendor change or dependency change produced this plan.

Read with the [approved contract](f6e-projection-contract.md), the completed
[source analysis](f6e-native-feasibility.md), and the existing
[live memory contract](phase6-memory-contract.md). The latter's accepted limits
and F6a/F6b formulas are unchanged. The application budget remains the D045
`max_bytes`: default 64 MiB, whole 1–512 MiB. H is at most 65,536; the accumulated
plan has at most 32 distinct `(layer, component)` sites.

## 1 Ownership and exact capacities

The implementation uses these private types. Names below are the intended Rust
interface, not new R exports. Actual compiled sizes, including padding, are
published by a native allocation profile and independently checked at the FFI/R
boundary; this document does not assign guessed byte sizes to Rust structs.

| Owner/type | Contents and capacity | Allocation/lifetime |
|---|---|---|
| `ProjectionSite` | `u32` layer, fixed component enum, f64 coefficient, `Arc<[f64]>` direction | One entry per site. No vector normalization, weighted copy or string key. |
| `ProjectionPlan` | H, implementation revision, exact-length `Box<[ProjectionSite]>` | One `Arc<ProjectionPlan>` per independently constructed plan. All old direction Arcs are shared when adding one new site; only its H doubles are copied. |
| `ProjectionRuntime` | plan Arc, one `Box<[f32]>` of length H, `[ProjectionProof; 32]`, fixed decode counters, first-fault record, optional boxed probe observer | One boxed runtime per projected context. No growing map/cache or per-row allocation. |
| `ProjectionProof` | fixed context/producer identity, proven bit, site ordinal and status | All 32 slots are charged even for one site. No model-layer-sized or graph-count-sized collection. |
| `ProjectionDecode` | decode/microbatch counters, 32 fixed occurrence counters, pending site/role, checked transfer counters, callback-thread identity | Inline in runtime. Reset at every decode/microbatch; never stores a tensor/data pointer. |
| `ProjectionFault` | fixed reason enum plus scalar site/row/status values | Inline first-error latch. Format an R-facing error only after decode. No allocated error string in the callback. |
| `ProjectionProbeState` | two `Box<[f32]>`, each H: baseline producer and baseline immediate consumer; fixed scalar comparison/status fields | One boxed observer, used for one site at a time. It moves between sequential baseline/edited probe contexts after the previous native context has been freed. |
| C++ `ProjectionTensorInfo` / classifier frame | F32/type/op/role/layout/extent codes and fixed scalar fields | POD out-parameter and fixed stack frame. No STL container, allocation, copied name or Rust `ggml_tensor` layout. |

The context's existing boxed `LiveDispatcher` remains the **only installed eval
callback owner**. It gains a separate optional boxed projection runtime guarded
by a mutex; capture session Drop removes only capture. A dormant source context
does not allocate projection runtime/directions/row. A projected context with
all coefficients zero retains its admitted plan and H-row capacity, but performs
no projection tensor get/set or projection-only scheduler barrier.

Allocate exact slices directly. In particular, copy a borrowed R f64 slice
directly into its one Arc slice allocation, without an intermediate owned Vec.
Construct the site array at exact requested capacity and verify capacity before
boxing; use a fallible exact allocation path where available. Any temporary
Vec-to-Box/Arc copy in the actual implementation must either be eliminated or
added as a separate live allocation before admission. No `collect()` with an
unproved spare-capacity bound is allowed in the new path.

The plan is immutable after publication. `LoadedModel` queries it through its
context; it does not own a second independent direction set. A later ordinary
steer/ablate derivation inherits the complete projection plan by Arc, with a new
context/runtime/row, rather than reconstructing directions from R or discarding
them. Adding a projection creates a new entry array and shares the previous
directions. A duplicate site is rejected before copying the new direction.
Separate user-retained model handles retain their own contexts, as today; the
per-application bound includes the source and candidate, not an unobservable
global census of unrelated R objects.

## 2 Shared dispatch, classifier and failure boundary

The dispatcher takes a barrier when projection **or** live observation requires
the node. At ready it revalidates the current tensor, projects each actual row,
then permits live capture to read the edited values. Static projection remains
active without `on_state` and during logits. Capture's final-source-row filter
never limits projection. Projection covers each computed row in every prefill
chunk/microbatch and incremental decode, including the final layer's legitimately
pruned row set. The existing generation `decode_batch` remains the single
`n_batch` chokepoint.

The allocation-free `attn_norm-0` marker provides microbatch row counts, using
the existing single monotonic sequence contract. Check cumulative counts against
the current decode's token rows. Carry the decode's actual output-row policy:
under the present last-logit-only path, a final-layer MLP can have zero output
rows in an earlier microbatch and one in the final microbatch. A structurally
valid empty tensor, or an omitted final-layer MLP when that policy requires zero
rows, performs no read/write and is not a missing-site failure. Do not demand a
positive-sized backing buffer for a zero-byte operation. Conversely, omission
when at least one selected output row is required is a failure. Other supported
producers must match their actual computed row counts. New multi-sequence/output
policies need explicit qualification; they cannot reuse this accounting silently.

`projection.cpp`, compiled with the existing relm native bridge and pinned GGML
headers, supplies a finite classifier and synchronous row get/set wrappers.
Rust keeps tensors opaque. Initial supported grammar is:

| Architecture/site | Producer grammar | Excluded similarly named node |
|---|---|---|
| Dense Llama MLP | down-weight `MUL_MAT`, optional documented bias `ADD`, then optional scale `MUL`; final node named `ffn_out-<layer>` | Residual `ADD` also named `ffn_out`; every MoE/MUL_MAT_ID chain |
| Dense Llama attention | output-weight `MUL_MAT`, optional documented output scale `MUL`, then optional output bias `ADD`; final node named `attn_out-<layer>` | Pre-Wo `kqv_out`, residual sum, LoRA/unknown chains |
| Dense Qwen2 MLP | dense down-weight `MUL_MAT`, named `ffn_out-<layer>` | Any attention site or residual sum |

Each optional bias/scale operand must be the expected immutable model weight
role with the correct shape; an arbitrary ADD/MUL cannot masquerade as that
wrapper. Match pinned weight/name roles using bounded `GGML_MAX_NAME` inspection,
shape and flags, not allocated strings. At most two wrappers and one matmul are
followed, with their fixed source slots checked explicitly; no recursive graph
search or dynamically sized traversal stack. A new chain requires an explicit
classifier/fixture update. No generic promotion from the observation site's
architecture table is allowed.

At ask and ready require actual F32, hidden width H, contiguous two-dimensional
rows, checked byte extent and offsets, non-input/non-weight output, no view or
nonzero view offset, and the declared producer chain. Ready also checks backing
storage. Refuse overlapping producer storage with any input/weight/source range
examined by that finite grammar; do not assume a bias/scale in-place alias is
safe merely because its name matches. Ordinary later consumer reuse of the
completed producer buffer is permitted by the pinned allocator ordering, but
the private gate must exercise it. The local classifier cannot certify arbitrary
global alias graphs; unknown view/alias arrangements are unsupported, not an
excuse for unchecked writes. This conservative rule may refuse some otherwise
dense configurations with in-place optional wrappers; report the exact refusal.

Initial Metal qualification also requires a host-accessible shared compute
buffer, checked through the pinned public backend buffer predicate and retained
device receipt. Its setter is synchronous memcpy after scheduler synchronization.
The private-buffer setter currently allocates a staging Metal object and does
not inspect copy completion errors; it is not silently covered by the shared
M4 proof or this host-row ledger. A private/non-host buffer is an explicit
unsupported buffer mode until separately proved/accounted, not a CPU fallback.

The one-row loop reads H f32 values, accumulates the dot in ascending coordinate
order using f64, computes/checks each f64 update and casts it once into the same
row buffer. Write the row only after the entire row passes finite/strict-f32-range
checks. No dense H-by-H projector, f64 row copy, H-by-token capture or per-row
allocation. Alpha zero bypasses the arithmetic/read/write path exactly.

Every ready callback and every row boundary checks an allocation-free view of
the existing cancellation state. Catch panic at the C boundary. A first fault
disables further projection and capture, but does not rely on callback `false`
to abort the whole graph: the pinned scheduler only breaks its current split.
After `llama_decode`, check projection faults and completeness **before** logits,
sampling, state or token publication. A partial-write/backend/identity failure
poisons that derived context; subsequent operations fail, never run unprojected.
Async completion uses the existing `model_invalidated` ownership path. The
original handle/shared weights are unaffected. Cancellation between complete
decodes may use the ordinary cleared-KV cleanup; cancellation during a partially
projected decode must conservatively invalidate unless reset is separately proved.
The existing additive restoration guard still runs on every applicable exit.

Source anchors: [scheduler](../rebirth/src/llama.cpp/ggml/src/ggml-backend.cpp#L1802),
[Llama sites](../rebirth/src/llama.cpp/src/models/llama.cpp#L169),
[Qwen2 sites](../rebirth/src/llama.cpp/src/models/qwen2.cpp#L102),
[FFN wrappers](../rebirth/src/llama.cpp/src/llama-graph.cpp#L1880),
[attention wrappers](../rebirth/src/llama.cpp/src/llama-graph.cpp#L2842),
[allocator](../rebirth/src/llama.cpp/ggml/src/ggml-alloc.c#L631),
[context owner](../rebirth/src/rust/rebirth-llm/src/engine.rs#L280),
[decode boundary](../rebirth/src/rust/rebirth-llm/src/generate.rs#L497).

## 3 Downstream probe and bounded proof cache

Do not reuse the additive `steer_ok` verdict as projection evidence. For each
requested projection site, before returning the candidate, use a clean baseline
decode and an edited decode in **two sequential throwaway contexts**. Both use
the same resolved model/backend/offload, graph policy and context parameters as
the candidate. Only one probe context exists at a time. Backend/model/KV/graph
allocations remain the existing engine category, but their extra context and
possible OOM are real; relm dispatchers, plans, buffers and wrappers are charged
below. Do not silently clamp context configuration and then cache that result as
proof of a different configuration.

Use one fixed in-vocabulary token, one sequence and one actual row. The baseline
captures the selected producer and its immediate residual consumer, exactly two
H-wide f32 vectors. Choose the largest-magnitude finite producer coordinate
(lowest index on a tie); a zero/inconclusive signal fails capability. Build one
canonical unit f64 axis direction at that coordinate, coefficient one, and use
the **same classifier, arithmetic and row writer** as production. No alternate
probe-only setter is permitted. The canonical axis is a separate H-double Arc,
not a clone of every user direction.

During the edited decode, producer readback and downstream capture reuse the
runtime's single H-f32 row. Retain no third baseline/edited output vector. At
the selected producer verify the prescribed edit and unchanged other coordinates;
at the immediate consumer verify it consumed the edit. Llama attention's
consumer is `ffn_inp`; clean MLP's consumer is the residual ADD ending at `l_out`.
The probe classifier verifies that operand relationship. For the last-layer
attention gather, validate the one-row `GET_ROWS` route and its zero row index,
rather than treating any gather as identity. Read any needed residual operand
coordinate as a scalar at the consumer boundary, not a retained tensor pointer.
Scalar expectations and allowed rounding are frozen with the independent probe
controls before the first run; use the approved site/downstream tolerances,
never derive a tolerance from observed native error. Reject a zero delta even if
a loose absolute comparison would otherwise pass. Missing, read-only/no-write and
wrong-site injected bridges must all fail this same proof.

The baseline and edited decodes reuse one boxed probe workspace/runtime after
freeing the previous native context. Thus probe data is exactly:

```
baseline producer        4H
baseline consumer        4H
edit/readback/consumer   4H   # one shared runtime row
canonical axis           8H
                         ---
                         20H bytes
```

All boxed headers, the axis Arc header, one-site probe plan and 32-slot runtime
cache are additional compiled descriptor terms. This is independent of P and
prompt length. The source and candidate plan/runtime may coexist with this one
probe workspace; admission deliberately sums them rather than relying on allocator
reuse between stages. No cache entry is set until both producer and causal
consumer checks pass.

Proofs are **context-local**, not an expanding shared-model BTreeMap. They bind
the immutable model owner, resolved backend/offload, fixed context/graph policy,
site/layer, H and classifier implementation revision. A new derived context is
reproved; no stale proof is inherited through an Arc. Runtime reclassifies ask
and ready nodes on every graph execution, including reused one-token graphs and
different row counts. A parameter/policy/role change invalidates the proof and
fails before publication; it does not trigger an unbudgeted probe in generation.
Fixed occurrence counters reject missing/duplicate selected producers per
microbatch, independently of observation's first-`ffn_out` latch. Dense residual
duplicates are classified as non-producers, not counted as another site.

## 4 Arithmetic ledger and compiled profile

All arithmetic is checked u64 before allocation, then checked for usize/native
index representability. R twins use the existing checked 64-bit allocation
profile: `r(x) = 48 + pool(x)`, and `g(x) = r(x) - r(0)`, where pool is
0/8/16/32/48/64/128 for small
requests and otherwise rounds to eight bytes. Runtime fingerprint verification
is required. The projection estimate is **added** to the existing accepted
artifact/application estimate; no part is paid from its unexplained spare room.

Let P0 be the source's projection count, P=P0+1 for a new site, I0 indicate P0>0,
H the hidden width, and D the model depth. Counts/uniqueness/H/budget are validated
using borrowed inputs before making the new Arc or any FFI Vec. The common
inherit-only path shares a whole plan Arc; its admission counts the actual unique
plans/entry arrays, rather than pretending there is a newly copied direction set.

The following profile fields are `size_of`/`align_of` or exact owned capacities,
not handwritten architecture-dependent constants:

| Field | Meaning |
|---|---|
| `direction_arc_header_bytes` | two Arc counters plus alignment padding before `[f64]` |
| `plan_arc_bytes` | two counters, alignment and `size_of::<ProjectionPlan>()` |
| `site_bytes` | `size_of::<ProjectionSite>()` |
| `runtime_bytes` | complete boxed `ProjectionRuntime`, including all 32 proofs/counters and row/Arc descriptors |
| `probe_state_bytes` | complete boxed `ProjectionProbeState`, including both Box-slice descriptors |
| `model_owner_bytes` | complete relm `LoadedModel` value and its separate boxed `LiveDispatcher`; Context is inline and is not added again |
| `derive_frame_bytes` | explicit `ProjectionBuildFrame`, `ProjectionEstimate` and FFI command descriptor sizes |
| `callback_frame_bytes` | explicit Rust callback/row frame plus C++ classifier POD/frame sizes; fixed arrays and scalar work included |
| `probe_frame_bytes` | explicit probe frame, Batch descriptor and exact one-token batch allocations |
| `ffi_fixed_bytes` | new FFI boundary/result/metadata owner descriptors not already embedded above; enumerate each actual type once |
| `error_format_bytes` | exact maximum formatted projection-error UTF-8 length, derived from fixed messages and decimal widths of its scalar fields; one owned result copy |

Arc layout is expressed as `align_up(2*sizeof(usize), align_of(T)) + sizeof(T)`
for a sized value, or the aligned header plus the slice data for directions.
Tests must compare the layout computation with the actual allocation path; do
not assume the fat Arc pointer is the allocation's header. Rust stack descriptor
charges above are conservative additions to requested owned heap bytes; global
allocator bookkeeping and engine allocations are not presented as exact RSS.
Exact slice capacities, not requested logical lengths alone, are checked at the
owned boundary. Any changed type/capacity changes the profile and twin result.
Construct error text in a fixed byte array sized from the declared error grammar
(included in `derive_frame_bytes`) and make one exact owned copy afterward;
do not assume the geometric capacity of `format!` fits `error_format_bytes`.

For a new-site derivation, the native projection terms are:

```
N_directions = P * (8H + direction_arc_header_bytes)
N_plans      = (I0 + 1) * plan_arc_bytes + (P0 + P) * site_bytes
N_contexts   = (I0 + 1) * (4H + runtime_bytes) + 2 * model_owner_bytes
N_frames     = derive_frame_bytes + callback_frame_bytes + ffi_fixed_bytes
             + error_format_bytes
N_probe      = 20H + direction_arc_header_bytes + plan_arc_bytes + site_bytes
             + runtime_bytes + probe_state_bytes + model_owner_bytes
             + probe_frame_bytes
N_projection = N_directions + N_plans + N_contexts + N_frames + N_probe
```

The unique P direction allocations are counted once across source/candidate;
their two independent entry arrays are both counted. The one probe axis is
separate. The maximum direction data is 16,777,216 bytes at P32/H65536; a runtime
row is 262,144 bytes, and the probe's four named data buffers sum to 1,310,720
bytes. These figures exclude the explicitly additive compiled descriptors.
Zero coefficients do not reduce admission. With no projection request/plan,
all new projection terms are zero; the ordinary dispatcher path stays dormant.

One probe Batch of capacity one, zero embedding width and one sequence allocates
exactly four i32 values, two sequence pointers and one i8, in addition to its
Rust descriptor. This follows pinned `llama_batch_init`; a different batch
capacity must update the formula, not be covered by an allowance. The native
probe does not request a full-vocabulary copy or retain logits.

### Accumulated residual adapters and FFI copies

Projection derivation retains the full existing additive/ablation specification.
Current native derive keeps an authoritative steering baseline but reconstructs
ablation from `InterventionSpec`; it is not legitimate to omit these host buffers
as “model/KV.” For the existing owned-Vec FFI adapter path, let S be accumulated
steer entries, A expanded ablation coordinate entries, Is/Ia their presence bits,
and Cb the source baseline's actual f32 capacity. Charge:

```
N_adapter_data = 4Cb                         # source authoritative baseline
               + 4HD * (2Is + 2Ia)         # spec steer + candidate baseline;
                                             # spec mask + spec add
               + 4H * Is                   # one conversion vector
               + 8HS + 4S + 16A            # six existing FFI array payloads
```

Also charge the exact Vec/spec/baseline/FFI descriptors in
`adapter_fixed_bytes`, actual source/candidate metadata String capacities in
`metadata_bytes`, and the measured R residual-adapter payload/working copies in
`r_adapter_bytes`. No projection-specific D-by-H buffer is introduced. Use the
actual capacities if an existing buffer is larger than the formula's logical
size. Existing source interventions have already been proved; this path must not
accidentally rerun an allocating all-layer residual probe. If a derive operation
adds an unproved residual intervention, its existing probe peak must be charged
separately before the new path is admitted. That is not included in the scalar
projection probe above.

The initial private projection gate uses no FFI/residual adapter payload except
the declared composition cases; public arming waits for this complete combined
ledger. The eventual boundary can reduce copies by borrowing, but must update
both twins and preserve ordinary APIs rather than subtract a speculative saving.

### R ownership and total admission

The R side measures `r_projection_fixed_bytes` from the exact simultaneous
source/candidate projection records, normalized native command and return-payload
skeletons, using empty direction vectors but real metadata, names and P0/P list
capacities. It scans existing entries one at a time; it does not materialize a
second complete intervention list merely to estimate it. Existing immutable
direction SEXPs reused by candidate records are counted once. Allow two new plain
H-double owners: the retained new entry and the normalized FFI direction, with
no extra hidden canonicalization copy after admission. Therefore:

```
R_projection = r_projection_fixed_bytes + (P0 + 2) * g(8H)
R_extra      = R_projection + r_adapter_bytes
estimate     = existing_direction_estimate
             + N_projection + N_adapter_data + adapter_fixed_bytes
             + metadata_bytes + R_extra
```

The measured skeleton includes the empty vector headers for these owned slots;
g adds their payload growth. Candidate references to old direction SEXPs do not
add another direction payload. Repeated metadata/header accounting in measured
R prototypes is conservative; it does not imply a duplicate numeric allocation.
The existing direction estimate remains intact; overlap with its conservative
validation workspace is deliberately charged again, not subtracted. This does
not claim a second native allocation of shared directions. Measure the actual
R objects retained at construction stages and reject an implementation/profile
violation rather than silently raising max_bytes. Strings/attributes already
included in a measured skeleton must not be reintroduced as an unbounded copy
inside the native callback.

Expose a private `ProjectionEstimate` with the named terms, input counts,
profile version and compiled fields above. R independently computes every
variable term and requires exact equality before native derivation. Native
rechecks borrowed shape, native model dimensions, previous plan/count identity
and budget immediately before ownership transfer. Counts/overflow/32-site/H
refusals precede direction/plan/context allocation. The 8 MiB live transport,
32 MiB live materialized state and 2 GiB live spill limits remain unchanged:
projection directions are persistent application-owned model state, not a new
payload smuggled into the live queue. A simultaneous live call adds its existing
capture/reply estimate to the already admitted projection runtime; it does not
copy directions per state or charge an unbounded state history.

## 5 Private implementation surface and precise verification contract

After the independent golden commit is frozen, the first implementation is
private feasibility only. Planned minimal source changes:

1. `projection.rs`: immutable types, checked row arithmetic, estimate/profile,
   fixed runtime and probe; `projection_tests.rs`: independent fixture consumers.
2. Native `projection.cpp`, its C declarations, CMake/build rerun registration:
   finite classifier/POD layout and bounded row IO; no vendored file changes.
3. `live_capture.rs`: one combined dispatcher, project-before-observe ordering,
   separate session/plan lifetime and outside-decode error/completeness checks.
4. `engine.rs` / `generate.rs`: private plan attachment, context invalidation and
   probe builder; preserve callback-free test loader and the decode chokepoint.
5. `intervene.rs`: retain inherited projection owner on derived contexts;
   `async_job.rs`: honor poisoned projection contexts in existing completion
   cleanup. No public R mode/FFI constructor is armed in this first gate.

Intended test-only entry:

```
derive_projection_for_test(source, borrowed_sites, full_residual_spec,
                           ProjectionTestOptions) -> LoadedModel
ProjectionTestOptions { probe_fault, callback_mode }
callback_mode: CallbackFree | Dormant | Production
probe_fault: None | MissingProducer | NoWrite | WrongSite | FailAfterRow
```

The faults are `cfg(test)` only, injected into the same probe/runtime path, and
cannot be selected by R or an environment variable in product code. Numerical
tests consume committed numeric token IDs, raw producer/post-edit/consumer
vectors and logits; expected values come only from the independent frozen
manifest/CSVs. Streaming comparison accumulates counts/max error without keeping
all activations in memory. No sampler rewrite or full-prefix replacement of
incremental KV is allowed.

The settled reference interface is
`tests/llm-golden/projection/goldens/`: `arithmetic-inputs.csv`,
`arithmetic-expected.csv` and refusals for identical-row arithmetic;
`forward-cases.csv`, `forward-projections.csv`, `forward-tokens.csv`,
`forward-residual-interventions.csv`, `forward-sites.csv`,
`forward-activations.csv`, `forward-row-witnesses.csv` and `forward-logits.csv`
for the three-layer Llama forward. Public layer/neuron/source-position columns
are one-based; supplied native token IDs are zero-based. The current reference
declares 15 forward cases, including P513 plus one incremental token and retained
vectors at positions 1, 2, 128, 512, 513 and 514 with all-row scalar witnesses.
The final manifest and separate commit, not this pre-freeze count, govern the
collector. Cached Qwen2 proves its actual classifier/producer/consumer path and
same-row arithmetic; the Llama reference is not falsely called a Qwen2 full-model
oracle.

Tolerance scopes must remain distinct: binary64 scalar intermediates use
absolute-plus-relative 1e-12; checked f32 edits of the **identical supplied row**
use absolute-plus-relative 2e-6. Independently recomputed model producer/site,
activation and logit rows retain absolute 0.01 because their upstream model
kernels differ. Also check the native edit against its actual captured pre-row
with the fixed scalar formula, without feeding native values back into the
independent producer or regenerating a golden.

Planned exact nonignored test IDs (nine; must actually execute, not merely compile):

- `projection::tests::projection_row_matches_independent_reference`
- `projection::tests::projection_boundary_rejects_invalid_inputs`
- `projection::tests::projection_capacity_ledger_matches_owned_buffers`
- `projection::tests::projection_classifier_accepts_only_declared_dense_sites`
- `projection::tests::projection_probe_rejects_missing_noop_and_wrong_site`
- `projection::tests::projection_forward_matches_independent_reference`
- `projection::tests::projection_microbatches_pruning_and_graph_reuse`
- `projection::tests::projection_capture_and_static_additive_composition`
- `projection::tests::projection_cancel_fault_and_owner_cleanup`

These IDs are a driver contract, not invented passing counts. Fixture case/value
counts are pinned from the frozen independent manifest before compilation; the
collector requires positive executed case counts, positive comparison counts
for numerical cases and exact manifest equality. Forward cases
cover all three supported sites, first/last layers, zero/negative coefficients,
full incremental history and downstream consumer/logits. Resource tests cover
H65536/P32 boundaries without a large model, borrowed preflight refusal before
copy, Arc sharing versus entry-array copies, probe coexistence, exact capacities,
FFI/R twin arithmetic and all cleanup/fault exits. Tiny synthetic C++ graphs
exercise dense wrappers, duplicate residual names, wrong dtype/layout/views,
aliases, MoE/MUL_MAT_ID and unknown-chain refusal. Missing-node/fault paths must
be observable failures, not zero-work passes.

One additional ignored test is
`projection::tests::projection_feasibility_model`. It uses the cached Qwen model
for its declared MLP site and the committed tiny Llama fixture for its attention
site, without downloads. Same source/build/model/backend/settings for:
`callback_free`, `dormant`, `zero`, `active_one`, `active_multi`. Use a fixed
declared multi-site set (first/middle/last distinct MLP layers when available),
identical numeric prompt/token settings, one warmup per mode and three balanced
interleaved measured rounds. The fixed measured orders are:

1. callback_free, dormant, zero, active_one, active_multi;
2. active_multi, zero, callback_free, active_one, dormant;
3. active_one, dormant, active_multi, zero, callback_free.

Every mode occurs once per round and has the same mean ordinal position. Require
the declared token count in every run; early termination makes a timing sample
incomparable, not a reason to discard it and choose a replacement. Measure prefill
and incremental generation separately.
Release only: `debug_assertions` must be false. Preserve the existing dormant
median-ratio <=1.05 acceptance bound; zero is reported separately and must be
numerically exact. Active latency/transfer cost is reported, with **no invented
active threshold** and no rerun to select a favorable sample.

Each numerical test emits one JSON marker `F6E_PROJECTION_TEST` containing:
`schema`, `test_id`, `source_manifest_sha256`, `reference_manifest_sha256`,
`model_sha256` when relevant, `expected_cases`, `executed_cases`,
`expected_values`, `compared_values`, `max_abs_error`, `max_rel_error`,
`negative_controls_expected`, `negative_controls_rejected`, `status`.
Finite comparisons use the already frozen tolerances; counters must match.

The benchmark emits `F6E_PROJECTION_BENCH` JSON with `schema`, source/reference/
model digests, `build_profile`, `debug_assertions`, resolved backend and native
receipt data, settings, ordered sample records, medians, dormant ratio/limit and
status. Every sample records `round`, `mode`, `prefill_seconds`,
`decode_seconds`, `decoded_tokens`, `site_rows`, `read_bytes`, `write_bytes` and
`barriers`; mode descriptors include exact native layer/component/alpha and
direction digest. Read/write counters use checked arithmetic and count actual
copies. CPU acceptance requires zero GPU layers and no GPU compute buffer.
Metal acceptance requires actual selected `Metal` or `MTL<digits>` device
identity, positive matching Metal compute buffer and actual positive offload
(the benchmark's configured full-offload policy requires all expected layers).
A label/request alone is not proof. Retain raw upstream logs, ordered samples,
source hashes and failed receipts. Do not call a missing receipt a GPU timing
failure or treat an exit-zero with no comparisons as success.

The owner launches one detached source-frozen affected pipeline: formatting,
clippy, these exact tests, then release CPU/actual-Metal feasibility. A failure
stops dependent public arming and is diagnosed from its retained source/logs.
No accepted F6a/b/c/d suite is rerun unchanged. A bridge placement, alias,
downstream or resource failure is a genuine gate; a graph-op vendor fallback
requires its own decision and is not silently substituted.

## 6 Ready boundary

Independent references were frozen separately at `d8a4800`. The owner then
authorized the private native gate. Its Rust module, plan attachment, dispatcher
extension, timing instrumentation and clone-configuration override are all
`cfg(test)`; ordinary package arming remains unavailable. The C++ bridge is a
relm-owned native source, compiled with the existing static bridge. No vendor,
dependency, R or rebirth-ffi source was changed by this milestone.

The implementation names the plan/site/runtime/probe types `Plan`, `Site`,
`Runtime` and `Probe`. It transfers the same two baseline vectors into the edited
probe; the canonical axis uses a directly initialized Arc slice. Probe data
therefore remains 20H. `Estimate` publishes direction, plan, runtime, probe,
frame and total native bytes. The frame term uses the actual `ArithmeticFrame`,
FFI POD, error descriptor/text bound and compiled C++ name-frame size; there is
no generic fixed reserve. The full residual spec's actual capacities, source
steering baseline and independent candidate baseline are checked additionally
before derivation. This private gate uses a fixed 64 MiB native admission ceiling;
the complete configurable R/FFI twin in section 4 must still be connected before
public application is armed.

Private fixture observation is separate from projection/probe storage: at most
128 retained row records, 128 requested positions, 2,048 scalar witnesses and
8 MiB including their capacities/descriptors. The benchmark and capability probe
do not enable it. It retains only the reference's requested positions and is
not a product capture API or an unbounded prompt-sized activation map.

The nine exact nonignored IDs in section 5 are present. Frozen numerical work is
13 scalar cases/52 output coordinates, 15 forward cases/34,748 comparisons, and
three microbatch/pruning cases/10,042 comparisons. Forward comparisons comprise
21,888 activations, 3,648 logits, 5,888 pre/post coordinates and 3,324 scalar
witness values; the pruning test also checks 144 last-logit values. The classifier
has 12 C++ controls, including view/type/layout/alias/MoE/wrong-weight refusal.
Missing/no-write/wrong-site probes, partial-write/cancel/panic ownership, original
isolation, capture-after-edit and real additive live replies have dedicated tests.

The ignored release benchmark uses the five declared modes and fixed orders,
128 tokens, n_batch512/n_ubatch128/context768, seed42, temperature0.8 and top_p0.95.
Its direction is a declared native-coordinate-1 unit axis; active sites are the
middle MLP layer and the distinct first/middle/last MLP layers. Before Metal
timing, it executes the 15-case tiny Llama forward reference on actual Metal once,
with the same backend/offload evidence and nested `tiny_forward` result. It does
not repeat the ordinary CPU forward gate in the CPU benchmark.

`F6E_PROJECTION_TEST` is emitted after each test's assertions. Its relative-error
field reports `abs(error)/(1+abs(reference))`. The benchmark emits each raw
`F6E_PROJECTION_SAMPLE` before token/parity/gate assertions so failed work remains
visible, and a `F6E_PROJECTION_BENCH` success marker only after all assertions.
Its receipt has actual `callback_free_backend`, `hooked_backend` and (Metal only)
`tiny_forward.backend` objects, raw ordered samples, five median total elapsed
times and the unchanged dormant ratio/1.05 bound. Prefill/decode fields measure
engine decode durations; total elapsed additionally includes sampling/output.
No active threshold is introduced.

Only rustfmt, C++ `-fsyntax-only`, file-link/fixture-count inspection and diff
whitespace checks were run by the native owner. No Rust compilation/linking,
test/model execution or performance result is claimed. Those are the parent's
single detached pipeline. R/FFI public implementation follows the private causal
gate and complete compiled/twinned admission ledger; approval of D046 does not
establish that either gate has passed.
