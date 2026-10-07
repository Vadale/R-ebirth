# Visual analysis and directional steering

Updated: 2026-10-05. D-042 records the founder's decision to schedule this work
after the merged F6a/F6b delivery and before Phase 7. The sequence is **F6c
reusable graphics → F6d direction construction and evaluation → F6e projection
steering**. Each increment ends independently usable. This document approves
the roadmap position and objectives, not new public signatures, dependencies,
vendor patches or untested feature claims. F6d and F6e have not started.

On 2026-10-07 the founder authorized starting this sequence. The concrete F6c
surface was presented in [the graphics contract](f6c-graphics-contract.md)
and API-GRAMMAR section 12 under D-044, then approved by the founder's instruction
to proceed after merging PR60. F6c implementation and local acceptance are now
complete, including installed tests, actual cached-model comparisons, managed
spill and foreground RStudio plotting/export. Final CI and integration remain
pending; see the [implementation report](f6c-implementation.md) for exact source
scopes, retained failures and limitations. D-042/D-043 scope and order are unchanged.

## Starting point

PR59 is merged at `cf4df637c1b60920560e16bb3199168b31f5910c`; its tree matches
accepted `f37da77ed5c144a624a77e92b43cf94af7054cd9`. The nine PR checks and both
post-merge workflows passed. Existing operational evidence retains its exact
executed source and limitations; this planning change requires no rerun.

Current building blocks include `plot.llm_probe`, the Anatomy Lab's token/layer
heatmaps, dose-response and ablation comparisons, direction geometry, topic
maps and a rolling live-observation demo. F6b adds actual applied coefficient,
revision and source-position records. Most specialized plots remain demo
functions rather than a coherent reusable package interface.

## F6c Reusable graphics and intervention comparisons

**Goal:** make the existing research instruments understandable through three
connected views, using base-R data structures and existing graphics first.

- A model-block map identifies supported layers, attention/MLP/residual paths,
  capture points and active steering/ablation sites. Detail views select a
  layer or captured coordinates. Distinguish architecture metadata from
  measured activity and estimated associations; do not invent causal edges.
- A paired comparison displays baseline, intervention and their difference,
  with corresponding output/logit changes and experimental settings. Freeze
  model, prompt, seed and generation settings. Use a shared token prefix for
  directly matched activation comparisons; if free-running outputs diverge,
  label that divergence rather than pretending equal positions are equal inputs.
- A steering timeline links tokens, states and the coefficients/revisions that
  actually produced them. Display the F6b next-decode boundary faithfully;
  restoring a coefficient does not erase its prior KV-history effects.

Reuse useful demo panels instead of rebuilding their analysis. Keep numerical
data available independently of rendering. Support exportable figures and
reproducible settings; an interactive view can follow a concrete client need.
Large captures must remain filterable and spill-aware, with bounded live history
and explicit aggregation. Loading every neuron or edge is not a prerequisite.

**Acceptance:** small known fixtures establish plotted values, differences,
coordinate alignment and intervention markers; labels distinguish descriptive
scores from intervention effects. A runnable paired example uses the accepted
capture interface on the actual generation context. Check image readability,
export and bounded retention. A polished graphic alone is not numerical proof.
Unsupported architecture details must be explicit. Freeze any public plotting
or comparison contract in API-GRAMMAR before implementing its exports.

## F6d Construct save and evaluate directions

**Goal:** turn contrastive examples into a reproducible, model-bound direction
artifact that works with the existing additive steering mechanism.

Start with explicit paired target/control examples, fixed capture components
and token-selection rules, per-layer mean differences and normalization.
Specify optional pair normalization and control-mean orthogonalization as
distinct methods; do not treat either as universally preferable. Reject
non-finite or zero-norm results and mismatched pairs rather than silently
discarding observations. Fit transformations only on construction data.

Save model/checkpoint identity, tokenizer/template, quantization, layer and
component coordinates, capture/normalization method, corpus and split hashes,
seed and vector digest. Separate construction, coefficient selection and final
evaluation prompts. Same hidden width does not establish transfer between
models, checkpoints or attention/MLP/residual spaces. Any import from another
tool needs a demonstrated semantic mapping, not just a readable binary file.

