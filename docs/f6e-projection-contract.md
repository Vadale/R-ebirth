# F6e projection steering contract

Date: 2026-10-07. **D-046 / API-GRAMMAR section 14: APPROVED.** The founder
replied "vai continua" after the concrete D046 question and linked contract.
This approves the API, placement, compatibility and resource scope below.
Implementation, independent references and actual acceptance remain required;
approval is not a numerical or resource result. No vendor patch or dependency
change is authorized.

## 1 One extension to the existing application interface

Keep the constructor signature; append one optional argument to the application:

```r
llm_direction(target, control, context, layer,
              normalize_pairs = FALSE, orthogonalize = FALSE,
              max_bytes = 64 * 1024^2)

llm_apply_direction(m, direction, context, coef = 1,
                    max_bytes = 64 * 1024^2, operator = "add")
```

`operator` accepts exactly `"add"` or `"project"`, without partial matching.
Existing positional calls and the default additive residual operation retain
D045 behavior. There is no new exported function, dependency, inference runner,
loader option or automatic model/artifact download.

Construction now also accepts the declared full-width `mlp_out` and `attn_out`
capture profiles. A residual artifact remains `relm_direction/1`, with the same
schema, arithmetic, canonical encoding and digests as D045. New component
artifacts use `relm_direction/2`; the top-level component must equal the capture
component and participates in the payload digest. Other fields/types and the
paired arithmetic are unchanged. Each schema2 canonical stream uses ASCII
`relm_direction/2` followed by NUL, then the same typed domain and value body;
schema1 keeps its existing `relm_direction/1` prefix byte-for-byte. This applies
to every schema2 domain, including matrix/pairs/splits/context/values/artifact.
Freeze separate new schema-2 byte fixtures;
do not regenerate or relabel the accepted schema-1 references.

Residual artifacts remain restricted to layers `2:L`. Component artifacts may
name layers `1:L`. Matrix width is still the complete hidden/output width, not
head width or the MLP's intermediate expansion. The raw-text/last-position
capture profile and all D045 pair/split/size limits stay in force. Constructor
input is supplied data: it does not certify that the caller captured the claimed
component or that a particular model supports editing it.

Application requires the existing independently recorded destination model
context and validates provenance, schema, values, coordinate order, integrity
and handle compatibility before native derivation. `"add"` accepts only
schema-1 residual artifacts. `"project"` accepts only schema-2 `mlp_out` or
`attn_out` artifacts. Neither equal vector length nor an altered component label
establishes transfer. No implicit residual-to-MLP/attention conversion is allowed.
The stored and destination model records remain **recorded provenance, not
authentication of already-loaded weights**. Trusted caller RDS remains the only
persistence path; the existing bounded temporary-checksum-file exception applies.

## 2 Exact operation and initial supported sites

For the validated unit direction `v`, apply on each executed token column:

`h_new = h - coef * v * sum(v * h)`.

`coef = 0` is an exact no-op, `1` removes the parallel component within the
frozen floating-point bound, `-1` doubles it, and values above one can reverse
it. `v` and `-v` produce the same projection operator. This is different from
the signed addition of a contrast vector. It changes activations, not weights.

The native copy of `v` remains f64. Accumulate the dot product in ascending
coordinate order in f64, calculate each update in f64, check finiteness and f32
range, then cast once to the existing f32 tensor. Do not silently renormalize,
clip coefficients, omit coordinates, rescale overflowing output or use a new
vendor kernel. `coef` must be a plain finite scalar within the existing f32
coefficient range; malformed arguments and nonfinite computed rows fail with
classed conditions. A zero coefficient bypasses tensor copying/writing.

Initial application support, contingent on actual feasibility acceptance:

| Model graph | Component | Exact site |
| --- | --- | --- |
| Dense `llama` | `attn_out` | Post-`Wo` attention output, including its existing output bias/scale, before the residual addition |
| Dense `llama` | `mlp_out` | Raw dense feed-forward output before the residual addition, not the later same-named residual sum |
| Dense `qwen2` | `mlp_out` | Raw `ffn_out` before the residual addition |

CPU and Metal are required; CUDA/Windows and other architecture/site combinations
are explicitly unsupported by this increment. Qwen2's unnamed post-`Wo` result
must not be replaced with a pre-projection attention tensor. A Llama architecture
label alone does not prove a dense MLP: its MoE graph uses a different producer
and a misleading residual `ffn_out` name. Refuse MoE, unknown producer chains,
unsupported type/layout/alias roles and missing or duplicate sites before a
usable projected handle is returned. Existing trace support does not authorize
projection support on other graphs.

All actual rows and microbatches that reach the chosen producer are edited,
including prefill and later decoding. The final layer may omit unused rows under
llama.cpp's existing output pruning; do not synthesize those rows or promise
extra capture. Projection is independent of the narrower F6a observation filter.

## 3 Native placement and ownership

