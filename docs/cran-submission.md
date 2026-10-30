# relm CRAN maintenance — 0.6.2 candidate

Updated 2026-10-30. CRAN published 0.5.0 on 2026-10-29 and requested corrections
before 2026-11-20. The published archive and the separate 0.6.1 release remain
immutable. A new 0.6.2 candidate addresses the Fedora Clang missing errno header
and GCC-ASAN/LTO unresolved native state helper during installation (D-058).
Neither reported failure reached package tests; the ASAN report is not evidence
of a runtime memory violation.

The correction preserves the engine version, dependency graph, public API,
compiler/sanitizer/LTO flags, numerical contracts and all ordinary platform gates.
Local checks do not establish exact CRAN-farm equivalence. Candidate production
installation, required CI, archive inspection and submission remain separate
acceptance steps; no 0.6.2 submission has been made.

## Historical 0.5.0 submission record

Updated 2026-10-19. **Submitted to CRAN; awaiting a response.** The maintainer
reported completing the email confirmation. Submission is not acceptance.
The exact submitted source archive has SHA-256
`f47e37cfff796229065dce77b352c97a3fe9581a679beab4ec44bdf0737a3ab1`.
Its corrected win-builder R-devel result had **0 errors, 0 warnings and 1 NOTE**
(new submission and four intentional domain terms), with 5,068 passed expectations
and 141 scoped skips. The former failed archive remains recorded as failed.

Actual win-builder Rust/Cargo 1.92 and CMake 3.31.8 built this archive. This proves
availability on that server, not general farm availability or a policy exception.
The submission explicitly disclosed the Rust/Cargo 1.85 minimum and unmet age
guidance. Do not submit a replacement while this candidate awaits CRAN feedback.
No separate 0.5.0 GitHub release has been announced by this submission.

WP15 permits completion with documented admission blockers while r-universe
continues. [WP16 documentation and compatibility](wp16-plan.md) and the project's
[30-day green-CI gate](api-policy.md) before v1.0 are separate work, not CRAN rules.
The sections below preserve the preparation stages and their original scope;
references to pending checks describe those historical stages, not a new task.

## What this candidate changes

- Declares and checks **Cargo >= 1.85.0 and rustc >= 1.85.0 independently**.
  A newer compiler does not excuse an older Cargo. Missing, nonzero, malformed
  or multiple-line version output fails before extraction/native compilation.
  Tools are found on PATH, then `~/.cargo/bin`; the package installs neither.
- Removes unused Windows live-file identity fields by limiting their storage
  to Unix. The original destructor body is unchanged. Unix identity/delivery
  checks remain; Windows retains caller-managed unpublished files rather than
  deleting an unverified pathname. This does not add Windows spill-lease or
  live-file cleanup parity. Standalone file tests precede the Windows build.
- Adds HTML Tidy to the existing production R-devel job and enables incoming
  metadata/remote checks. Tools used for checking are not package dependencies.
- Groups the already integrated CUDA/portability work under version 0.5.0 and
  admits that version in the batch/service recipes' closed version set. Exact
  prepared-library fingerprints and other dependency pins remain enforced.

The engine source archive, all 81 Rust dependency versions and their bundle,
Cargo.lock, authorship notices, API signatures and numerical bounds are unchanged
from PR71. No model, inference, held-out prompt or old acceptance suite was
replayed for these local corrections. Current-candidate full CI is required.

### Packaged-metadata correction

The first PR72 matrix at `b1dff21` ended with five successful Rust/integrity jobs
and six failed R jobs. All six stopped at the same install/configure guard:
R CMD build folded `rustc >= 1.85.0` between the operator and version, which the
new parser rejected. Actual Windows and R-devel source archives retain that
valid DCF layout. The correction normalizes field whitespace before parsing;
versions, declarations, refusal rules and native code are unchanged. A regression
fails against the original parser and passes after correction: 35 configure cases
include 12 folded-field/line-ending cases, with old Cargo/rustc still refused.
Both original CI DESCRIPTION files also pass the corrected complete script with
the real local tools, without rebuilding the engine or rerunning models.

Actual Windows three-case file controls and Linux four-case controls passed in
the failed matrix; Tidy5.6.0 installed successfully. R-devel incoming checks
reported the expected new-submission NOTE. Full package tests and later HTML
checks did not run after the install failure; these are not current acceptance.
Raw failures and correction evidence:
[`pr72-dcf-b1dff21`](../tests/cran/evidence/pr72-dcf-b1dff21/).

