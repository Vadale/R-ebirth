# F6e projection steering: implementation and evidence

D046 was approved on2026-10-07 by the founder's "vai continua" after the
concrete question and [contract](f6e-projection-contract.md). This record
separates approval, static analysis and actual execution. No new dependency or
vendor patch is authorized. The branch is `codex/projection-steering`, based on
integrated F6d main6dd701beb128d267a9c5f7324ace04b2c043589c.

## Current status

| Stage | Status and scope |
| --- | --- |
| D046/API14 decision | Approved; no pending API question for this contract |
| Native architecture | One source-only analysis complete; conditional route, no execution acceptance |
| Independent new reference | In preparation under tests/llm-golden/projection; must be separately frozen before native arithmetic |
| Compiled capacity/probe ledger | Concrete plan in preparation; no memory acceptance yet |
| Private native feasibility | Not implemented or run; actual CPU/Metal causality is required |
| Public R/native interface | Not implemented; default-add/schema1 compatibility remains required |
| Installed package/resource/lifecycle | Not run for F6e |
| New held-out experiment | Protocol frozen before any F6e inference; no result yet |
| Integrated implementation review | Not started; one review after complete implementation |
| F6e final CI/integration | No feature PR or dispatch yet |

## Native decision and required boundaries

The [focused native source analysis](f6e-native-feasibility.md) identifies a
possible synchronous producer boundary in the pinned scheduler. The documented
callback contract is observation. Actual projection must prove downstream
consumption, structural producer identity and no accidental editing of Llama's
same-named residual/MoE output. Qwen2 has no named post-Wo attention site and is
limited here to MLP. Other architectures/backend modes are not inferred from
observation support.

A narrow relm-owned C++ classifier may inspect actual pinned tensor structures;
Rust keeps opaque pointers. The single context-owned dispatcher must project
before observation for every actual row/microbatch. F6a final-row selection
cannot limit projection to one token. Graph reuse must preserve ownership and
actual selection. A false callback return only stops one split; errors must be
latched, checked outside decode before publication and invalidate an unusable
context. No silent no-op fallback or vendor patch follows a failed proof.

Projection plans have static coefficients; F6b replies still update only
additive steering. Derived-handle composition must keep every original
projection while preserving steer-before-ablate order. Original weights and
handle remain independent. Ordinary trace/embed and initial image requests
must retain the approved refusals; text generation/logits and mixed live
observation are explicitly exercised after native feasibility.

## Reference, resource and timing scope

New arithmetic/encoding/forward references are independent of product code and
must precede it in a separate commit. Existing schema1/reference/model bytes
remain unchanged. Scalar f64 comparisons use absolute-plus-relative1e-12;
projection writes use absolute-plus-relative2e-6 against the exact checked-f32
formula. Existing tiny-model downstream activation/logit0.01 bounds remain
unchanged. Overflow, wrong site, missing write, sign/orthogonal/zero behavior,
composition and causal propagation need positive and negative controls.

Freeze actual plan/vector/row/classifier/cache/probe/FFI/R transient capacities
before arming production callbacks. No whole-prompt host capture, hidden clone,
arbitrary reserve or borrowed tensor retained across callbacks. Existing
capture/spill/model/KV contracts remain separate and explicit.

Release timing must compare same-source callback-free, dormant/zero and active
paths with a warmup and three balanced rounds on actual CPU and Metal. Keep the
existing5% dormant threshold; failed gates are diagnosed, not relaxed or blindly
repeated. Active per-site/multi-site cost is measured and reported without an
invented threshold or GPU-speed claim. Old F6a timings do not accept new writes.

## Evaluation and evidence discipline

The [F6e-v1 protocol](f6e-evaluation-protocol.md) freezes38 new prompts,
12construction pairs,6selection/8final tasks, layer12 residual versus MLP,
fixed grids,256-token cap, quality guards and uncertainty before inference.
Its unit-norm random control is a balanced pair-sign randomization with truthful
prompt-role swaps, not a mislabeled arbitrary vector. The complete site/operator
settings are compared; different sites/directions prevent an isolated operator
effect claim. A negative result or zero selection is acceptable evidence.

Use fresh installed F6e R code and the necessary candidate native library for
changed execution; retain source/model/backend hashes and actual test counts.
Failed runs stay failed even when some stages pass. Carry unchanged accepted
stages with exact parent provenance rather than rerunning/relabeling them.
No old F6a/b/c/d/WP9/WP10/I1/maintenance/service/sanitizer/Valgrind matrix or UI
session is repeated wholesale. Existing F6d scoped-check/external warnings and
truncated-output limits remain in its original report.

Long operations run detached with durable status, one pipeline/model owner and
the existing quiet20-minute monitor. Final all-nine ordinary checks and affected
native instrumented gates remain required. No tracked receipt-only CI loop;
mark the final PR ready after its gates pass. Specific merge permission is
separate from this implementation authorization.
