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
| `ProjectionProof` | fixed context/producer identity, proven bit, site ordinal/status, optional owned tensor/buffer POD and receipt-reported bit | All 32 slots, including the fixed metadata, are charged by compiled `Runtime` size even for one site. No tensor/data pointer, model-layer-sized or graph-count-sized collection. |
| `ProjectionDecode` | decode/microbatch counters, 32 fixed occurrence counters, pending site/role, checked transfer counters, callback-thread identity | Inline in runtime. Reset at every decode/microbatch; never stores a tensor/data pointer. |
| `ProjectionFault` | fixed reason enum plus scalar site/row/status values | Inline first-error latch. Format an R-facing error only after decode. No allocated error string in the callback. |
| `ProjectionProbeState` | two `Box<[f32]>`, each H: baseline producer and baseline immediate consumer; fixed scalar comparison/status fields | One boxed observer, used for one site at a time. It moves between sequential baseline/edited probe contexts after the previous native context has been freed. |
| C++ `ProjectionTensorInfo` / classifier frame | F32/type/op/role/layout/extent codes, fixed scalar fields and bounded buffer/type/device identity receipt | POD out-parameter and fixed stack frame; complete NUL-terminated type/device/registry names occupy fixed 32/32/16-byte arrays. No STL container, allocation or Rust `ggml_tensor` layout. Two coexisting info PODs plus the compiled identity-access frame are charged separately from retained runtime slots. |

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

The generic host-buffer predicate remains the first fast path. Pinned Metal
shared, private and mapped buffers all report `is_host == false`; that predicate
alone cannot identify shared Metal storage. For a nonhost buffer, require actual
pointer identity with the registered MTL registry, its indexed GPU device and
that device's default buffer type, together with exact canonical `MTL<digits>`
shared-type/device names. Names alone never authorize access. In the pinned
backend, the initialized immutable `use_shared_buffers` property both selects
the distinct default shared singleton and gates the shared allocation request;
the joint identity checks therefore exclude the private fallback. No environment,
buffer policy or vendor state is changed. Classifier, row get/set and immediate
consumer access use the same predicate and preserve shape/data/usage/alias guards.

Before row access the first nonempty selected ready producer records fixed owned
metadata; decode completion prints it once per context/site outside the callback.
Inherited contexts reset their receipt slots. Actual tiny-Llama and cached-Qwen
Metal receipts must establish the shared kind, registry/default/device identity,
original nonhost flag, complete bounded names, usage and tensor extent alongside
backend/offload and numerical gates. Static source reasoning is not execution.
The shared setter is synchronous memcpy after scheduler synchronization. Private,
mapped, unknown and spoofed identities remain unsupported; the private setter's
staging allocation/completion behavior is not covered by this one-row ledger.

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
For the actual same-row readback check, the existing producer box is overwritten
with the edited decode's current pre-row. One f32 `baseline_signal` in `Probe`
retains the original removed coordinate for the downstream expectation; its
compiled size and padding are included by `size_of::<Probe>()`. The canonical
axis readback must match zero at the selected coordinate and that current pre-row
elsewhere within `2e-6 * (1 + abs(expected))`. Consumer comparisons keep the
independent downstream absolute tolerance 0.01. Probe payload remains 20H.
Private forward audits read the post-write tensor storage and independently
evaluate the scalar equation from each retained pre-row and actual plan Site,
without another H-vector. These are 2,944 same-row coordinate comparisons for
the full 15-case reference and 704 for the three-case microbatch subset. They
are reported separately from the unchanged 34,748 and 10,042 whole-forward
comparisons in `F6E_PROJECTION_SAME_ROW` (maximum scaled error limit 2e-6).
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
| `derive_frame_bytes` | actual request/profile/estimate, entry Vec, two Arc handles, one independent Site, error owner/frame, execution/mutex guards and FFI command descriptors |
| `callback_frame_bytes` | two `ProjectionInfo` values, `ArithmeticFrame`, runtime mutex guard, and C++ access/name frames; retained Metal receipts are already in the 32 Runtime proofs |
| `probe_frame_bytes` | explicit probe frame, Batch descriptor and exact one-token batch allocations |
| `ffi_fixed_bytes` | new FFI boundary/result/metadata owner descriptors not already embedded above; enumerate each actual type once |
| `error_format_bytes` | maximum of the static admission/context/budget failures and two adapter-setter grammars and decode-status grammar (signed-i32 11 bytes, usize 20); fixed formatting frame and one exact String copy |