Use additive steering first. Reuse F6c to show held-out effect sizes, uncertainty,
coefficient sweeps and quality tradeoffs, including unchanged baseline, zero
coefficient and suitable matched/random controls. Define task-relevant quality
measurements before evaluating; shorter answers alone do not establish better
answers. Record failed or degenerate directions and strong-coefficient failures.

**Acceptance:** an independent small reference verifies direction arithmetic and
normalization; save/reload preserves exact values and provenance and rejects
incompatible artifacts. A bounded cached-model example evaluates held-out
prompts without leaking them into direction or coefficient selection. Base-R
tables expose numerical results underlying each plot. Approve concrete artifact,
side-effect and public API contracts before implementation; no new dependency
or model download follows from this roadmap decision.

## F6e Projection steering

**Goal:** add a distinct runtime intervention on a supported activation stream:

`h_new = h - alpha * v * dot(v, h)` for a unit direction `v`.

With `alpha = 1`, the component parallel to `v` is removed. This differs from
the existing residual addition `h_new = h + alpha * v`. Changing the sign of an
additive coefficient does not implement projection removal. The weights remain
unchanged; this is an activation intervention, not fine-tuning.

Begin with a feasibility/specification gate for the exact FFN/MLP or post-output-
projection attention tensor on the currently supported backend. Observation of
a tensor does not imply that it is safely editable. F6b's R reply reaches the
next decode, so it cannot substitute for an operation on the current captured
activation. Define placement, normalization, coefficient domain, composition
with additive steering/ablation, supported layers/architectures, cancellation,
restoration and live-update behavior before writing the public implementation.
Do not silently broaden D-041 or assume a vendor patch is authorized.

**Acceptance:** independent goldens precede code and verify zero identity,
unit-scale removal, negative-scale amplification, orthogonal-component
preservation and causal propagation at the exact intervention site. Exercise
composition, no-op detection, lifecycle/reset and applicable CPU/Metal paths,
then compare held-out effects and task quality with the additive baseline using
F6d. Verify numerical, resource and native-boundary changes proportionately.
No universal behavior, cross-model compatibility or safety guarantee is implied.

## Relationship to DwarfStar

The reference is the official [directional-steering documentation](https://github.com/antirez/ds4/blob/main/dir-steering/README.md)
and [direction constructor](https://github.com/antirez/ds4/blob/main/dir-steering/tools/build_direction.py),
inspected on 2026-10-04. Its constructor uses paired activation captures and
normalized layer directions, with optional pair normalization and default
control-mean orthogonalization. Runtime editing uses the projection operation
above at FFN or attention outputs. Its [sweep helper](https://github.com/antirez/ds4/blob/main/dir-steering/tools/run_sweep.py)
varies coefficients over fixed prompts. Pin an upstream revision before a
concrete implementation comparison; these moving links do not constitute a
dependency, copied code or acceptance evidence for relm.

## Delivery boundaries and later phases

Deliver F6c, then F6d, then F6e before starting Phase 7. Prepare each concrete
contract when that increment becomes current; do not require one approval for
every routine implementation choice, and do not invent exported function names
in this roadmap. Keep the accepted F6a/F6b interfaces and bounded-resource
semantics intact. Use one coherent milestone at a time, affected checks and
sparse background monitoring for long work; preserve earlier source scopes.

Technical debt directly needed by an increment belongs in that increment.
D-043 now replaces Phase 7's broad types/compiler/generic-service programme with
consolidation, usability and external validation of this research workflow.
Reduce justified internal duplication and support cost while preserving public
contracts and distinct correctness coverage; do not start a blanket rewrite.
Phase 8 Windows/CUDA remains hardware-deferred and Phase 9 remains CRAN/docs/API
stability. Existing topic modelling, I1, application serving and T1/T2 vision are
retained. Biology/DNA and a new topics satellite are outside active scope; other
historical expansion phases are uncommitted ideas, not automatic next steps.
See SOLO-PHASE-PLAN section 0 for the focused product boundary.
