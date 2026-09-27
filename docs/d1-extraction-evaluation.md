# D1 — Funding-extraction pilot evaluation

Date: 2026-09-27. This report separates JSON conformance from extraction quality.
The experiment uses the frozen [S0 contract pilot](s0-output-contract.md), not a
representative benchmark or a validated production application.

**Outcome: the structured candidate fails all four held-out promotion gates.**
It produces schema-valid JSON on 10/10 inputs, but no fully correct, grounded
record. The evaluation report is delivered; D1's usefulness acceptance remains
open. No runtime or inference failure was hidden or retried.

## Protocol and candidate selection

The [D1 protocol](d1-d2-execution.md) permits two prompt versions and the two
already-cached registry models. Development uses 13 cases from ACE, HEAL and
NOBEL. The ten held-out cases belong to NLM and BRAIN. Constructed contract cases
are not counted as document-extraction quality. Cases, source snapshots, labels,
schema and acceptance thresholds remain unchanged.

Every generation uses the public `llm_generate()` API, context length 4096,
maximum 768 generated tokens, greedy decoding, top-p 0.95, chat mode and seed
`101 + case index in cases.json`. Constrained and unconstrained runs receive the
same prompt and input. Each mode loads one model in a fresh R process on macOS
arm64 with Metal. There is no output repair, automatic retry or selective omission.

Local runtime: R 4.5.1, relm 0.2.0.9000, S1 native library SHA256
`db307bcb91472a92b5441073674ba684f0f40a14b43766f3dc2ac899b8040d48`.
The runtime/build and model digests are part of the frozen candidate identity.
These measurements do not establish Linux CPU or other-model quality.
The driver binds native bytes and R/package versions, not installed R wrapper
bytes. The installed S1 package remains unchanged throughout these experiments;
a package version alone is not a complete content identity.

Development results, with each denominator including all 13 inputs:

| Model / prompt | Mode | Schema valid | Task valid | Joint value/evidence correct | Known amounts correct | Unsupported emitted fields in task-valid records |
|---|---|---:|---:|---:|---:|---:|
| 1.5B Q4_K_M / v1 | Unconstrained | 12/13 | 10/13 | 4/13 | 4/4 | 14/24 |
| 1.5B Q4_K_M / v1 | Structured | 13/13 | 5/13 | 0/13 | 4/4 | 10/20 |
| 1.5B Q4_K_M / v2 | Unconstrained | 3/13 | 0/13 | 0/13 | 0/4 | Undefined: no task-valid emitted fields |
| 1.5B Q4_K_M / v2 | Structured | 13/13 | 0/13 | 0/13 | 0/4 | Undefined: no task-valid emitted fields |
| 0.5B Q8_0 / v1 | Unconstrained | 7/13 | 6/13 | 3/13 | 0/4 | 4/4 |
| 0.5B Q8_0 / v1 | Structured | 13/13 | 6/13 | 0/13 | 0/4 | 20/24 |

No development candidate demonstrates useful extraction. Select 1.5B/v1 for
the single held-out evaluation because it is the only structured candidate
recovering the four known amounts; its unconstrained comparator also has the
highest joint accuracy. This is selection of the least unsuccessful candidate,
not promotion. Version 2 shortened instructions and emphasized missing values
and exact quotations using development failures only; it performed worse.

The initial v1 run preceded the addition of explicit native/runtime identity
checks to the evaluation driver. Preserve it as exploratory evidence. Re-execute
the identical selected configuration with the final identity checks before
freezing; this is a provenance verification, not another tuning opportunity.
The runtime-checked repetition produced byte-identical predictions in both
modes. Independent review then found that interrupted metadata could abort the
report. After that failure-accounting fix and its regression test, one final
unchanged development run supplies the frozen candidate provenance. All runs
are retained; the extra runs do not count as additional independent quality data.
The final run also matches the initial predictions byte-for-byte. The candidate
was frozen in commit `1d2cb7b`, before any held-out inference or review.

## Held-out outcome

All ten selected cases completed in each mode. The driver returned exit status
1 because the quality gate failed; execution itself was complete. The cases
comprise six NLM and four BRAIN excerpts/questions in two source groups.

| Measurement | Unconstrained | Structured | Structured promotion requirement |
|---|---:|---:|---:|
| Schema-valid JSON | 5/10 | 10/10 | 10/10 |
| Task-valid records, including missingness/evidence consistency | 2/10 | 2/10 | 10/10 |
| Joint value/evidence accuracy | 1/10 (10%) | 0/10 (0%) | At least 8/10 |
| Known-amount accuracy | 1/4 (25%) | 1/4 (25%) | 4/4 on this pilot |
| Unsupported emitted fields in task-valid records | 2/4 (50%) | 6/8 (75%) | At most 5% |
| Median generation time per input | 4.443 s | 5.515 s | Descriptive only |
| Sum of generation times | 55.383 s | 50.917 s | Excludes setup/model load |