Arc layout is expressed as `align_up(2*sizeof(usize), align_of(T)) + sizeof(T)`
for a sized value, or the aligned header plus the slice data for directions.
Tests must compare the layout computation with the actual allocation path; do
not assume the fat Arc pointer is the allocation's header. Rust stack descriptor
charges above are conservative additions to requested owned heap bytes; global
allocator bookkeeping and engine allocations are not presented as exact RSS.
Exact slice capacities, not requested logical lengths alone, are checked at the
owned boundary. Any changed type/capacity changes the profile and twin result.
Construct error text in `ErrorFrame`, a fixed byte array plus length sized from the declared error grammar
(included with `fmt::Arguments` in `derive_frame_bytes`) and make one exact owned copy afterward;
do not assume the geometric capacity of `format!` fits `error_format_bytes`.

A representable total above the valid caller budget returns the existing
`RebirthError::Oom` with the actual `estimate_bytes` and `budget_bytes`.
Invalid input and checked-arithmetic/representability failures retain
`RebirthError::Intervention`. The fixed budget suggestion is
"Projection owners and working copies exceed max_bytes. Reduce projection sites or increase max_bytes."
It fits the existing 150-byte error grammar; the enum and formatting-frame
layouts do not change. The projection FFI borrows this exact owned text for its
message and returns exactly two numeric fields, `estimate_bytes` and
`budget_bytes`, without calling the generic allocating `Display`/human-size path.
The measured R failure envelope must cover the larger of the existing
Intervention prototype and this two-double OOM prototype. The native response
charge now explicitly takes the maximum with the compiled error-array/iterator/
result descriptor sum; the focused regression requires it to remain within the
existing 1512-byte response charge on the supported 64-bit profile. No ledger
field, budget threshold, scalar formula or numeric tolerance is changed. These
source corrections require their own model-free native/R-hosted execution;
earlier profile and installed failure receipts retain their original sources.

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
               + 8HS + 4S + 16A            # five existing FFI array payloads
```

Also charge the exact Vec/spec/baseline/FFI descriptors in
`adapter_fixed_bytes`, any actual source/candidate metadata String capacities in
`metadata_bytes` (zero for the new handle-only projection boundary), and the measured R residual-adapter payload/working copies in
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
             + N_projection + N_residual_probe + N_adapter_data + adapter_fixed_bytes
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

### Implemented internal profile/estimate boundary (unarmed)

The compiled implementation is `projection_layout.rs` / `projection_profile.rs`
and `rebirth-ffi/src/projection_boundary.rs`. The real owner types and dormant
`LiveDispatcher::projection` slot are compiled in ordinary and test builds.
Only `cfg(test)` compiles their arming/callback/probe methods. Moving the types
has not introduced a product derive or tensor-mutation entry point. The existing
live estimate reads the changed `size_of::<LiveDispatcher>()`; the focused
profile/FFI case checks this affected charge rather than rerunning F6a.

The internal `.Call` functions are:

```
rebirth_projection_allocation_profile() -> named numeric list (27 fields)
rebirth_projection_preflight(ptr, config) ->
    list(ok=TRUE, armed=FALSE, profile, inputs, terms)