## Rust and Cargo: technical floor versus admission policy

Cargo resolves/builds packages; rustc compiles Rust. Distributors can package
them separately. Check their executable output with `cargo --version` and
`rustc --version`, rather than assuming the OS package version means both match.
The locked Arrow 59 crates declare Rust 2024 edition and rust-version 1.85.
[Rust 1.85 introduced the stable 2024 edition on 2025-02-20](https://blog.rust-lang.org/2025/02/20/Rust-1.85.0/).
The existing Linux oldrel CI leg tests this floor on the full source package.
Lowering DESCRIPTION alone would misrepresent the build requirement.

[CRAN's Rust guidance](https://cran.r-project.org/web/packages/using_rust.html)
asks for testing Cargo at least two years old, preferably four, and conservative
requirements compatible with system tools. On 2026-10-19, version 1.85 is less
than two years old; it reaches that age on **2027-02-20**. This preparation does
not satisfy the age guidance and no exception has been requested or granted.
Explicit version checks fix an installation defect; they do not waive policy.

The founder chose direct form submission with this issue disclosed, after the
technical checks pass, without a preliminary email. The tested dependencies stay
unchanged; no CRAN exception has been granted. Alternatives if CRAN refuses are waiting
until the two-year date or undertaking a separately authorized Arrow/dependency
downgrade with affected validation. The candidate does not silently take either
route. A new stable toolchain on GitHub is not evidence of CRAN farm availability.

## Other portability and resource limits

The [published CRAN flavors](https://cran.r-project.org/web/checks/check_flavors.html)
identify their C/C++ compilers but do not establish a Cargo/rustc/CMake version
for this package. Their linked Fedora details likewise do not confirm those
tools. CMake >= 3.28 and the Rust floor are now confirmed on the specific win-builder
R-devel environment described below. Availability on other CRAN farm configurations
remains unconfirmed; hosted CI does not establish it.

The wrapper installation follow-up replaces `cargo run --bin document` with
`Rscript tools/generate-wrappers.R`, after linking the package DLL. The installing
R calls extendr's registered metadata generator, so production and selftest
wrappers come from the actual DLL. The optional maintainer `document` binary
remains available but is no longer linked/executed by package installation.
This avoids the standalone executable's requirement for a linkable `libR`.
A dedicated Linux CI check builds real R4.6.1 with `--disable-R-shlib`, then
installs the production package with Cargo/rustc1.85 and inspects its metadata,
source functions and ELF dependencies without model calls. PR73 passed this actual
non-shared-R installation check; its retained receipts bind 250 R functions,
27 profile fields, three notices, no self-test hooks and no libR.so dependency.
No compiler/toolchain installation, registry download or model download happens
inside the package's locked offline build. Package compilation uses two Cargo
jobs; check-mode owned context parameters are capped at two threads.

At accepted PR71 source, the verified Windows/R-devel source tars were 7.77/8.36 MB
with no outer paths over 100 bytes, six built vignettes and exact installed
attribution. Linux installed size was 126.4 MB, including 113.26 MB of debug
sections. Those diagnostics remain present; nothing is stripped to obtain a
smaller size report. These are **parent measurements**, not new 0.5.0 tar sizes.

The official current PACKAGES index and Archive directory, fetched on 2026-10-19,
contained no case-insensitive `relm` name entry; no current package dependency
field named relm. This is a dated observation, not a reservation or admission
decision. GitHub repository/issues and the r-universe package URL returned HTTP
200. Exact snapshots/digests are retained locally with the finalization evidence.

## Evidence and handover

PR71 at `846d2e5` passed all eleven ordinary jobs; founder merge `21b2589` has
the identical accepted tree. Windows production source checks reported
4,973 expectations/141 scoped skips and zero check errors/warnings/notes.
R-devel reported 4,981/141, a passing PDF manual and one missing-Tidy NOTE.
Four Unix R/service jobs and complete Rust release/no-spill/integrity jobs passed.
The Windows compiler unused-field diagnostic was separate from R check status.
The earlier GCC16 correction and all original failed runs retain their scopes.

Local finalization controls and their source bindings are in
[`tests/cran/evidence/finalization-20261019`](../tests/cran/evidence/finalization-20261019/).
They exercise the affected code, not a newly installed 0.5.0 engine. Actual
Windows execution, Tidy/incoming results, final source tar and its platform
checks must come from the new ordinary eleven-job matrix. Capture the results
locally and in the PR; do not trigger another matrix merely to commit receipts.

Before the authorized upload:

1. Inspect all twelve current outcomes, actual routes, diagnostics and allowed skips.
2. Bind one 0.5.0 source tar by SHA256 and source inventory; record its incoming
   checks, size, examples, vignettes, PDF, installed notices and platform results.
3. Complete the non-shared-R check and disclose the Rust-age/system-tool limits
   in the form comments. The founder authorized this route without a preliminary email.
4. Complete the [submission comments](cran-comments.md) with that exact candidate,
   then submit through the official form. The agent may merge after all checks
   pass; a separate release is not authorized by this decision.

The [CRAN submission checklist](https://cran.r-project.org/web/packages/submission_checklist.html)
expects current R-devel `--as-cran` results and disposition of significant notes.
No CRAN submission, preliminary email, release tag or separate publication has
occurred. The selected archive has since been uploaded once to win-builder;
the failed result and focused correction are recorded below.

## Post-PR72 preparation (2026-10-19)

PR72 is integrated at `7310ab8` with the exact accepted source tree. All eleven
checks passed, including production Windows/R-devel, HTML Tidy and the full
manual; the only R-devel check NOTE was `New submission`. Exact source receipts
remain local and in PR72. These are parent results, not acceptance of the new
R-hosted generator. No compiler, dependency, kernel or public API is changed by
that follow-up. Its focused local evidence and ordinary final matrix are separate.

The final upload must be built with R release/patched and that **same archive**
checked with R-devel. An R-devel-built archive is useful evidence but does not
by itself satisfy the release-build recommendation. Bind the selected archive
and all external results by SHA256; reuse passed unchanged stages.

See [the authorized form-submission procedure](cran-request.md).
No numerical acceptance probability is justified by the available evidence.
Current farm tool availability and disposition of the Cargo-age guidance still
require external confirmation. Twenty or thirty days of use, publicity or prior
r-universe downloads are not an admission prerequisite; the project's 30-day
green-CI criterion is separately attached to v1.0.

## First exact-archive win-builder result (2026-10-19)

The R-release-built archive `relm_0.5.0.tar.gz` (7,772,402 bytes, SHA256
`cc36c8819ee28fc2b261289b9ea902aa9d852ded1ed2844f6636381e622b357d`)
was checked by win-builder with R-devel r90707 on Windows Server 2022.
Actual Cargo/rustc 1.92.0 and CMake 3.31.8 built and installed the package;
compiled-code/Rust checks, examples, vignette rebuild and PDF/HTML manuals passed.
This demonstrates tool availability on that server, not an exception to the
Cargo-age guidance or availability on every CRAN farm.

The whole check **failed**: 1 ERROR, 1 NOTE, zero warnings; 5,066 expectations
passed, two failed and 141 were explicitly skipped. Both failures came from one
child process using unqualified `new('externalptr')` when methods was not attached.
The process exited before the invalid-pointer loop; this was not a demonstrated
failure of the runtime pointer guards. The NOTE identifies a new submission and
the domain terms `downloader`, `embeddings`, `interpretability` and `vendored`.

The correction qualifies `methods::new()` using the already-declared dependency.
That same test now starts its child without methods in `R_DEFAULT_PACKAGES`,
asserts methods is not attached, and restores the parent's environment afterward.
All original refusal, close, panic-output and deadline assertions remain intact.
One original/fixed local comparison on the retained production DLL reproduces
the same two failures, then passes all three outer expectations with zero warnings,
six classed native refusals and three safe closes. No model or native rebuild
was used. The first local driver stopped before tests because its dependency
library was not selected; that failure is retained, and no dependencies were installed.

Raw external logs, selected test sources and focused results are retained in
[`win-builder-methods-20261019`](../tests/cran/evidence/win-builder-methods-20261019/).
The downloaded Windows binary and full local evidence remain outside Git.
The original win-builder check stays failed. Current automatic CI and a corrected
release-built archive checked by win-builder are required before CRAN submission.
PR74's current-document privacy cleanup is merged; the founder explicitly chose
to leave history unchanged. No personal planning is included in the selected archive.
