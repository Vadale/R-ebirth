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
