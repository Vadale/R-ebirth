# F6d: recorded contrast directions

D045 was approved on 2026-10-07 after the concrete API and temporary-checksum-file
proposal. The implementation adds `llm_direction()`, `llm_apply_direction()` and
`print.relm_direction()` in R, with no native/vendor/dependency change. Artifact
identity is recorded provenance plus compatibility checks, not authentication
of already-loaded weights. [Contract](f6d-direction-contract.md) and
[frozen experiment](f6d-evaluation-protocol.md) define the scope.

## Implementation and independent reference

Construction validates complete paired coordinates and exact recorded context,
then computes differences row by row. Optional pair normalization and control-
mean orthogonalization precede final unit normalization. Scaled norms and frozen
relative guards refuse unstable/nonfinite input without silently dropping pairs.
The artifact retains only a bounded data frame and ordinary metadata. Canonical
little-endian checksums preserve double bits and ordered coordinates; temporary
files are bounded, unique, closed and removed on all exits. Printing and checked
application validate schema, semantics and integrity before native derivation.

Independent Python/Decimal references were frozen in separate commit `e80166e`
before product arithmetic: 16 accepted and 16 rejected cases, 52 direction values,
112 scalar diagnostics, 38 per-pair norm rows, 19 exact typed byte vectors and
77 explicit controls. Installed fixtures are byte-identical copies checked in
ordinary CI. Existing numerical goldens and tolerances are unchanged.

## Review and installed verification

The [single integrated review](../tests/directions/measurements/integrated-review-20261007/review.md)
found three issues: incomplete canonical writes could still hash; repeated
neuron labels exceeded the max-width allocation ledger; attributed row names
could retain an environment outside the serialized schema. Corrections reject
I/O warnings/incomplete byte counts, strip validated labels from row temporaries,
and enforce plain/canonical frame row names. The approved envelope, algorithm,
API and native runtime were not expanded. Targeted source closure and installed
regressions passed; no second broad review was performed.

Corrected installed run `corrected-boundaries-20261007-175129` passed 21 direction
cases / 1,311 expectations, zero failures, skips or test warnings. Independent
verification matched 173 source and 28 installed hashes; codetools reported no
usage messages. The unchanged accepted F6b DLL was reused in a fresh isolated
F6d R library; this is not renewed native acceptance. The external testthat
R 4.5.2 build-version warning is retained.

The first installed run remains FAILED: its expected-refusal test used an
unsupported `expect_s3_class(info=)` argument and stopped that loop. All other
recorded cases, including the exact export allowlist, passed at that source.
The corrected assertion tests the identical class via `inherits()`. New product
corrections justified the affected direction-test rerun; the unchanged package
export case was not repeated. Raw failures and sources are preserved under
[measurements](../tests/directions/measurements/).

## Real-model and held-out scope

The initial cached-Qwen CPU run completed 24 construction captures (12 pairs,
896 coordinates), exact trusted-RDS persistence and checked-versus-raw native
steering comparison. Independent arithmetic reconstructed the retained direction
with maximum absolute difference `4.996003610813204e-16`. The overall attempt
FAILED before selection generation because the harness supplied capture options
without an observation callback. The amendment keeps all frozen scientific
settings, reuses accepted capture/artifact/random data and changes only invalid
submission options.

The next attempt completed 42 selection generations but FAILED in its collector:
`unname()` retained the returned text's `seed` attribute. All 42 raw streams were
verified byte-identical to the returned character values, with their seed and
terminal events retained. Recovery interprets those same observations, without
new selection inference. No holdout or coefficient decision preceded recovery.
Both original failed attempts remain failed; passed subsets retain their exact
source scopes. The protocol records both harness amendments.

Recovery independently verified 76 observations: the 42 retained selection runs,
32 newly executed held-out runs and two separate construction-prompt views.
The fixed selection rule chose coefficient **2**. Both baseline and selected
outputs contained the required literal answer on all eight final tasks. Mean
output length changed from 281.125 to 202.625 characters (paired change -78.5;
conditional 95% bootstrap interval [-162.003125, -5.75]). The random-direction
control changed length by -7.75 characters, interval [-18.378125, 1.878125].
Zero steering retained exact seeded text and actual sampled-token IDs.

This is **not complete-response brevity or broad quality evidence**: all eight
baseline outputs and six selected outputs reached the fixed 64-token cap.
The literal answer check does not evaluate all factual content, relevance or
reasoning. The eight hand-written tasks and 2,000 paired bootstrap resamples
give limited conditional uncertainty, not validated population coverage. No
holdout retuning occurred. Raw outputs, all 18 intervals, resampling indices,
selection lock and source manifests are retained in
[evaluation evidence](../tests/directions/measurements/evaluation-recovery-20261007-180659/).

The separately observed first state has 896 coordinate differences matching
`2 * direction$value` within the existing 1e-6 absolute comparison bound
(maximum error 1.3871316720259763e-7). This uses already captured data, with no
extra inference. F6c comparison/timeline retain only two states/eight history
rows, actual token IDs and recorded alignment. Four PDF/PNG views were exported;
PNG views were visually inspected. Final render-only adjustments improved legend
and caption margins without changing measurements or rerunning the model.

The final new installed `[MODEL]` reset case passed four expectations across
five eight-token calls: zero equals the seeded baseline, checked application
equals raw-vector application, the original handle reproduces its baseline
after the derived handle closes, and its intervention list remains empty.
Seven source and 28 installed hashes matched. It reuses the recorded construction
artifact and does not recapture, refit or repeat the held-out experiment.
This test-only addition follows the scoped source check below; final ordinary
CI includes the case with an explicit skip when the exact pinned model is absent.

The new vignette executed and its synthetic plot was inspected. Source build and
scoped package check passed with **0 errors, 2 deliberately omitted-vignette
warnings, 0 notes**; 180 source hashes matched without drift. The initial Quarto
launcher failed before any expression because the restricted runtime blocked its
architecture `sysctl`. Its unchanged pipeline then passed under ordinary local
runtime permissions; both receipts are retained. Local work is accepted; all
nine final remote checks and integration remain pending. No clean-CRAN, universal
provenance or release claim is made.

The ordinary golden job now pins Python 3.13.5, the exact already-used test
interpreter recorded by the new independent reference; package dependencies are
unchanged. Both the new reference self-check and the byte-identical package
fixture mirror run under the existing job name. Model-free direction tests run
in the existing four R legs; no large model is downloaded in ordinary CI.

Final static audit matched the seven final product/model-case hashes and 31
mirrored fixture files, checked 32 relative documentation links and inventoried
546 archived evidence files (6,754,787 bytes). It confirms the two approved
exports plus one S3 method and unchanged native/dependency/model inputs.
Two collector assumptions were corrected before that audit passed: the fixture
source is the reference's `goldens/` child, and the evaluation driver's original
pending-verification label has a separate successful independent receipt.
Original statuses and both failed collector versions are retained; no model or
accepted runtime gate was repeated for this audit.
