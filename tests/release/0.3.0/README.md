# relm 0.3.0 release receipts

These records validate packaging and the release version boundary. They do not
replace or relabel the original S1, D2, probe or service acceptance evidence.

- `initial-as-cran.log`: complete first source-tarball check on macOS arm64,
  R 4.5.1. Tests, examples, vignettes and manual passed, but the result is
  **3 warnings and 3 notes**, not a clean CRAN check. A zero process exit code
  alone did not establish the release gate.
- `initial-packaging.json`: source/binary hashes and packaging commands. Its
  status explicitly records the warnings found during review. The original
  runner's process-completion status has not been treated as acceptance.
- `applications.json`, `batch-version-boundary.log`, `service-environment.json`:
  the installed 0.3.0 binary passed 466 model-free batch process/identity checks
  and 11 fresh-process service environment checks. A new physical dependency
  library was prepared; historical development snapshots were not mutated.
- `rstudio-smoke.json`, `rstudio-version.txt`, `rstudio-job-id.txt` and
  `rstudio-smoke.R`: actual RStudio 2025.09.1+401 background-job execution against
  the built 0.3.0 package, with no user-workspace import/export. Exact README
  quickstart/schema blocks passed. Demo A passed the existing nightly core
  expectations (AUC >= 0.70 and positive-steering shift greater than negative).
  Demo B reproduced clustering, labels and statistics on the complete fixed
  1,200-document corpus with seed 20240707. The script preserves original local
  paths as execution provenance; it is not a portable installed-package test.

The RStudio run reported 30 warnings after successful completion.
`demo-warnings.json` and `demo-warning-audit.R` retain a bounded diagnostic:
24 Demo A warnings report fewer than ten observations per fold, causing glmnet
to select regularization by deviance instead of AUC; six report zero-length
interval arrows omitted by base graphics. Both demos still meet their recorded
checks. These are limitations of the historical small-data demonstration, not
evidence for the new grouped probe's statistical validity.
Demo A's selected historical estimates remain exploratory, not independent
scientific inference. No larger-model or extraction-quality claim follows.

Packaging follow-up excludes the website-only `_pkgdown.yml` from the source
archive and adds the POSIX interpreter line to `cleanup`. The missing shell
checker was obtained from Debian devscripts v2.26.9 in a temporary tool directory.
`corrected-as-cran.log` retains the complete second source install/check:
two CRAN-specific warnings and four notes. A generated Quarto cache caused the
additional note. The final packaging-only pass removes it and compares every
archive member; its check reuses the already verified installed package and is
explicitly not a new native installation. The Rust build warning is not erased
by the `--no-install` follow-up.

`smoke-carry-forward.json` independently compares 626 R/native/test/reference and
README/NEWS/model-registry files across the first two archives: every hash is
identical. Thus the successful application/RStudio checks retain initial-package
provenance without another identical model run. The final package comparison
separately checks the archive contents after excluding cache data.

`pkgdown.log` records 12 false `@examplesIf` conditions for absent text/vision
model environment variables, rather than broken pages or R errors. Model-gated
reference examples remain skipped in that model-free site build; actual text
README/demos run separately. No new vision execution is claimed.

Remaining CRAN-specific warnings and distribution verification are tracked in
the [release report](../../../docs/release-0.3.0.md). No acceptance threshold or
native implementation changed.

`final-packaging.json` and `final-packaging-check.log` record the final archive
comparison and packaging-only check: one upstream-pragma warning, three notes;
no hidden-cache or top-level warning. `DESCRIPTION` differs only by its `Packaged`
timestamp. Tests and vignette execution are explicitly skipped by `--no-install`
and remain covered by the preceding full check. `finalize-package.py` retains
the exact bounded packaging procedure and byte-comparison assertions.
