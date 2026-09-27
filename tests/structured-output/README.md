# S0 funding-extraction contract pilot

This is a small, frozen **contract pilot**, not a representative benchmark or a
claim of extraction quality. It contains 23 source-derived cases from seven
historical NIH/NIMH/NLM documents and nine original constructed cases. Text and
labels are English. No model has been tuned or evaluated against these cases.
Labels were prepared from the source text by the coding assistant; they are not
expert-certified or independently collected human annotations.

## Task and codebook

Given `target` and `text`, extract only funding information explicitly applicable
to that target and scope. The target can distinguish a programme total from its
annual allocation or its new awards. Do not use facts from other excerpts, the
page title or the URL to fill absent information. Input IDs/source locations are
application metadata, not generated fields.

The complete output shape is [output.schema.json](output.schema.json):

| Field | Meaning and normalization |
|---|---|
| `amount_usd` | Stated USD figure in whole dollars, 0..2147483647, or null. Scale an explicit decimal-million expression exactly (`$11.5 million` → 11500000); do not calculate totals from other allocations, convert currencies, or infer awarded/disbursed status. |
| `amount_qualifier` | `stated` for an unqualified figure; `approximate` for about/approximately/roughly; `at_most` for up to; `less_than` for nearly/less than; `at_least` and `more_than` retain their literal distinction; `not_stated` when amount is null. `stated` does not mean exact audited expenditure. |
| `duration_years` | Explicit funding/award period in whole years, 1..30, or null. `each year` for a requested annual allocation means 1. A reporting-year label, programme age, renewal frequency, cumulative history or generic maximum award term does not establish the requested award's duration. An explicitly anticipated term is extractable; its qualification stays in evidence. |
| `conditional_on_funds` | True only for an explicit funding-availability condition; false only for explicit lack of that condition; otherwise null. Future/planned wording alone is insufficient. |
| `evidence` | Required object with one string/null per preceding field. Every populated field has an exact contiguous quote from the input, at most 512 Unicode scalar values. Missing fields have null evidence. Quotes must substantiate the target, units and qualifier, not merely contain a plausible number. |

Related fields must agree: null amount implies `not_stated` and null amount/
qualifier evidence. Null duration/condition implies null corresponding evidence.
These cross-field/domain rules are application checks, not features promised by
the proposed core schema subset. Negated awards, unrelated private prizes and
institution-wide budgets must not be assigned to the requested research award.
Conflicting equally authoritative figures require amount abstention; do not pick
the first. Preserve other independently supported fields.

Reference `evidence` values are **required evidence anchors** for this pilot.
The automatic scorer accepts a longer exact quote containing the anchor. This
conservative rule may reject another valid quote; any such disagreement requires
annotation review and a recorded dataset revision, not silent post-result edits.
Automatic quote matching is not a general semantic-entailment test.

## Sources and reproducibility

[manifest.json](manifest.json) records URLs, selected source locations, retrieval
method and SHA256 of every normalized snapshot plus the cases/schema. Six pages
were fetched directly; the HEAL notice was retrieved through the web tool's
cached official page because direct retrieval returned HTTP 403. No claim of
live-page byte identity is made for that source. The source snapshots contain
only selected text, not complete websites, logos, images or third-party papers.

NIH's [copyright FAQ](https://www.nih.gov/about-nih/frequently-asked-questions)
describes government-authored website text as public domain unless otherwise
marked. Credit: National Institutes of Health, National Institute of Mental
Health and National Library of Medicine. Original annotations, code and
constructed cases use the repository's license. Archived documents are used as
historical text; no statement about current funding or medical practice follows.

Normalization decodes HTML entities and collapses whitespace within paragraphs;
selected paragraphs are joined with two line feeds and stored as UTF-8 without
Unicode normalization. `source_span` uses zero-based Unicode scalar offsets with
an exclusive end in the committed normalized snapshot. Generated quotes use the
input's exact characters; source offsets are computed outside the model.

## Partitions and limits

- **Development:** 13 source cases; ACE, HEAL and Nobel groups.
- **Held out:** 10 source cases; NLM and BRAIN groups.
- **Contract:** nine constructed cases; never counted as real-document quality.

ACE releases from 2012/2022 share a group. NLM training and budget pages share a
group. All excerpts and alternate questions from a source remain together.
Five independent source groups are too few for broad performance or subgroup
claims. The original 100–200-excerpt aspiration remains a possible D1 expansion,
versioned and frozen **before** tuning on it; this smaller S0 set fixes the
contract now. It must not be marketed as that larger corpus.

No generation prompt/model has been selected using held-out outcomes. Development
may guide prompts; hold out NLM/BRAIN until the D1 candidate is fixed. S0's simple
baselines are frozen reference rules, not prompt/model selection.

## Commands and evaluation

```sh
python3 tests/structured-output/verify.py --self-test
python3 tests/structured-output/check_batch_contract.py
python3 tests/structured-output/baseline.py
python3 tests/structured-output/verify.py --predictions RUN.jsonl --split held_out --gate
```

All tools use Python's standard library, consistent with existing test tooling;
Python is not added to the relm runtime. The first command validates hashes,
source spans, grouping, labels and corruption guards without network/model access.
The baseline command reports two deliberately simple comparators. It is not LLM
performance. `RUN.jsonl` is a future D1 result artifact; it does not exist yet.

Each prediction row contains `id`, `status` (`success`, `failure`, `abstained`)
and, for success, `output` as JSON text or a parsed object. Every selected input
must have exactly one record; missing/duplicate/unexpected IDs fail. Failures,
abstentions and invalid JSON/evidence stay in the denominator. The scorer reports
field accuracy, joint value/evidence accuracy, known-amount accuracy and the
fraction of emitted nonmissing fields unsupported by reference values/anchors.

**D1 pilot gate:** zero malformed/untraceable outputs; joint value/evidence
accuracy at least 0.80; known-amount accuracy at least 0.90; unsupported emitted
fields at most 0.05. At least one nonmissing prediction is required, so blanket
abstention cannot pass. With ten held-out cases these are coarse engineering
thresholds, not population estimates. Report counts alongside rates and the two
source groups; no confidence claim from treating related excerpts as independent.
Also report all error categories and time spent reviewing/correcting the output.

Before any usefulness claim, inspect semantic support and compare both the rules
and current unconstrained generation on the same frozen cases/model/seeds. A
correct source span by itself does not establish support. S0 validates reference
artifacts; D1 must still execute and report the actual application experiment.

## Fixture-only batch artifacts

[batch-contract.json](batch-contract.json) is a hand-assembled manifest and two
result examples for three inputs. Its successful output is copied from a label,
not generated; model/schema/input hashes refer to actual local fixtures. The
example has one committed result, one interrupted result and one missing result.
`check_batch_contract.py` verifies skip/retry decisions and refuses changed
model, prompt, schema or source identities, corrupted output digests, duplicate
IDs and changed seeds. The main manifest also pins this example's bytes.

Run identity is SHA256 of the configuration serialized as compact UTF-8 JSON,
keys sorted lexicographically, no Unicode normalization, no trailing newline.
This fixture uses only strings, integers, booleans, null, arrays and objects;
sampling decimals are strings to avoid cross-language float rendering differences.
Source identity includes both the requested target and exact input text. Output
digest uses the same encoding. D2 must supply cross-language byte fixtures before
adopting this convention and store all committed outcomes, including failures.

The check is a pure offline contract assertion. It does not implement or test a
runner, atomic writes, locking or recovery after a real process interruption;
those remain D2 gates. Its placeholder build/backend records describe an example,
and its prompt is not a selected D1 generation prompt.