```

`config` is exactly 11 unique fields: `mode`, `layer`, `component`, `coef`,
`direction`, `steer_entries`, `ablate_entries`, `existing_direction_estimate`,
`r_projection_fixed_bytes`, `r_adapter_bytes`, `max_bytes`. Mode is exactly
`new_site` or `inherit`; the former converts one positive R layer to native
zero-based, accepts `mlp_out`/`attn_out`, and borrows a plain non-ALTREP numeric
unit direction. Inherit requires layer 0, component `mlp_out`, coefficient 0,
and an empty numeric direction. Scalar counts must be finite exact nonnegative
integers below 2^53. Coefficients obey the strict finite f32 range. Width, depth,
backend, prior plan/count and source baseline capacity come from the live native
owner, not the supplied configuration. A poisoned owner, shape mismatch,
duplicate new site or source steering omitted by a zero entry count is refused.
The pure checked equation interface is also exported to the internal FFI crate;
it cannot allocate or install a projection.

The current constructor profile is version 2 (27 fields); retained version-1
receipts remain evidence for their original unarmed source only. Field order:

```
version, direction_arc_header_bytes, plan_arc_bytes, site_bytes,
runtime_bytes, probe_state_bytes, model_owner_bytes, derive_frame_bytes,
callback_frame_bytes, probe_frame_bytes, residual_probe_fixed_bytes,
ffi_fixed_bytes, adapter_fixed_bytes,
error_format_bytes, metadata_owner_bytes, slot_bytes, proof_bytes,
projection_info_bytes, cpp_access_frame_bytes, cpp_name_frame_bytes,
ffi_command_bytes, ffi_response_bytes, ffi_registry_bytes, ffi_handle_tag_bytes, layout_checksum,
max_sites, max_width
```

`layout_checksum` is a 52-bit checksum of actual field offsets, including every
retained Metal receipt field; it is a layout identifier, not a cryptographic
source receipt. Every returned integer is exactly representable by R doubles.
`model_owner_bytes` counts inline Context only inside LoadedModel. Runtime
contains all 32 Proof slots and their optional fixed `ProjectionInfo` PODs;
no extra per-state diagnostic Strings/Vecs are introduced.

The FFI terms are compiled from their actual types:

- `ffi_command_bytes`: `ProjectionScalars`, borrowed `ProjectionCommand`, one
  List and three Robj owners; five borrowed Robj references, borrowed
  `ProjectionResidualArrays`, a candidate Rc pointer, model Ref, registry RefMut,
  NativeGuard, two shell Robj owners, independent Box<dyn Any> and its outer
  Box pointer, plus the compiled installed-R-header shell frame. These are
  simultaneous descriptors or conservative non-overlap additions, not invented
  storage. The direction is borrowed here; its Arc is paid in `N_directions`.
- `adapter_fixed_bytes`: InterventionSpec, independent f32 conversion Vec and
  the five FFI Vec descriptors (three i32, two f64). The authoritative baseline
  Vec descriptor is inline in LoadedModel and is not added twice.
- `ffi_fixed_bytes`: two handle/Rc control shells excluding the already-counted
  inline LoadedModel, each actual extendr heap Box<dyn Any> and ExternalPtr
  descriptor, plus `ffi_response_bytes` and `ffi_registry_bytes`.
- `ffi_response_bytes`: the exact 27/15/14 named-scalar arrays, five root Robj and
  name slots, four List owners and their borrowed scalar iterator. Construction
  uses `from_names_and_values`, avoiding `from_pairs`' extra native name/value
  Vecs. R owns the actual lists/names/CHARSXPs; they must be in the measured R
  configuration/response skeleton.
- `ffi_registry_bytes`: current weak-registry capacity plus a candidate exact
  capacity of old capacity+1, each times sizeof Weak, plus its Vec descriptor.
  This includes possible old/new allocation coexistence. Final registration must
  use/check that exact reservation and revalidate the profile before transfer.
- `ffi_handle_tag_bytes`: actual UTF-8 length of type_name::<LlmHandle>().
  extendr creates one R character-vector tag per external pointer; source and
  candidate share its interned CHARSXP. Empty external-pointer skeletons need
  the explicit two `r(8)` tag vectors plus `r(B_tag+1)` (176 bytes on the accepted
  R profile). Actual populated `object.size()` measurements do include the tags;
  they must not receive that increment again. This is R storage, not native
  metadata. The source/candidate environment, finalizer and tag inventory is
  specified in [the R ownership contract](f6e-r-ownership-contract.md).
- `metadata_owner_bytes`, input `metadata_bytes` and `metadata_scratch_bytes` are
  zero by construction: preflight uses scalar getters and a seven-byte stack
  architecture buffer. The future projection derive returns a handle only and
  R reuses immutable source model metadata; it must not call the ordinary
  `metadata()`/`ok_payload()` String-copy path. Ordinary intervention APIs retain
  their existing return shape.

Inputs has exactly 15 fields: `mode` (0 inherit, 1 new), `hidden_size`, `layers`,
`previous_sites`, `steer_entries`, `ablate_entries`, `source_baseline_values`,
`metadata_bytes`, `metadata_scratch_bytes`, `existing_direction_estimate`,
`r_projection_fixed_bytes`, `r_adapter_bytes`, `max_bytes`, `backend`
(0 CPU, 1 Metal, 2 CUDA), `production_armed` (0).

Terms has exactly 14 fields: `direction_bytes`, `plan_bytes`, `context_bytes`,
`frame_bytes`, `probe_bytes`, `projection_bytes`, `residual_probe_bytes`,
`adapter_data_bytes`,
`adapter_fixed_bytes`, `metadata_bytes`, `r_projection_bytes`, `r_adapter_bytes`,
`existing_direction_estimate`, `total_bytes`. Metadata term sums the two input
metadata fields and the profile metadata owner field. Total is the sum of
projection, residual probe, adapter data/fixed, metadata, R projection/adapter and existing
estimate; subterms of `projection_bytes` are not added a second time.

For inherit-only P>0, direction bytes are `P*(8H+header)`, plan bytes are
`plan_arc_bytes+P*site_bytes`, contexts are `2*(4H+runtime_bytes)+2*model_owner_bytes`.
It shares one complete Plan Arc and the same unique direction Arcs. One scalar
probe peak and the fixed frames remain; `R_projection=F+P*g(8H)`. At P=0 both
projection and R-projection terms are zero. Native tests additionally verify
actual Arc pointer sharing rather than relying solely on the equation.

`validate_adapter_capacities` checks ten actual capacities before ownership
transfer: steer-layer/vector, ablate-layer/neuron/value, spec steer/mask/add,
one conversion row and candidate baseline. Oversized spare storage is refused,
not hidden behind logical lengths. Source baseline capacity is measured directly.
Source ablation remains installed engine state; its accumulated host spec must
be reconstructed/validated on the later derive boundary, using the five arrays.
Existing residual proofs are reused. The actual private constructor separately
admits `residual_probe_bytes` before copies, so a legitimate uncached steer or
ablation can run the bounded scalar sentinel in section 4.6. The older unarmed
`projection_validate_transfer` helper retains its cache-only refusal contract.

This is the implemented allocation/admission boundary, not completed production
integration. Still required before arming: independent R equation/profile parity;
verify the new actual constructor and its owner-controlled tiny fixtures;
bind the parent-owned R construction inventory to the full version-2 combined
budget; then enable the public route and prove public lifecycle/composition.
The source implementation of exact native construction/registration is described
below; it has not been executed by the implementing agent. The private feasibility constructor
retains its separately accepted test-only gate. No model/decode/test execution
was performed while adding this profile.

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
two coexisting FFI info PODs, compiled C++ identity-access and name frames,
error descriptor/text bound; there is
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

### 4.5 Unarmed transfer validation and source-state inspection

The transfer helpers do not construct a model or arm the dispatcher.
`LoadedModel::projection_validate_transfer(command, residual, ffi_profile)`
rereads dimensions, the current plan, backend and authoritative source steering
baseline capacity from the borrowed native handle. It refuses a failed steering
restore, unproved retained projection sites, invalid residual ranges/nonfinite
values, or excess dense-vector capacity. The FFI source check binds the exact
`Rc<HandleState>`; the final constructor must hold that source's model borrow and
native execution guard continuously through validation and registration.
A previous R receipt is not an identity token.

Residual capability checks are cache-only and separated from the projection
sentinel. The borrowed five-array FFI view validates lengths, indices and finite
f32 inputs before copying, and queries each used steering/ablation layer. Its
five slice descriptors fit inside the already charged five Vec descriptor
workspace; the view's scope must end before those owned vectors are created.
A second scan of the validated dense spec checks every nonidentity residual
layer against the same cache, without allocating a layer list or adding cache
entries. Missing capability is a classed refusal requiring a separately
admitted residual probe; this helper never executes one. These checks preserve
steer-sum/ablate-after-steer semantics. They do **not** authenticate R ablation
values against previously applied values: the engine discarded those original
inputs, and no extra retained authentication storage is introduced.

Exact registry registration rechecks the actual old capacity and its admitted
`ffi_registry_bytes`, verifies source membership and candidate freshness, then
reserves a replacement of exactly old capacity+1. It retains live weak entries
and inserts the candidate before replacing the old vector. Every failure keeps
the original registry intact. Both arrays and the replacement Vec descriptor
are already in the dynamic registry term. No R call may occur while this
registry transaction or the source model borrow is held. The result helper
returns only `list(ok, ptr)` and does not call `LoadedModel::metadata()`.

`rebirth_projection_state_facts(state, ptr)` is an internal inspection entry
returning exactly `hash_slots`, `bindings` and `c_finalizer_bytes`. The accessor
uses the installed `Rinternals.h`, with no copied object layout. Its first pass
checks empty parent, no environment attributes, exactly two ordinary names
`ptr`/`closed`, and no active binding, without reading their values or allocating
a hash-count vector. The second pass uses `Rf_findVarInFrame3`: the pinned R
implementation returns promises unforced, so they can be rejected explicitly.
It also rejects a mismatched pointer, attributes, ALTREP and any non-scalar or
nonlogical `closed` value. Official lookup can rebox at most two immediate
scalar bindings; the R query workspace explicitly charges 2×56=112 bytes.
The argument R objects protect the source environment and pointer; expanded
binding values remain rooted in that environment. Direct `CAR` access is not
used because R rejects it for immediate binding cells.

The C accessor reports its actual compiled frame size, including four pointer
arguments across the accessor and chain helper. The Rust query adds its POD,
two Robj owners, one List owner, three named-scalar descriptors and iterator.
`ffi_response_bytes` is the maximum of this complete query workspace and the
existing 26/15/13 profile-response workspace: they are separate calls and never
coexist. The hosted fixture records both actual numbers and checks coverage.
There is no new profile field, persistent model owner or projection layout.
The one C object is compiled by the existing R compiler flags into an archive
bundled in `librelm.a`, so scratch/package linking retains its existing flags.

Production still needs to connect the validated R owner inventory, borrowed
input gate, native re-admission, exact reservations, cached proof checks,
projection sentinel, atomic registry transfer and handle-only response into one
constructor. The unarmed helpers and model-free fixtures do not establish that
this complete constructor has run. The compiled closure-frame and current
context invariants remain subject to that final integration gate.


### 4.6 Actual private constructor (version 2, execution pending)

`projection-private` is default-off in both Rust crates and is not enabled by the
package build. Tests compile the same constructor using cfg(test); the private
FFI build forwards the feature. The only registered route is the internal
`rebirth_selftest_projection_constructor(path)` fixture, which refuses in a
default build. No registered product derive/operator exists. The unregistered
`projection_construct_boundary(ptr, config, five borrowed R objects)` is the
future transfer boundary; parent-owned public construction remains gated on
actual combined-budget parity and lifecycle verification.

`LoadedModel::projection_construct(command, ProjectionResidualArrays, ffi)`
returns only `(LoadedModel, ProjectionConstructionReceipt)`. The receipt contains
`adapter_capacities: [usize;10]`, `projection_probe_decodes: usize` and
`residual_probe_decodes: usize`; it is native scalar evidence, never returned as
model metadata. Arrays use existing one-based R indices, converted only after
borrowed validation. Native admission derives H/D/P0/backend, reads the source
baseline's exact capacity and checks its range/finite values, checks every old
projection proof, and refuses poisoned, vision or live-owned contexts. Inherit
requires an existing plan. All counts/scalars/direction shape and the complete
budget pass before the five exact Vec copies. No R preflight receipt is trusted
as model identity or as permission to allocate.

The three spec buffers and conversion row use exact reservations; ten capacities
are verified again after candidate baseline creation. The source's accumulated
ablation input remains a validated specification, not authenticated history.
Steer sums remain f32 in input order; nonfinite sums fail before any candidate
context is installed. Ablation remains last-write-wins after steering. New
projection sites share old f64 directions once, copy only the exact site array,
and allocate one new f64 Arc slice without an intermediate Vec. Inherit shares
the complete old Plan Arc. Every candidate receives its own H-f32 callback row.

The residual probe is now a separate, always conservative term:

```
N_residual_probe = 0                                if S=A=0
                 8HD + 4H + residual_probe_fixed_bytes otherwise
