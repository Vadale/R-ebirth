# Milestones, agents and proportionate verification

Founder instruction, 2026-09-27; recorded in D-029. This refines the existing
Claude workflow without changing API/dependency approval or correctness rules.

- **Work units:** one coherent deliverable per active WP. Keep small local
  commits for review/recovery, but do not turn each edit, test or document into a
  separate task, agent or PR. Split only for a distinct dependency, meaningful
  acceptance boundary, excessive scope or a real blocker.
- **Push cadence:** accumulate local work. Push at a reviewable milestone, a
  dependency handoff or a justified backup point. Run remote CI on the candidate
  for integration, not after each micro-edit. Once a candidate is green, do not
  rerun unchanged suites without a new change, failure or unresolved concern.
- **Agent selection:** the owner handles routine cohesive work. Delegate a
  substantial independent analysis or implementation only when parallelism or
  expertise is likely to repay its context/token cost. Send focused context and
  clear file ownership. Use stronger reasoning for native/numerical architecture
  and difficult review; use ordinary effort for mechanical tasks. Do not launch
  every named role by default or repeat an ultra consultation for routine work.
- **Review:** one integrated independent review for a substantial WP. Address
  concrete findings and recheck the affected behavior. Another broad review
  requires unresolved risk, material redesign or disagreement. A phase-end
  maintainability review remains useful; line count is a signal, not an automatic
  extra-agent trigger, especially for data and documentation.
- **Verification:** choose checks from the changed behavior and its failure cost.
  Documentation/data work gets link, schema, provenance and consistency checks.
  R behavior gets focused package tests; native/numerical work additionally gets
  the appropriate goldens, Rust checks and boundary/resource tests. The package
  integration suite runs once on the final relevant candidate. Record scope,
  skips and failures; never present an unrun gate as passed.
- **Long operations (founder instruction, 2026-09-28):** run tests, builds,
  scripts, downloads, remote CI and other lengthy computation in the background
  when supported. Prefer completion events; otherwise use sparse scheduled
  checks to resume the same chat on completion or an actionable failure. This
  is standing authorization for future long operations across projects.
  End the active waiting turn; avoid polling loops, repeated log reads and
  unchanged progress notifications. A check with no actionable change should
  exit promptly. Reuse the current monitor, and disable it when its work is
  complete or requires founder input. Waiting alone never justifies a rerun.
- **Critical gates remain:** spec-first; approved dependency decisions;
  independent numerical references; regressions for data loss, memory corruption,
  boundary validation and process/thread ownership; parsing/download/service
  security review when those surfaces change; green required CI before merge.
- **Stop condition:** once acceptance passes and material review findings are
  resolved, finish the milestone. Cosmetic alternatives, speculative abstractions
  and repeated equivalent tests are not reasons to restart the cycle.

An internal role need not be a new conversation or process. No new dependency,
product export, weakened assertion or disabled CI job is authorized by this
efficiency amendment.

## CI scope refinement (2026-10-03)

Keep all nine ordinary check names and their existing event triggers. For a
verified change limited to the explicit external-documentation allowlist in
`tests/ci/change_scope.py`, the four R jobs and two native build jobs report
package/native execution as **not applicable**, with the compared commits.
They do not present unexecuted tests as passing tests. Golden/contract, vendor
coherence and supply-chain jobs still execute. This classification does not
certify an older runtime or repair a failed baseline.

Any package, test, fixture, workflow, classifier or unrecognized path requires
full ordinary CI. Package documentation is not external documentation. Missing
history, unexpected PR merge parents, malformed metadata, renames involving a
non-allowlisted path and ambiguous paths also require full checks. Do not add
paths to the allowlist to make a failing candidate green.

The vision nightly runs short installed-package lifecycle checks **before**
downloading the models. Its model stage selects vision tests, including the
separately named async/VLM test; generic async coverage remains in ordinary R
CI. Required actual-model gates reject missing, duplicate or skipped results,
even when a skipped case already recorded passing expectations. Preserve each
phase's timings, skips and failures before deciding success. Native vision
boundaries, model pins and same-runner numerical comparisons remain unchanged.

Use those timings to identify the next real bottleneck. Do not promise a new
wall-clock duration from a reduced test selection alone. A new runner does not
invalidate unchanged numerical evidence, but its prior source remains explicit;
changed runtime or reference inputs still require the affected acceptance.
