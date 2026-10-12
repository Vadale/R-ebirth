# relm 0.4.0 release record

**Published 2026-10-12.** The [GitHub release](https://github.com/Vadale/R-ebirth/releases/tag/v0.4.0)
and annotated tag identify integrated commit
`3bd5da7399dc163d8c9e4a4e1865a875e7186e71`, the exact accepted PR66 tree. All nine
final PR checks passed. Source, Mac binary and checksum assets were published and
their sizes/digests verified. No CRAN submission or Windows/CUDA acceptance is
claimed; numerical and research limitations remain.

## Verified r-universe installation

The source and Mac arm64/R 4.5 binary served by r-universe identify the same
release commit. [The Mac build](https://github.com/r-universe/vadale/actions/runs/38273228791/job/114897804233)
completed its build, check and store stages; the actual package check reported OK.
A normal R repository download was installed in a fresh library on the existing
Mac. Version 0.4.0 and `RemoteSha` matched, and all 49 installed files were
byte-identical to the downloaded binary payload. This was not a clean VM test.

One cached Qwen CPU load and one seeded, eight-token-limit generation returned
`Ready`, then the handle closed. No model or dependency download was needed.
The binary was built under R 4.5.3; the host R 4.5.1 emitted that version warning,
which was retained. The DLL contained no native fixture hooks.

| Distributed artifact | SHA256 |
| --- | --- |
| r-universe Mac arm64 binary | `ee716dfb0d403e3136d5fa84edf406d0e128d5d57e2698f83580cb01168eac1d` |
| Its installed DLL | `98247f18d59ba46c710f66f3ddbe94e7b390d0e040b5ef4c3a2f34ea21745227` |

Four Linux jobs also succeeded. Windows and WebAssembly jobs failed;
the whole r-universe workflow is not reported as green. Those platforms are
outside this release's accepted Mac/Linux scope. The chronological packaging
record below preserves the original failures and each build's source scope.

## Integrated maintenance

PR65 merged at `60ccdcb3e28742501aac86021349f8e4552a8a79`. Its tree matches the
approved `a77e652` candidate. All nine final checks passed, including the four R
platform checks, Rust default/no-spill tests and release ownership stages. Those
checks used explicit maintainer fixture builds; final production release assets
are verified separately.

The release includes the Phase6 research APIs and Phase7 public walkthrough,
shared R validation/condition handling, duplicate trace-coordinate refusal,
public older-R state inspection, production omission of native fixture hooks,
and the updated simplifier compendium. See [NEWS](../rebirth/NEWS.md) and the
[maintenance plan](maintenance-0.4.0-plan.md),
[simplifier compendium](simplifier-compendium.md) and
[support matrix](supported-workflow.md). The affected local maintenance checks
and one integrated review/closure are recorded in the
[source-bound receipt](../tests/maintenance/0.4.0/local/owner.json).

## Packaging corrections

The website configuration omitted five current help topics and two articles;
its configured URL was absent from DESCRIPTION. The corrected complete index
passes `pkgdown::check_pkgdown()` using the existing RStudio Quarto installation.

The first production source build generated all six bundled vignettes. Its
subsequent `R CMD check --as-cran` failed during installation: the FFI build
script invoked bare `R` despite the installation's `R_HOME`. The check's PATH
guard deliberately rejects that call. The corrected launcher uses the explicit
host executable, retains PATH discovery for standalone Cargo builds, and reports
configuration output on failure.

A focused execution reproduced the original rejection using the actual guard.
Both corrected invocation modes compiled the real C accessor and produced
identical object bytes. Each retained one warning from the installed R header;
no diagnostic was suppressed. No model call occurred. Original logs, source
hashes and the focused results are retained in
[packaging-r-path](../tests/release/0.4.0/packaging-r-path/).
The failed check remains failed. The corrected package check reused the already
rendered vignette files; all 18 remained byte-identical.

## Warning-corrected production package

The final affected Mac production check reports **zero errors, zero warnings
and one NOTE**. The note identifies a new CRAN submission and the 5,152,966-byte
source archive; this release does not submit to CRAN. The check now completes
shell portability, pragma and HTML-manual validation. Examples, six vignette
checks/rebuilds and PDF manual pass. Package tests report 5,010 passing
expectations, no failed assertions or warnings, and the same 130 explicit skips
listed below. The installation log contains no compiler/linker warning.

Fresh installation matches all 49 binary files, 250 source function
bodies/formals and the unchanged 27-field compiled profile, with no native
fixture hooks. Independent inspection verified 816 staged sources and all 814
archive members: 794 exact repository files, 19 generated files and DESCRIPTION
with equivalent original field values plus R build metadata. The 18 bundled
vignette files are unchanged from the accepted parent build. The original driver
status is retained with a separate passed owner receipt.

| Corrected artifact | SHA256 |
| --- | --- |
| Source tarball | `48978da212cad853ce56055a8d8733328ce4835053b3d9c12e8e8a9544339048` |
| Mac arm64 binary | `971b72086c4bce52170d191e1bcc24af6a7b373c98a9b6d76e5a5855f16c04d2` |
| Installed DLL | `8aee29a6b22fd630dbb570b5b0260559d49bac34e2862bad41ee611908b70bb4` |

See [retained outputs and owner verification](../tests/release/0.4.0/warning-cleanup/completed/).
These assets superseded the parent candidates below and were subsequently
published on GitHub. Website and real RStudio observations retain their parent-source
provenance. No model inference was replayed during the warning correction or
artifact inspection.

## Parent built production package

The corrected source tarball completed `R CMD check --as-cran` with **zero errors,
two warnings and two notes**. Installation, package tests, examples, vignette
checks/rebuilding, compiled-code/Rust checks and the PDF manual passed. Package
tests reported 5,010 passed expectations and 130 scoped skips: 62 production-
omitted native fixtures, 62 optional-model tests, four repository-only fixtures,
one network download and one CRAN-gated model case. The earlier full CI separately
exercised explicit maintainer fixtures.

A fresh Mac binary installation reports 0.4.0, matches all 250 source function
bodies/formals and all 49 binary files, has no registered native fixture hooks,
and retains the 27 accepted compiled allocation-profile values. Codetools is
silent. The 813-file source archive contains 793 exact repository files, generated
vignette material and DESCRIPTION with unchanged original field values plus R's
four build metadata fields. The only original/corrected tarball differences are
DESCRIPTION metadata and the FFI build launcher.

The package website built all current help and articles. All 1,051 inspected
local file references resolve across 46 HTML pages. Nine emitted figures were
visually inspected; no browser-interaction claim is made. The website retains
12 false model-dependent `examplesIf` notices; those optional examples were not
executed without their models.

| Artifact | SHA256 |
| --- | --- |
| Source tarball | `e801ba6b478e4aa768f1fd1d947dec15cf42646416f9340b1c2e647e504a47b9` |
| Mac arm64 binary | `3dd59e5e0d95d04f644519fce3a6416a4c798e9d3f5cbb8088e4ba7c214d4b0c` |
| Installed DLL | `1bc5f033870e3fbb0917989ba2f79695f12301e0383d5d3b33a8489846ddea78` |

These superseded parent assets were not published. Compact raw logs, source/installed hashes
and separate owner verification are in
[completed packaging evidence](../tests/release/0.4.0/packaging-r-path/completed/).
The original driver status remains `awaiting_owner_verification`.

## Actual RStudio smoke

RStudio background job `F3B7C316` completed successfully in 64 seconds on
2026-10-12, using the fresh production 0.4.0 library above. No user workspace
was imported or exported. The seven bound inputs and all 49 installed files
still match their pre-run hashes. Original status, all 323 job-output records,
saved observations and separate verification are retained in
[RStudio evidence](../tests/release/0.4.0/rstudio/rstudio-owner.json).

The shipped README quickstart, async/streaming and structured-output blocks
passed. Saved observations include three normalized 896-dimensional embeddings,
896 trace coordinates, the seeded async response and the actual JSON output.
Demo A passed its recorded exploratory gates: best layer 11, AUC 1.0, steering
shifts +0.118576 and -0.867675. Its saved PNG was visually checked for readable,
unclipped labels. These are historical exploratory checks, not new evidence of
generalized efficacy.

Demo B passed with seed 20240707 and the full 1,200-row corpus: 12 clusters and
0.1% noise. The first 16 abstracts were embedded twice with exact identity;
the full corpus was embedded once, then reused for both seeded pipelines.
Cluster assignments, labels, silhouette, cohesion, top terms and cosine
statistics matched exactly. The original status's phrase “duplicate embeddings”
must be read within that scope; full-corpus embeddings were not computed twice.
Demo B result arrays and temporary figures were not persisted by the existing
demo; its actual PASS output and source assertions are retained. No inference
was repeated to inspect or archive either demo.

## Original diagnostics and subsequent corrections

- `checkbashisms` is unavailable on this Mac, so that shell-portability check was
  not completed. This is one package-check warning.
- Pinned vendored C/C++ contains nonportable and diagnostic-suppression pragmas,
  reported as the other package-check warning. No vendor source was changed.
- The two notes concern incoming new-submission/tarball size and the system HTML
  Tidy being too old for full HTML validation. The local-link inspection does not
  substitute for that validator.
- Native linking emitted one duplicate `-lc++` warning. Package tests also retain
  the external testthat R4.5.2-versus-host-R4.5.1 warning. Neither is hidden by the
  test report's zero assertion-warning count.
- Demo A emitted 30 warnings: 24 small-fold warnings switch the cross-validation
  selection metric from AUC to deviance, and six zero-length interval arrows
  are omitted by the plotting device. All messages remain in the saved warning
  records and the ordinary job output. README and Demo B emitted no R warnings.

The founder subsequently asked to correct avoidable warnings before accepting an
exception. The Demo A source now requests the same small-fold deviance metric
that glmnet previously selected automatically and draws collapsed intervals as
ticks. A focused model-free comparison preserved fit/selection/coefficients
exactly, and the saved result plot now renders without warnings. The original
RStudio job and its30warnings remain unchanged historical evidence; this is not
a repeat model run. See [focused correction](../tests/release/0.4.0/demo-warning-fix/scope.md).
The founder then requested correction of the remaining warnings. D048 now
records the bounded cleanup. Local checkbashisms 2.26.12 and HTML Tidy 5.8.0 are
available; testthat 3.3.2 was rebuilt under the existing R4.5.1 into an isolated
tools library. No package dependency was added or upgraded. Makevars now
explicitly selects the C++17 linker and Darwin no longer repeats its standard
library flag. The demo restores graphics parameters before closing its output
device, avoiding an incidental `Rplots.pdf`.

Vendor patch 0005 removes 64 GCC/Clang diagnostic directives in 14 files, including
three files not listed by R's narrower pragma scanner. It removes suppression
rather than hiding pragmas from the scanner. Optimization directives, numerical
statements and the b10828 upstream/pre-patch identities stay unchanged. Both tree
integrity and reverse-patch coherence pass; R's pragma check is now empty.
The affected production rebuild passed with the zero-warning result above.
Its six bundled vignettes are carried byte-for-byte;
the earlier site and RStudio results retain their original source scope.

The original warning-bearing runs remain unchanged historical evidence. The new
package check passes without a warning exception; D035 still applies only to
0.3.0. A clean package check does not imply completed CRAN readiness.

## Completion and remaining limits

Source publication/follow-up CI, tag/assets and the fresh r-universe installation
are complete as recorded above. The original package, documentation and RStudio results are
retained; their assets are not relabelled as the newly patched build. The current
Mac package check satisfies the release skill's zero-error/zero-warning gate,
with its single incoming NOTE explained. No warning waiver is required.
External-user feedback stays deferred under D047, without an external usability
claim. No CRAN submission or Windows/CUDA acceptance is included.

The CPU long-prefix numerical oracle uses explicit F32 cache/unfused attention,
with separate default-context arithmetic/write/zero-identity guards. Production
precision policy and frozen bounds remain unchanged. This does not establish
F64 equivalence for default execution. Earlier cross-schedule outliers remain
unaccepted. The fixed-corpus projection experiment remains modest and truncated;
no quality promotion or consumed-holdout rerun follows from this release.