```

Each requested layer/type first consults the existing immutable capability
result. Uncached steering uses the existing shift-12 sentinel: baseline scalar
plus shifted scalar, two fresh contexts, one 4HD f32 spec and one 4H f32 row.
Uncached ablation uses one fresh context and the existing -17.5 scalar pin with
its unchanged 0.01 tolerance, retaining two 4HD buffers. Contexts are sequential,
no full-row BTree capture is retained, and this path inserts no BTree cache
nodes. A later derivation may prove a new kind again; cached proofs can skip it.
This supports legitimate residual additions without an uncharged old all-layer
probe. The conservative 8HD+4H term deliberately sums the two named maxima.

`residual_probe_fixed_bytes` is the compiled sum of InterventionSpec, Vec<f32>,
ProjectionResidualArrays, the capability MutexGuard, and twice the exact scalar
capture + TraceContext + Batch + one-token C-array descriptors. The latter is
four i32 values, two sequence pointers and one i8. The two sequential scalar
contexts are conservatively charged twice; their model/KV engine allocations
retain the existing separately declared engine envelope. Neither residual nor
projection probe excludes its relm-owned capture/dispatcher/adapter storage.

Version-2 `derive_frame_bytes` additionally charges the construction receipt,
two borrowed-array descriptors, an independent Arc<[f64]> descriptor, and two
Runtime values that may coexist with boxed destinations at candidate/probe
installation; it assumes no optimizer-dependent stack elision. Remaining
request/profile/result, entry Vec, two Arc<Plan> handles, Site, error/format
frames, NativeGuard and runtime MutexGuard retain their explicit sizeof terms.
Profile/result sizeof and FFI response-array counts therefore change too. The
14-term total adds `residual_probe_bytes` once, outside `projection_bytes`.

The transfer's allocation/critical-section ordering is:

1. Parse/protect R inputs and prepare an R external pointer with NULL address,
   exact existing type tag and a null-safe C finalizer. Allocate the complete
   `list(ok=TRUE, ptr=...)` response before creating any Rust handle box or context.
2. Allocate the empty closed Rc/Any handle and install its pointer using official
   `R_SetExternalPtrAddr`, which cannot allocate/evaluate. The C finalizer clears
   tag/address first and drops its matching Box<Box<dyn Any>> at most once. A
   wrapper allocation failure therefore owns no native or Rust handle resource.
3. Recheck source identity/closed state after all R allocations. Acquire the
   native guard and retain the exact source model Ref. Recompute the actual
   registry-capacity profile, then hold the registry RefMut through construction
   and exact old-capacity+1 reservation. No R API/evaluation occurs in this region.
4. Build a fresh candidate preserving resolved n_batch/n_ubatch, run each
   projection's existing baseline/edited downstream sentinel before usable
   return, install adapters and exact baseline, and atomically register/open the
   candidate. Any failure drops its plan/context under the native guard while
   preserving the source and old registry. A cancelled/failed probe can poison
   only the throwaway context; a usable candidate is not returned.
5. Release all native borrows and return the already allocated handle-only
   response. Parent R closes this pointer if its later environment/finalizer
   assembly fails. No LoadedModel::metadata or ordinary ok_payload copy occurs.

The C shell helper adds its compiled frame (three pointer fields plus one pointer
argument) to ffi_command_bytes. Its registered finalizer uses the same R weakref
and native function-pointer storage already itemized by the parent R ownership
contract. No private R layout, initialization shim or dependency was added. The
previous installed-header state inspector and its opaque void-pointer ABI are
unchanged. The actual shell/null finalizer is exercised by the R-hosted fixture.

Ordinary production cloning retains its previous batch defaults. The private
constructor's dedicated clone helper preserves source n_batch/n_ubatch; the new
fixture asserts both actual values. Separate-context trace/embed calls refuse a
projected handle. A feature-enabled ordinary residual derive also refuses that
handle so it cannot silently lose its plan or bypass admission; the legitimate
inherit operation is the bounded constructor above. Default ordinary handles
retain their existing behavior. Static projections continue on the same live
generation dispatcher; public live construction/inventory binding remains a
parent integration gate, not an acceptance claim from these source edits.

New owner-run gates are three exact native constructor tests and one R-hosted
outcome. They include 12 independent residual-term/exact-budget pairs; tiny
source/plan identity, unsupported/invalidated/cancel/error/adapter-overflow
cleanup, clone configuration and separate-context refusals; one selected
240-logit frozen composition case with new and cached residual capabilities;
and actual R shell/registry/worker-loan/close/inherit transfer. No old numerical
suite, Qwen or performance benchmark is repeated. All execution is pending the
parent's detached source-frozen pipeline.

### 4.7 Registered private combined-boundary bridge

The constructor scope in section 4.6 has now passed its owner-run private gate
at `private-constructor-resume-20261008-024551`: four outcomes, 49 cases,
35 refusals and 240 frozen-reference logits, maximum absolute error
0.00184210506 under the unchanged 0.01 limit, plus 56 independently compared
R/native terms. The earlier compile failure remains retained. This acceptance
does not cover the complete public R owner inventory or activate the operator.

The internal registered bridge has exactly seven arguments:

```
rebirth_projection_construct(ptr, config,
    steer_layers, steer_vectors, ablate_layers, ablate_neurons, ablate_values)
