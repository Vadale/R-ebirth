# Corrected pruning pipeline: partial verification, Metal failure

Overall status: **FAILED**. Source manifest
`77fa1433ad624e0505895f519a9d8df651e88e5708b4fbfe07dc7968da3547c6`.
All623 source files and raw stage-log hashes matched; no source drift or warnings.

Separately verified completed stages:

- Format, clippy and no-spill libtest compilation passed.
- Native7:3cases/10042 independent comparisons (max0.003909901715815067),
  704same-input comparisons, and the separately accounted fixed-schedule
  pruning/history/replay checks passed. The grouped long-prompt cross-schedule
  observation retains its two outliers (vocabulary1 and43); it is not accepted
  as independent0.01 accuracy.
- Native8:6composition cases/1negative control passed.
- Native9:3lifecycle/ownership cases/3negative controls passed.
- CPU release:20samples,128tokens each, one warmup plus3balanced measured rounds
  per mode. Medians callback-free/dormant/zero/one-site/multi-site were
  1.346264/1.350309750/1.350369667/1.362167250/1.370164250seconds.
  Dormant ratio1.0030051684 passes the unchanged1.05bound. Actual CPU-only
  backend receipts show0of25offload and75.06MiB CPU compute buffer.
  Token identity, raw samples, transfer counts and medians were checked.

The Metal leg failed before any timing sample or completed tiny-forward case.
The first layer0MLP derivation probe returned native_status=-6, then the private
test unwrapped the classed Intervention error. The native classifier's -6
condition covers missing data, !is_host or weight-buffer usage. At the pinned
source, even Metal's **shared** buffer type reports is_host=false; the same
predicate cannot distinguish shared from private Metal storage. The log alone
does not establish the actual failed tensor storage mode. Do not remove the
guard or claim Metal support from this static diagnosis. A bounded actual-buffer
proof and exact shared-storage classification are required, with private/unknown
buffers still rejected and no unbudgeted staging.

The failure preserves all sources/logs. CPU and native completed stages retain
this exact source; no repeated native1-9/CPU benchmark is justified by this
Metal-only failure. Public F6e remains unavailable.
