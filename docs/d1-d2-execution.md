# D1/D2 — Evaluated extraction and restartable batch execution

Date: 2026-09-27. Founder authorized the D block after S1 acceptance.
S1 is merged as PR #44 at `87f6c04`. Work branch: `codex/document-extraction`.
The sequence remains D1, then D2; there is no new relm export in this block.

**Recorded outcome:** the [D1 experiment](d1-extraction-evaluation.md) is complete
with failed quality gates: 10/10 schema-valid structured outputs, 2/10 task-valid,
0/10 fully grounded, 1/4 known amounts and 6/8 unsupported fields among task-valid
records. Preserve this bounded negative result; D1 usefulness is not accepted.
Human correction time remains unmeasured. The held-out set is consumed and must
not become a tuning set for a new held-out claim. D2 is prepared, not implemented;
its application dependency decision below remains pending.

## Dependency decision

[D-031](../DECISIONS.md#d-031--json-dependency-for-the-document-extraction-application)
proposes application-only `jsonlite == 2.0.0`. It is not yet approved. R's
`tools::sha256sum()` supplies hashing; no digest/renv dependency is needed for
the bounded recipe. Existing base-R and Python-standard-library evaluation
tools can proceed independently of this application dependency decision.

## D1 acceptance and experiment protocol

Acceptance, copied from the execution plan:

> Frozen held-out report includes all inputs, failures and abstentions, source
> verification, field accuracy, unsupported values, coverage and correction time.
> Numeric product thresholds set in S0 determine promotion; an honest failure
> report does not establish usefulness.

Use the unchanged S0 pilot: 13 development source cases, 10 held-out source cases
in two groups, and nine constructed contract cases. This is the small contract
pilot, not the unbuilt 100–200-excerpt corpus. Preserve the codebook, labels,
group assignments and numeric gate. Existing first-amount and always-missing
baselines remain frozen comparators.

The initial prompt is `tests/structured-output/prompts/funding-v1.txt`, derived
from the public codebook and development examples. Its two fictional teaching
examples are not held-out records. Start with the already-cached, registry-pinned
Qwen2.5-1.5B-Instruct Q4_K_M demo model. The 0.5B integration model is an optional
development comparator. Use greedy decoding, explicit per-record seeds, context
4096 and at most 768 generated tokens; both constrained and unconstrained modes
receive the identical prompt and input. No model download is needed initially.

Bound development to at most two prompt versions across these two models.
Keep every run and its failure records. If neither candidate is useful, report
that result rather than changing held-out data or expanding an unbounded search.
Select using development outcomes only, then write a frozen candidate manifest
pinning prompt/model/schema/driver/input identities and generation parameters.
Only that candidate may enter the single held-out evaluation. No prompt changes,
selective retries or model selection from held-out results.

Report schema validity independently of the unchanged task scorer. The promotion
gate remains zero malformed/untraceable records, joint value/evidence accuracy
at least 0.80, known-amount accuracy at least 0.90, and unsupported nonmissing
rate at most 0.05. On ten held-out records and four known amounts, show counts
alongside rates. Failures and abstentions stay in the denominators. Record
latency, raw outputs, error classes, source evidence and all discrepancies.

Audit each emitted field's semantic support and requested scope. Store proposed
corrections separately from original predictions with reasons. Assistant review
time is explicitly assistant time, not human correction time; actual human
review time remains unmeasured until a person performs a timed review. Do not
turn an automated score or assistant audit into a human-usability claim.

## D2 acceptance and storage contract

Acceptance, copied from the execution plan:

> Clean-session run succeeds offline after explicit setup; forced
> interruption/resume preserves completed results and creates no duplicates.
> Changed inputs/configuration refuse stale reuse. Record setup time,
> first-result time and memory on Mac and Linux CPU. This is the first production
> milestone.

Implement `examples/funding-extraction/` with `setup.R`, `run.R`, one helper
module, versioned example configuration and a README. One R process owns one
model, handles one bounded document at a time and returns ordinary tables.
Setup explicitly prepares an application library/model cache from pinned,
hash-verified artifacts. Run/resume never install or download. Record the actual
R/platform, package versions, native-library digest, model and backend; package
version alone is not native-inference reproducibility.

Retain S0's UTF-8 canonical JSON contract and test real R writer bytes against
the independent Python fixture. Reject malformed/duplicate/unknown keys and
out-of-contract values; never execute configuration code or repair model output.
Acquire the single-writer lock by atomic directory creation, with an ownership
nonce, host and PID. Remove only the caller's lock. Recovery of an abandoned
lock is explicit and requires stopping/verifying the former owner; age or a
reused PID alone is insufficient evidence.

Commit complete records by closed temporary file and checked same-directory
rename. Never delete a committed destination first. Validate record structure,
run/source/seed identities and content digests before skipping a committed file.
Committed result files are authoritative; diagnostic events may have an
incomplete final line after termination. Retry unfinished documents with the
same seed. Changed configuration requires a new run directory.

Test interruption before and after rename, orphan temporary files, explicit
stale-lock recovery, competing writers, corrupt results and individually changed
model/prompt/schema/source identities. Scope guarantees to tested local Mac/Linux
filesystems and process interruption, not power-loss durability or network
filesystems. D2 operational mechanics do not establish extraction usefulness if
D1's quality gate fails; report these dimensions separately.