```

`config` is the same exact eleven-field list as preflight. The five residual
arguments are plain, non-ALTREP integer/double arrays with existing one-based R
indices: integer steer layers, flattened double steer vectors, integer ablation
layers, integer ablation neurons, double ablation values. Projection direction
remains borrowed from config until admitted. In a build with
`projection-private`, the bridge calls the accepted constructor helper with the
transfer-failure seam fixed to false. Its success is exactly
`list(ok=TRUE, ptr=<externalptr>)`; errors use the existing classed payload.
There is no fault selector or model metadata in this call.

A default build registers the same internal arity for an explicit classed refusal,
`Projection construction is unavailable in this build.`, before input parsing
or model access. Registration is not default arming. No exported R function or
public `operator="project"` route has been enabled. Parent-owned R code can now
bind its actual source/candidate inventory and configured budget to this bridge
in a private-feature scratch DLL. All existing borrow/registry/cleanup ordering
in section 4.6 remains unchanged: R argument preparation precedes the native
critical region; the bridge adds no R call within that region.

The generated seven-argument extendr wrapper has a concrete additional native
frame. From extendr-macros 0.9.0 `wrappers.rs` (argument conversion at 549–601,
wrapper/result construction at 243–299), it owns seven SEXP arguments, seven
protected Robj locals and seven Robj function-argument clones. The inner
catch-unwind closure borrows seven Robj arguments. Charge both its result and
the generated wrapper's result descriptors, without assuming stack elision:

```
bridge_frame_bytes = sizeof([SEXP;7]) + 2*sizeof([Robj;7])
                   + sizeof([&Robj;7])
                   + sizeof(Result<Result<Robj, Box<dyn Error>>, Box<dyn Any+Send>>)
                   + sizeof(thread::Result<Result<Robj, RebirthError>>)