The schema check alone passes. The four actual promotion checks are task validity,
joint accuracy, known-amount accuracy and unsupported-field rate; **all fail**.
The constrained candidate has 0/6 joint matches in NLM and 0/4 in BRAIN. The
unconstrained comparator has 1/6 and 0/4 respectively. Related excerpts are not
independent observations, so these counts do not support population inference.

| Field accuracy, with invalid records scored incorrect | Unconstrained | Structured |
|---|---:|---:|
| `amount_usd` | 2/10 | 1/10 |
| `amount_qualifier` | 2/10 | 1/10 |
| `duration_years` | 1/10 | 1/10 |
| `conditional_on_funds` | 1/10 | 0/10 |

The frozen first-amount baseline has 6/10 joint matches, 2/4 known amounts and
9/14 unsupported fields. Always-missing has 6/10 joint matches and 0/4 known
amounts. Both fail the gate, but their higher joint score shows why this LLM
candidate must not be promoted merely because it generates plausible records.

Coverage is also not usefulness: all 10 structured responses contain at least
one asserted value or qualifier; 9/10 assert an amount. Only 2/10 pass task
consistency and 0/10 are fully grounded. Unconstrained output includes five
strict parse failures, two parsed full abstentions (one with invalid nonnull
evidence), and three other parsed records. All ten remain in the score.

## Source review and correction burden

The assistant reviewed both modes against every held-out source excerpt,
requested scope and evidence field. Snapshot hashes and exact source spans
pass the unchanged S0 audit. The separate
[semantic review](../tests/structured-output/measurements/d1-macos-metal-2026-09-27/semantic-review.json)
records reasons and proposed replacement values/evidence for all 20 outputs.
It is reference-assisted review, not blinded or independent expert annotation.
Original model responses and frozen labels were not modified or rescored.

The structured results require proposed corrections in **10/10 records**;
the unconstrained results in **9/10**. Examples:

- NLM's five-year total is confused with its annual allocation; `nearly` is
  discarded, and trainee/grant counts are read as dollars.
- The institution-wide NLM budget is assigned to a narrower training award.
- BRAIN's new-award subtotal is confused with its programme total.
- Funding conditions are asserted without support. Some evidence is fabricated;
  other quotations occur verbatim but do not substantiate the requested fact.
- Correct null values can still carry invalid nonnull evidence. The schema
  intentionally does not promise these cross-field/domain relationships.

Human correction time is **unmeasured**, not zero. The review artifact records
the assistant's elapsed inspection window and explicitly includes waiting and
record preparation; it is not a measure of active human correction effort.
This missing usability evidence is another reason no production-readiness or
time-saving claim follows.

## Reproducible evidence and validation

[Recorded artifacts](../tests/structured-output/measurements/d1-macos-metal-2026-09-27/README.md)
preserve all five development executions, the frozen candidate, both held-out
runs and semantic review. `check-evaluation-artifacts.py` verifies 150 original
predictions against their recorded byte digests and recalculates the scores.
The candidate binds the final development report, input/schema/model/settings,
native runtime and evaluator source; archived exploratory provenance is labelled.

Eight model-free evaluator regressions pass, including runtime/candidate drift,
failure denominators and interrupted/unreadable metadata. The unchanged S0
source/contract checks also pass. These checks run in the Rust CI golden job;
actual inference is the explicit manual D1 experiment. No native/R package code,
API or dependency changed, so an unchanged native rebuild was not repeated locally.

The next quality experiment should test a more capable, pinned local model on
a broader, independently reviewed corpus under a new bounded protocol. The
consumed held-out pilot is now regression material: it cannot be reused for
tuning and then presented as fresh held-out evidence. No third prompt, changed
label, weaker threshold or additional model search was undertaken in this block.

## Interpreting the checks

Schema conformance checks JSON shape, types and bounds. Task validity additionally
checks missingness relationships and whether quoted text occurs in the input.
Joint accuracy requires every expected field value and evidence anchor to match.
Neither schema validity nor substring matching proves semantic support.

The frozen unsupported-field metric counts emitted nonmissing fields from
task-valid records only. An invalid record is excluded from that particular
denominator, but remains a failure in the all-case accuracy denominator and
independently fails the zero-invalid-record promotion gate. An undefined rate
cannot pass. Report semantic audit findings for invalid records as well.

Human review/correction time is unmeasured. Assistant analysis and proposed
corrections are not a measurement of a person's correction burden. The labels
were prepared by an assistant and have not been independently expert-certified.

## Delivery boundary

The experiment evaluates the funding-extraction application. S1's supported
schema guarantees and resource checks remain a separate, already accepted result.
Successful JSON generation alone does not establish a useful document workflow.

D2's planned offline setup, durable results and interruption/resume checks remain
unimplemented. Application-only jsonlite 2.0.0 is proposed in D-031 and awaits
explicit approval. Even if the operational recipe passes later, it will not
establish extraction usefulness without a passing, independently evaluated
candidate. No service, statistical-probe or Windows work is included here.