The recommended feasibility route is a **zero-vendor-patch** bridge through the
existing synchronous scheduler callback. At the pinned source, requested-node
computation and backend synchronization precede the ready callback, and the
following graph segment is submitted afterward. That supports investigation;
the documented callback is observational and this is not yet runtime proof of
safe editing, backend copying or graph-cache behavior. The focused
[source analysis](f6e-native-feasibility.md) records the exact pinned boundaries
and is not executed native acceptance. The initial Metal capability must verify
the actual buffer mode used; unproved staging/allocation behavior is unsupported
and cannot inherit shared-memory acceptance.

Use one context-owned dispatcher for both static projection and live observation.
At a matching ready event, validate the producer, project its actual rows, then
supply the post-edit values to a requested live observation. Never replace the
live callback with a second owner, call R from the worker, write an old tensor
on the next R callback, or retain a borrowed tensor pointer past its callback.
Projection remains armed even without `on_state`; only observation is optional.

A small relm-owned C++ classifier/accessor may include the pinned ggml headers
to inspect actual type, dimensions, strides, operation/source and alias roles.
Keep Rust's tensor opaque; do not hand-mirror its struct layout. This internal
bridge and a declaration of the existing backend write operation add no public
R export or vendor modification. Admit contiguous, validated F32 output rows
only. Use one H-wide row scratch buffer and synchronous backend access. Fail
closed rather than invent a generic arbitrary-layout tensor editor.

A per-model/backend/site runtime sentinel must establish both the edited value
and downstream consumption in a throwaway context before returning a handle.
An observed name, changed host copy, nonzero token effect alone or unconditional
"probe passed" flag is insufficient. Probe the selected producer semantics,
including the dense-Llama duplicate-name case; freeze positive and deliberately
missing/read-only/wrong-site negative controls. Caching may reuse only a proven
model/backend/site/layer/implementation identity and must not hide a changed
graph configuration.

Returning false from the current ready callback only breaks a scheduler split;
it is not sufficient whole-decode failure propagation. Store the classed native
error, prevent further projection/capture after it, check it before exposing
logits/state/token output, and invalidate the affected derived context if partial
computation cannot be safely reset. Cancellation, panic containment, failed
startup, deferred close and ordinary drop must release owners once. A damaged
derived handle must never silently run without its intervention; the original
handle and shared immutable weights remain usable.

If this bounded bridge cannot prove the required site/alias/downstream semantics,
stop before public implementation. An explicit graph-operation vendor patch is
a separate concrete decision; it is not authorized by this proposal.

## 4 Composition, live behavior and graphics

Derivation returns one fresh context sharing weights and carrying the accumulated
specifications, as for existing interventions. At most **32 projection sites**
are allowed per handle, with one projection per `(layer, component)`; deriving
a duplicate site is an error rather than an undocumented sum/replacement/order.
Different sites execute in graph order. At a sequential block: attention
projection, attention residual addition, MLP computation/projection, MLP residual
addition, existing residual additive steering, then existing residual ablation.
This preserves the established steer-before-ablate rule; an ablated neuron still
receives its explicit ablation value at that boundary.

Projection coefficients are static for a derived handle and every generation
started from it. F6b `on_state` replies still address only existing `steer`
entries; a projection ID in such a reply is rejected, never interpreted as an
additive update. Existing additive live revisions, audit columns and restoration
semantics are unchanged. Static projections compose with those updates; earlier
interventions' KV-history effects are not undone by changing a later coefficient.

`llm_generate()` synchronous/async/structured/text-streaming and `llm_logits()`
use the projected context. Initial projection acceptance is text-only: image
requests on a projected handle are rejected explicitly before execution. Ordinary
`llm_trace()` and `llm_embed()` retain their existing rejection of intervened
handles; use generation's supported live capture for post-edit observation.
No hidden expansion of D041 or vision/trace-context intervention is proposed.

`print()`/`summary()` identify kind `project`, component, layer and fixed
coefficient. The model map marks the actual configured component, distinguishes
projection from residual addition and appends integer `configured_projections`
to its returned site table after the existing D044 columns. Existing columns
retain their types/meaning; counts describe configured entries, not measured
causal effects. This additive table-column extension is part of D046 approval.
No direction vectors/model pointers enter plot tables. F6c comparisons retain
prefix-alignment rules and may show post-edit component values; timeline audit
continues to describe **additive live coefficients**, with that scope explicit
rather than presenting static projection as a live revision.

## 5 Bounded materialization and native storage

Keep the D045 limits on H, pairs, context, splits, canonical writes and
`max_bytes` (default64 MiB, whole1..512 MiB). Before native derivation, account for
all retained projection specs and copies; admitting one new artifact must not
hide already retained directions. Validate scalar counts before materializing
lists/copies. A single mutable row buffer is reused across sites/tokens; there
is no H-by-prompt or H-by-context host capture solely for projection.

