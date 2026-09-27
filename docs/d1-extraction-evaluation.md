# D1 — Funding-extraction pilot evaluation

Date: 2026-09-27. This report separates JSON conformance from extraction quality.
The experiment uses the frozen [S0 contract pilot](s0-output-contract.md), not a
representative benchmark or a validated production application.

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
