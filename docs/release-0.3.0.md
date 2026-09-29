# relm 0.3.0 release verification

Date: 2026-09-29. Publication authorized by the founder after WP12b integration.
Current status: candidate verification; tag/publication and distribution checks
are not yet complete.

## Delivered scope

This release groups the completed structured-output, native Spark, statistical
probe, restartable batch and local service increments. User-facing changes are
in [NEWS](../rebirth/NEWS.md#relm-030), the
[package quickstart](../rebirth/README.md) and the
[installation guide](getting-started.md). Application recipes now require
exactly relm 0.3.0 and a freshly prepared environment.

The release diff introduces no new core export, dependency or native inference
algorithm. Historical acceptance remains bound to its measured sources. The
service's 1,000-request stress is not rerun or relabelled as release-source
execution; its exact scope and the retained teardown marker remain in
[service implementation](service-implementation.md). The failed D1 quality
evaluation is unchanged.

## Built-package verification

The [release receipts](../tests/release/0.3.0/) retain the actual commands,
hashes and outcomes. On macOS arm64/R 4.5.1:

- Source build, fresh binary installation and version/path checks completed.
- Package tests, R examples, vignettes and PDF manual passed in the initial
  `R CMD check --as-cran`. The check also reported warnings and notes below.
- The pkgdown site built, including statistical probe reference pages. Its 12
  warning messages identify false model-dependent `@examplesIf` conditions:
  text/vision model variables were deliberately absent in the model-free site
  build. Those reference examples were skipped, not falsely reported executed.
- An actual RStudio background job ran the exact README quickstart and schema
  example against the built package, then both pinned-model demos. Demo A met
  existing core gates; Demo B reproduced all recorded statistics on the full
  1,200-document fixed corpus. Its seed was 20240707.
- Fresh application environments passed 466 batch process/identity assertions
  and 11 service environment/refusal cases. These checks specifically cover the
  new exact package version; they introduce no extraction-quality claim.

The RStudio demos emitted 30 warnings, captured by a separate bounded audit.
Twenty-four come from the historical Demo A's small folds: glmnet selects
regularization with deviance rather than AUC when fewer than ten observations
occur per fold. Six concern zero-length plotted interval arrows. Both demos
passed their existing checks; Demo A's historical selected estimates remain
exploratory. This is separate from the approved grouped `llm_probe()` protocol.

The corrected full installation/check also passed the package tests, examples,
vignettes and manuals. An independent SHA256 comparison found all 626 selected
R/native/test/reference and README/NEWS/model-registry files unchanged between
the initial and corrected archives. Initial application/demo receipts therefore
retain their original provenance; the packaging correction does not require
repeating the unchanged model work.

## CRAN check findings

The first check completed with **zero errors, three warnings and three notes**.
It must not be described as a clean CRAN check.

1. Top-level packaging/tooling: `_pkgdown.yml` was included in the source
   archive and `checkbashisms` was absent. The follow-up excludes the site
   configuration, supplies the Debian checker temporarily and explicitly marks
   the cleanup script as POSIX shell. The corrected full check passes this gate.
2. Vendored C/C++ contains pragmas classified as non-portable or suppressing
   diagnostics. No upstream code or integrity pin is changed merely to suppress
   this warning.
3. The source build can obtain locked Rust crates online. Full offline crate
   vendoring belongs to Phase 9 under the accepted D-013 implementation note and
   [architecture](../ARCHITECTURE.md). This release does not submit to CRAN.

The corrected full check has **two warnings and four notes**. Three notes concern
a new CRAN submission/source archive size, inability to verify the current time,
and an old local HTML Tidy executable. They are retained as tool/environment
limitations. The fourth identifies a generated Quarto cache. A packaging-only
follow-up excludes that cache, reuses the built vignettes and verifies archive
contents before a `--no-install` check against the verified installed package.
The final packaging check completed with **one warning and three notes**:
hidden files and top-level packaging now pass. The member comparison confirms
only cache removal and a changed `Packaged` timestamp. Installation, package
tests and vignette execution are explicitly skipped in that follow-up; their
successful corrected full-check evidence remains the reference. This avoids
recompiling unchanged code and does not erase the original Rust installation
warning or claim a second native acceptance.

Final source archive SHA256:
`854b802ae1a47b030e6c5125cae8d13afbd954f2a4447c704b0ad831535ae5de`.
Verified Mac binary SHA256:
`d8d09f35df2452c87a51cb6562960e55207798f3bd083edb2dd01e89472094ba`.
The binary comes from the corrected full source installation; its runtime
inputs are byte-identical to the final archive. Receipts retain both identities.

The local release checklist explicitly requests zero warnings. A founder decision
on the two remaining CRAN-specific warnings is pending before publication.
No waiver is inferred from the process exit code or from the successful tests.

## Publication and next work

The release PR must have all nine ordinary checks green before an exact-head
merge. The annotated tag and GitHub release then identify the integrated source.
r-universe follows `main`, so its version, source commit and actual binaries must
be inspected independently, followed by installation in a clean Mac library.
The release page and PR will record those final external results without a
self-referential commit/check cycle. No Windows/CUDA or CRAN acceptance is claimed.

After verified publication the default next scope is WP9 async generation, then
WP10 token streaming. See the [public execution plan](structured-production-plan.md#after-the-030-release).
No new work package starts as part of this release.