Freeze an explicit compiled capacity ledger before native implementation:
`8 * H * P` for each independently owned f64 direction set, `4 * H` for the
shared f32 row buffer, actual descriptor/Arc/mutex/cache capacities, FFI command
copies, throwaway probe temporaries and simultaneously live R validation copies.
Count shared ownership exactly once and independent clones separately. Add this
projection-specific ledger to the existing R artifact/application estimate for
admission under `max_bytes`; existing base model/KV cache and separately requested
capture/spill retain their own contracts. The capacity formula and compiled
constants must be pinned by independent tests before arming production callbacks;
this proposal is not resource acceptance and no undisclosed reserve may replace
that calculation. If a bound cannot hold, correct the implementation or return
a classed OOM, never silently raise the accepted limit.

No new persistent files, temp-file category, native thread, dependency or user
workspace mutation is proposed. Unsupported sites and shape/type/probe/overflow
failures use `relm_error_intervention` with specific reasons; malformed arguments,
OOM, busy/closed and native internal failures retain existing class hierarchies.

## 6 Golden-first feasibility and acceptance

Approved roadmap acceptance (verbatim):

> independent goldens precede code and verify zero identity,
> unit-scale removal, negative-scale amplification, orthogonal-component
> preservation and causal propagation at the exact intervention site. Exercise
> composition, no-op detection, lifecycle/reset and applicable CPU/Metal paths,
> then compare held-out effects and task quality with the additive baseline using
> F6d. Verify numerical, resource and native-boundary changes proportionately.
> No universal behavior, cross-model compatibility or safety guarantee is implied.

1. After approval, freeze a separate independent Python arithmetic/encoding and
   tiny-model forward reference before product code. Cover axis/general vectors,
   sign invariance, zero/one/negative/above-one coefficients, cancellation and
   nonfinite/overflow refusal, schema2 identity, and all declared sites. Keep
   accepted old references/model files unchanged. For scalar f64 arithmetic use
   the existing direction absolute-plus-relative1e-12 bound; f32 site writes use
   absolute-plus-relative2e-6. Existing tiny-model downstream bounds remain
   unchanged and are recorded before execution, not selected from the outcome.
2. A private native feasibility gate must demonstrate producer mutation and its
   use by later nodes/logits on actual CPU and Metal, prefill over n_batch and
   n_ubatch, final-row pruning, graph reuse, dense/MoE rejection, duplicates and
   mixed observation. Missing/no-op/wrong-site controls must fail. Inspect real
   backend/offload proof; exit0 alone is insufficient. Do not expose the public
   mode before this gate and the compiled memory ledger pass.
3. Preserve the inactive callback path; measure new overhead against the same
   source with projection disabled/callback-free using warmup and three balanced
   release samples. Retain the existing5% dormant bound without relaxation.
   Record active one-site/multiple-site projection latency and transfer volume
   on CPU/Metal honestly; no GPU-speed or isolated setter-cost claim. A failed
   bound requires diagnosis, not repeated attempts to obtain a passing sample.
4. Implement the bounded artifact/application extension and shared native owner.
   Test old schema1/default-add compatibility, first/last layers, site/operator
   mismatch, duplicate/capacity refusal, exact zero/reset, steer/ablate composition,
   additive live updates with static projections, cancellation/failed startup/
   errors/deferred close and all allocation/transient/FFI bounds. Exercise panic
   containment and known unsafe boundary under targeted instrumented native tests.
5. Run affected installed R cases in a fresh candidate library and bounded cached
   model checks, using existing cached Qwen plus the committed tiny Llama fixture.
   No new model download, unchanged old matrix or accepted F6d experiment rerun.
   Keep specific actual tests/counts, artifacts, backend and source identities.
6. Freeze a **new** disjoint construction/selection/final dataset before inference.
   The pre-inference [F6e-v1 protocol](f6e-evaluation-protocol.md) records that
   dataset, coefficient grids, random control and bounded quality measures.
   F6d's consumed held-out set is not fresh evaluation data. Compare original,
   zero, learned additive and learned projection settings plus a norm-matched
   projection random control. Fit residual and component directions on the same
   declared construction prompts, choose coefficients only on selection data,
   retain a zero fallback and evaluate the locked settings once. Predeclare
   token cap, answer/quality/truncation measures, seeds and paired uncertainty.
   A favorable behavioral score is not an engineering gate; compare the whole
   site/operator intervention, not an isolated operator causal effect when the
   compared direction spaces differ. Retain all tables/outputs/negative results.
7. Inspect scoped new projection map/comparison exports, execute the updated
   vignette and package check, obtain one integrated implementation review with
   affected correction closure, and publish one coherent feature milestone.
   Native changes require affected numerical/resource/FFI and sanitizer evidence;
   unchanged F6a/b/c/d UI/service/model/Valgrind suites are not repeated wholesale.
   Preserve all nine final PR checks and source scopes; use the existing20-minute
   quiet monitor for background work, not receipt-only CI commits.

## 7 Decision and execution

The founder approved the single appended operator argument, component-specific schema2
artifacts, explicitly supported static projection behavior and map-count column
above. This extension was selected over a second public projection wrapper or an
unapproved vendor patch: it reuses validation/ownership and preserves default
additive calls. No new dependency or vendor change is included. The exact next step is independent references and the bounded native feasibility
gate; feasibility failure is reported before further scope changes.
