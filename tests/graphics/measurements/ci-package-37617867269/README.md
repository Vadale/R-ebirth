# F6c ordinary CI failure and correction

Source: `9312e38081854a09aeffd50fc38f63c857bf8585`.
[Failed R run 37617867269](https://github.com/Vadale/R-ebirth/actions/runs/37617867269).
The five Rust checks passed in run37617867429. All four R matrix jobs failed
exactly the existing `test-package.R` export allowlist: it omitted D-044's already
approved `llm_compare` and `llm_timeline`. No new graphics/numerical test failed.
Each Mac leg recorded 3,365 passing expectations, one failure, zero warnings and
79 explicit skips; each Linux leg recorded 3,359 passing, one failure, zero
warnings and 80 skips. These are failed overall jobs, not successful acceptance.
Full available failed-step logs and job/step metadata are retained here.

The spec-first check still requires exact set equality. Its expected set is
extended only by the two functions already approved in API-GRAMMAR section12;
no assertion, export, signature or CI gate is removed. The earlier focused
local suite did not run this package-wide gate, which allowed the omission to
reach CI. The corrective verification includes that exact installed test file.

The full check also reported an `object.size` namespace NOTE in three graphics
helpers and two existing live-state helpers. Qualifying all 19 calls as
`utils::object.size` fixes resolution without a dependency/import change or
alteration to arguments, arithmetic or bounds. `source-equivalence.json` proves
both source files are otherwise byte-identical. Original source snapshots are
retained. The corrected package will use the already accepted native DLL, with
no native compilation or model inference required for this correction.

Targeted detached verification covers seven installed cases / 28 expectations
(package exports/registration and graphics materialization), package code-usage
analysis, and source build/scoped check. Final receipt verification PASSED: the existing seven cases / 28 expectations,
zero failures/skips/test warnings; no namespace/code-usage messages; source build
and scoped check with zero errors, two deliberately omitted-vignette warnings and
no NOTE. All 136 source hashes match. Full exact-head CI must still pass after the
correction is published.

The first corrective local driver (`ci-package-20261007-142016`) completed all
seven cases successfully: per-case expectations 1, 1, 7, 8, 4, 4, 3 (28 total),
zero failures/skips/test warnings. Its hand-counted aggregate guard wrongly
expected 27 and therefore failed after tests, before code-usage/build/check.
The original script/log/CSV remain unchanged. The corrected resume verifies the
actual seven receipt counts, unchanged source and installed hashes, then runs
only the previously unexecuted stages. It does not repeat installation or tests.
