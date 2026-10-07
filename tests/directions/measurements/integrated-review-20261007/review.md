# F6d integrated implementation review and targeted closure

Date: 2026-10-07. Reviewer: independent delegated implementation reviewer
`f6c_integrated_review` (the task name is historical).

## Outcome and scope

The initial review found three actionable correctness/resource defects, recorded
below and communicated to the implementation owner as they were established.
All three are closed by targeted source inspection of the corrections and their
regression tests. No remaining code blocker was identified within this review's
scope. Source closure is supported by the owner's completed focused installed
run, whose receipt was inspected without rerunning it. This is not a
model-evaluation acceptance claim.

This is the **one integrated independent F6d implementation review** required by
`.claude/skills/new-wp/SKILL.md` and D-029, followed by narrow closure of its own
findings. It is not another F6c review or a reconsideration of approved D-045.
The reviewed working tree is on `codex/contrast-directions`, based on golden
commit `e80166e5c12f50f795bb97fb16b468bff77394f0`. The initial owner snapshot is
`/private/tmp/relm-f6d/boundaries-20261007-174433/source/rebirth/R/`.

The reviewer read the current project guidance and HANDOFF, the approved
`docs/f6d-direction-contract.md`, the frozen independent
`tests/llm-golden/directions/ENCODING.md`, and the frozen
`docs/f6d-evaluation-protocol.md`. Implementation scope comprised:

- All five new R files: `direction-schema.R`, `direction-arithmetic.R`,
  `direction-encoding.R`, `direction-validation.R`, and `directions.R`.
- The two direction test helpers and the boundary, golden, and memory tests.
- The fixture-mirroring script and the affected export/CI integration.

Review covered schema and coordinate validation, numerical guards, declared
provenance, compatibility checks before native derivation, canonical encoding,
transient/materialized/canonical-file bounds, cleanup, and test coverage.
Small model-free source-overlay diagnostics established the findings below.
The reviewer ran no models, native builds, broad test suites, or repeated
F6a/F6b/F6c acceptance checks. Closure used source and test inspection only.
The sole repository write by this reviewer is this report.

## Initial actionable findings

### R1 — P2: canonical checksum I/O could succeed after an incomplete write

Original location: `rebirth/R/direction-encoding.R`, the `writeBin()` call in
`direction_hash()` and the subsequent checksum calculation (original lines
74–79; corrected implementation is now lines 59–93).