ffi_command_bytes = accepted_constructor_command_bytes + bridge_frame_bytes
```

This is an additive compiled change to the existing `ffi_command_bytes` field;
profile version 2, the 27/15/14 schemas, data/probe equations and all owned native
constructor types remain unchanged. `derive_frame_bytes` and the corresponding
total include the new command frame through their existing equation. These
Robj clones protect the same SEXPs and do not copy vector payloads; actual R
inventory is still the independently measured parent-owned input/config/output
inventory. The private compiled profile must be read afresh; retained earlier
profile values are not relabelled as measurements of this bridge.

A new model-free exact native test,
`tests::projection_bridge_compiled_frame` in rebirth-ffi, verifies the independent
scalar layout decomposition and inclusion in the actual FFI profile (two cases,
zero refusals). Owner recipes additionally check registered arity seven and
classed default/private-invalid-input responses from fresh respective DLLs,
without rerunning the accepted native constructor suite. The actual combined R
construction and cleanup tests remain the parent's next acceptance gate.

### 4.8 Normal-build activation after combined owner admission

The parent independently verified the actual combined R/native constructor gate
at `combined-token-binding-20261008-033744`: 27 R cases, five constructions,
42 independently recomputed terms, exact budget 1,273,947 bytes, and materialized
R ownership 1,210,312 bytes within its 1,245,080-byte R bound. Source/reset and
child-survival comparisons are exact lifecycle evidence, not new golden accuracy.
The failed no-vocabulary text-harness attempt remains retained separately.

The same bounded constructor, shared callback dispatcher and decode error check
now compile in the normal build. The seven-argument internal bridge forwards
the same borrowed inputs and retains the same R-allocation-before-native-borrow
and source/registry transaction ordering. Constructor/probe/C++/Arc/adapter
layouts and all 27 profile and 14 estimate fields are unchanged. The existing
15-field admission record now reports `production_armed=1`; the preflight
response still says `armed=FALSE` because that call constructs nothing.
There is **no new retained owner, vector capacity or constructor peak term**.
The accepted dynamic registry-capacity charge remains reread for each admission.

The fixed raw-token helper and R-hosted constructor selftest remain gated by
`projection-private`. Postconstruction reservation-failure injection is compiled
only for that harness. Native mutation-fault setters and private feasibility derivation
shortcuts remain cfg(test)-only; no product caller can select them. Scalar
buffer/failure receipts are emitted only in tests/private builds, while the same
bounded buffer-proof POD and callback frames remain charged in all builds.

Every ordinary text route uses the existing generation-context decode boundary:
raw/synchronous generation, text logits, asynchronous and streaming generation,
structured generation, and static projection with live additive revisions. The
callback edits precede live observation; callback failure is checked before
logits, state or tokens can be published. A failed projection poisons the
context and the async worker destroys it, returning the existing classed
intervention error and invalidation flag. Cancellation at a live-state boundary
retains the existing adapter restoration path. No new cancellation queue or
capture buffer is introduced.

Projected image generation refuses before tokenizer/file/encoder work; async
image requests additionally refuse before worker creation and return the same
owned model/permit failure payload. Image-encoder and image-embedding routes
also refuse. Projected trace and embedding calls refuse before separate-context
work. A direct native residual derive on a projected model must use the bounded
constructor and cannot silently discard the plan; R inheritance uses that
constructor with its complete admitted owner inventory. These refusal checks
inspect existing scalar flags and introduce no retained allocation.

Two new focused tests are prepared, not executed by the native owner:

- `projection_production::default_constructor_routes_and_owned_lifecycle` is an
  integration target whose linked library has no cfg(test) activation: 13 cases,
  nine refusals, 288 exact lifecycle logit comparisons, one tiny model load and
  two bounded constructions. It must run without `projection-private`.
- `async_job::tests::projection_static_live_restore_cancel_and_poison` uses the
  existing numeric-input and correlated-publication seams: ten cases, two
  terminal refusals, three exact post-edit live coordinates, one tiny load and
  one construction. It checks additive revisions, static-plan sharing,
  restoration, cancellation, stream ordering and failure before publication.

The no-vocabulary fixture does not establish public tokenizer/chat/structured
text behavior. Fresh default-DLL registration, actual public R binding and its
owner-budget twin, text/installed lifecycle/resource/evaluation/instrumented
checks remain parent-owned gates. Existing private numerical, CPU/Metal timing,
reference and constructor acceptance scopes are carried, not rerun here.
