# Long-prefill schedule diagnostic

Status: controlled diagnostic collection verified; **not feature acceptance**.
The earlier `feasibility-resume-20261007-213532` remains failed. No runtime,
reference, tolerance or vendor file changed for this diagnostic.

Sixteen CPU/debug executions of the same committed tiny model separate batch
grouping, output policy, observer presence, zero/active projection and replay.
Seventeen recorded comparisons plus owner checks of grouped-all versus grouped-last
use actual final and common-continuation logits. All603 source hashes,15 archived
changed-source hashes and three stage-log hashes match. Format/clippy and the
one ignored diagnostic test passed, with no warnings.

## Findings

- At a fixed schedule, all-output versus last-only, observer versus no observer,
  and cleared-context replay are bit-identical for both zero and active plans,
  for final48 logits and48 logits after a common next token using retained KV.
- Ordinary and zero-projection controls are bit-identical at each tested schedule.
- All8 audited runs contain every position0..514 exactly once at each of2 sites:
  8240 total witnesses, no missing/duplicate rows, and3072 same-input coordinate
  comparisons with zero measured error under the unchanged2e-6 bound.
- Changing only grouping from512+1+1 to512+2 changes ordinary final logits by
  at most0.007766246795654297 and active final logits by0.011423110961914062.
  The active fixed-reference comparison has2 outliers above0.01 only in the
  grouped variants. The original0.011524818752575161 failure is preserved.
- Common-continuation maximum differences are0.00009870529174804688 (ordinary)
  and0.00019124150276184082 (active). These are observations, not new thresholds.

The controlled factors localize the discrepancy to batch grouping. They do not
establish the specific upstream kernel mechanism or universal harmlessness.
The frozen reference declares513 prefill tokens followed by1 decode token;
the original extra pruning branch passed all514 tokens to `prompt_last_logits`,
changing both that schedule and output selection simultaneously.

No cross-schedule golden pass is claimed, and no changed golden or widened
0.01 bound is proposed. Any corrected pruning gate must retain long-prefill
coverage, compare the independent reference at its declared phase schedule,
and separately test output pruning at fixed schedules including512+2 with
actual same-input row and retained-history evidence.

`collection.json` retains all raw numerical results and failures.
`owner-verification.json` records source/log checks and exact extra comparisons.
Full native feasibility, CPU/Metal timings and public F6e remain unaccepted.