The stream counter advanced by the requested byte count regardless of whether
the connection accepted those bytes. A warning-only write failure therefore
allowed hashing of an incomplete temporary file. A focused diagnostic replaced
the connection write with a warning and no write. It returned the SHA-256 of an
empty file,
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`,
after 18 warnings instead of refusing the artifact with a classed error.

This violates the canonical-byte integrity and classed-I/O-failure contract.
Requested correction: convert warnings during write/close/checksum into the
existing classed checksum-I/O failure with the original condition retained;
verify finalized file length equals the emitted byte count before hashing;
retain cleanup on both failure paths. Add warning-only and silent-short-write
regressions. This was a correctness blocker, not a style request.

### R2 — P2: valid maximum-width inputs exceeded the frozen allocation ledger

Original location: `rebirth/R/direction-arithmetic.R:17`, extraction of named
matrix rows; corrected extraction is now at line 19.

`target[i, ]` and `control[i, ]` retained the validated neuron column names.
Arithmetic then propagated these names into several working vectors. A focused
diagnostic with valid 2 × 65,536 paired matrices and the default 64 MiB budget
failed before hashing with `relm_error_internal`, reason
`direction_allocation`: materialized bytes were 38,289,192 against an admitted
estimate of 32,810,776.

The supported width was admitted but could not complete under its own frozen
ledger. Requested correction: remove names from row temporaries after input
coordinates have been checked, preserve the independently frozen envelope and
numerical algorithm, and cover the maximum width with both optional arithmetic
operations enabled. This was a supported-input/resource blocker.

### R3 — P2: ignored row-name attributes could retain an unbounded environment

Original location: `rebirth/R/direction-schema.R`, `direction_frame()` (original
lines 33–49), and the saved-artifact frame validation in
`rebirth/R/direction-validation.R`.

Frame and column attributes were restricted, but attributes attached to the
`row.names` vector itself were not. For example, a construction context whose
pair-frame row names were
`structure(c("a", "b", "c"), hidden = new.env())` was accepted. The resulting
artifact retained that environment in its saved context. The diagnostic checked
the retained object with `is.environment()` and obtained `TRUE`.

Row names are ignored by the canonical frame encoding, and `object.size()` does
not account for an environment's referenced contents. The retained environment
could therefore hide a large object or native owner outside both the checksum
and materialization ledger. Requested correction: reject attributed or malformed
row-name vectors for every admitted frame and the saved artifact; canonicalize
ordinary, semantically unused frame labels; add construction and saved-artifact
regressions. This was a schema/ownership/resource blocker.

## Targeted correction closure

The owner corrected the three findings without changing the approved API,
independent numerical/encoding references, ledger constants, native code,
dependencies, or vendor code. Only the relevant corrections and their new tests
were inspected during closure; no second broad review or independent rerun was
performed.

| Finding | Inspected correction | Inspected regression | Closure |
| --- | --- | --- | --- |
| R1 | `direction-encoding.R:68–93` wraps the full write/close/hash body with a warning handler that preserves the warning as the classed condition's parent. After closing the connection, lines 81–83 require exact finalized byte-count equality before hashing. Existing `on.exit()` connection/file cleanup remains in place. `direction_write_bytes()` provides a narrow fault-injection boundary. | `test-directions-memory.R:71` injects a warning-only write; line 84 injects a silent short write. Both assert classed refusal, retained parent information, and temporary-file cleanup. | Closed by source/test inspection. |
| R2 | `direction-arithmetic.R:19` calls `unname()` on the two extracted rows before arithmetic. Coordinate validation still precedes computation. The numerical order and original envelope are unchanged. | `test-directions-memory.R:30` covers 2 × 65,536 inputs with pair normalization and control-mean orthogonalization enabled; checks recorded stage sizes against an independently written frozen envelope, output coordinates, and unnamed values. | Closed by source/test inspection. |
| R3 | `direction-schema.R:33–36` requires integer/character row names, no attributes, exact frame length, and no missing/duplicate entries. `direction_frame()` invokes it before canonicalizing ordinary labels to automatic row names. `direction-validation.R:51` applies the same check to a saved artifact. Context pair/split frames and diagnostic frames pass through the shared frame validator. | `test-directions-boundaries.R:135` injects a hidden environment into context pairs, context splits, an artifact's row names, and diagnostic-pair row names, asserting refusal. Ordinary labels are accepted and canonicalized. | Closed by source/test inspection. |

There are no optional style findings requiring follow-up. The owner subsequently
completed the corrected installed test gate; its evidence is recorded below.

At the owner's request, the R3 closure also checked the analogous matrix
dimname path. Attributed row-name vectors cannot enter diagnostics: the context
pair-ID column must be plain and must be `identical()` to matrix row names
(`direction-schema.R:132`). Attributed column-name vectors fail the exact
canonical `1:H` comparison at line 171. Attributes on the outer dimnames list
are not copied into diagnostics or the artifact; only its already-checked row
vector is used there. This narrow source check found no additional retained-owner
route and required no product change or test run.

## Other conclusions within the reviewed scope

- The API and implementation preserve the approved identity limit: checkpoint
  digests are recorded provenance. Exact independent destination model-record
  equality and available handle geometry/architecture/quantization checks are
  compatibility checks; they do not authenticate already-loaded weights.
- Artifact validation, integrity checks, and destination compatibility occur
  before delegating to the existing `llm_steer()` derivation. This
  review does not renew acceptance of unchanged native steering.
- Arithmetic uses row-wise differences and width-sized working vectors rather
  than materializing a full difference matrix. Its specified row order,
  normalization/projection order, finite-value refusals, scaled norms, and
  degeneracy guards are represented in the new independent golden tests.
- Canonical encoding binds ordered coordinates and fixed schema fields, uses
  typed little-endian domains, preserves signed zero, and excludes only the
  payload digest from its own payload. Temporary encoding uses one bounded file
  at a time and bounded emitted chunks. R1 closes the identified incomplete-file
  integrity gap.
- Trusted `saveRDS()`/`readRDS()` plus validation on use is the approved persistence
  boundary. The implementation makes no safe-untrusted-deserialization claim.

## Execution evidence and remaining gates

The owner-run first installed pipeline has a retained failure receipt at
`/private/tmp/relm-f6d/boundaries-20261007-174433/status.json`. Fixture mirroring,
documentation generation, and installation passed. Installed tests failed in the
expected-refusal golden test harness because
`expect_s3_class(..., info = id)` is unsupported by the installed testthat API.
The boundary, memory, package-export, and accepted-reference assertions preceding
or outside that harness failure showed no product numerical failure in that
log. The refusal loop was incomplete; the run must not be reported as passing.

The owner replaced that assertion with `expect_true(inherits(...), info = id)`.
The corrected focused installed pipeline, PID 25762, completed successfully at
`/private/tmp/relm-f6d/corrected-boundaries-20261007-175129/`. The reviewer read
its `status.json`, `independent-verification.json`, `installed-tests.log`, and
empty `code-usage.txt`; no tests were rerun. The receipts report 21 direction
cases / 1,311 expectations, zero failures, skips, or test warnings, no source
drift, and no codetools usage messages. These cases include the three findings'
regressions. The external startup warning that testthat was built under R 4.5.2
remains visible in the log and is not represented as a test failure or hidden.
The package-export success belongs to the separately retained original run;
it was not repeated in the corrected direction-only test scope.

Both pipelines reused the unchanged accepted DLL at
`/private/tmp/relm-f6b/library/relm/libs/relm.so`, SHA-256
`6edc6e6d512bb16e9d5ad8ed22093291e61a81bb89e5c2d07bee134db6ff04ac`;
it did not build or renew native acceptance.

The frozen held-out model evaluation was not run by this reviewer and is not
accepted by this report. The bounded evaluation and remaining owner acceptance
work are separate gates before F6d can be called complete.

## Source identity

SHA-256 values below bind this report to the reviewed files. Initial values refer
to the frozen owner snapshot named above; closure values refer to the corrected
working tree inspected on 2026-10-07.

| Product file under `rebirth/R/` | Initial SHA-256 | Closure SHA-256 |
| --- | --- | --- |
| `direction-arithmetic.R` | `a3d58f1660ec11ca6372cdd74b97f216c2a99220cba66e6557090a35b83d54be` | `02eba74db7afc4512fba156f50bce3d1667e7232187675025a094783e0d35642` |
| `direction-encoding.R` | `c47c604a78df4677164eb8a0057789cde080abfb4e370eed2fa31a36d7a41736` | `e91b7b7be0d77045c2f83d923183cbbf9d19c04106a91e140b8e07d391b058e2` |
| `direction-schema.R` | `51d7a46cc9294e0a67cde59e37aa0cbe2cfd9c6ec4f052e8ceecf2f6a112452c` | `cafe9e2333dd750543d7d94f85385193ef6cf97aadec413f906552fc1429c36e` |
| `direction-validation.R` | `2c4cbc22b1fa167ca6c69e8a32d2cbe035f5f8dd328b71656d5d87739b65c3e8` | `0b73da595f1a1fe2de8d53f91ca1287658f6e179f79a9e61157bc3488442267f` |
| `directions.R` | `c448f5cc997f0823154a766b7acb421c7e6181a0c57b045d31c2169d9669e868` | `c448f5cc997f0823154a766b7acb421c7e6181a0c57b045d31c2169d9669e868` |

| Reference or closure test file | SHA-256 |
| --- | --- |
| `docs/f6d-direction-contract.md` | `959bf910b5136caeda79ead3ec415ff12abfc0759cbd1900693d4c060eeb92b0` |
| `tests/llm-golden/directions/ENCODING.md` | `40092826e6bd4db5d80bbbc33c2ea2ab768a2e30a5cb058abc9fcbde4a04abf0` |
| `rebirth/tests/testthat/helper-directions.R` | `7d9cf7e07e279d99fe1fe0f83b527a06045a56d51b1f58bb601da2e06508584f` |
| `rebirth/tests/testthat/helper-direction-goldens.R` | `aac9132929fe188177979097edb27186d8a357c9191c3174f9f792d7649d5101` |
| `rebirth/tests/testthat/test-directions-boundaries.R` | `d3593544faf565c09f615a2a7b46238ca46ffaa9827162e64b587a1fc2b3d0a9` |
| `rebirth/tests/testthat/test-directions-goldens.R` | `6c8d6f5528c311ba1d445f597da35883d56a07c924756223e96629128b9385a1` |
| `rebirth/tests/testthat/test-directions-memory.R` | `9f49f8a2cf6962aa60d2d088cb18c011dfc7f17207cc3989ad9298029146062a` |
