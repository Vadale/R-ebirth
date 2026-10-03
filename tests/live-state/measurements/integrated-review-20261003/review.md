# Integrated F6a review

One read-only integrated review by `phase6_concrete_plan`, 2026-10-03.
Scope: approved D-041/API section11, frozen memory contract, native state/capture/
spill transport, R/FFI admission, callbacks and ownership. No builds, model calls,
reference edits or broad follow-up review were performed by the reviewer.
F6b is explicitly not implemented. Acceptance remains pending.

The original transport snapshot is retained under
`../transport-20261003-173544`; its clippy failure happened before runtime tests.

| Finding | Concrete mechanism | Scoped correction; execution not yet verified |
|---|---|---|
| P1 Arrow workspace | Shorter labels admitted more rows than the maximum-label packing used in the workspace estimate. | Reserve the full admitted frame-body workspace; retain encoded shorter-label control. |
| P1 whole-file bytes | H4096, maximum label8082, actual8080: adaptive129-row fragments add4480body bytes over the admitted128-row shape through64-byte padding. | Freeze the admitted per-component row count in the writer; two-file encoded boundary regression. |
| P2 admission/RNG | The four live strings/descriptors first entered the aggregate input cap during submission, after an omitted seed draw. | Repeat complete normalized R admission before seed; FFI inspects borrowed strings before copying; three exact-bound/RNG regressions. |
| P2 control ledger | Arc<LiveCancel> exists for memory jobs in spill-enabled builds but its charge was spill-only. | Charge compiled pointee and Arc counters in common live control accounting, remove spill-only duplicate. |

The reviewer found no additional causal-order, ownership, cancellation or
classed-error blocker. State acknowledgement precedes current-token delivery
and decode. Ordinary cancellation and unpublished-file cleanup avoid filesystem
work while holding the control mutex. This review is not test acceptance.

Required evidence remains corrected compilation/native/FFI/R execution, actual
allocation/serialization receipts, public transport timing and foreground RStudio
observation/cancellation with workspace restoration. Earlier native CPU/Metal
feasibility retains its separately recorded sources and excludes R transport.
