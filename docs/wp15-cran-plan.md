# WP15 — CRAN source packaging and CPU portability

Status: implementation authorized by the founder on 2026-10-18 (D-051).
Base: integrated Phase 8 commit `f74d9925a77a9508696583e4246584f886582303`.

## Acceptance (verbatim from ROADMAP)

**WP15 — CRAN prep:** vendored crates per CRAN Rust policy; WRE compliance; submission. *Acceptance:* accepted (or blockers documented; r-universe continues).
Keep CUDA optional. Check Windows CPU build feasibility through CI/win-builder
without requiring a local Windows machine; resolve or disclose actual blockers.
Windows GPU acceptance and optional interactive VM work remain separate later work.

## First milestone

1. Bundle the unchanged pinned engine as source, with shorter archive member
   paths, instead of renaming CUDA kernels or dropping supported functionality.
   Preserve the expanded Git tree, patches, licenses and exact file bytes.
2. Vendor the existing Cargo.lock graph without adding/updating dependencies;
   retain authors, licenses, checksums and an offline configuration. Make package
   builds locked and explicitly limited to two Cargo jobs.
3. Verify archive contents, configure/extraction and offline dependency resolution
   without native execution first. Then build/check the actual source package
   in an isolated disk-backed workspace and test Windows CPU through hosted CI.
4. Inspect real outcomes before any affected correction. No blind retries,
   suppression, altered numerical tolerances or repeated Phase 8 benchmarks.

The source archives are distribution inputs, not compiled binaries. A maintainer
preparation command and a model-free integrity check must keep them synchronized
with their original sources. The normal install must not need Python, Git,
network access to Cargo registries, a GPU or the CUDA SDK.

Four exact precompiled wasm assets from the locked wit-bindgen crate are omitted
from the source bundle. Their original SHA256 values and Cargo file-inventory
adjustment are recorded in `rebirth/tools/bundled-sources.json`. All native
source and license bytes are preserved; upstream build.rs returns before using
these assets on non-wasm targets. Wasm is not a supported WP15 distribution target.

Preparation (outside package installation): `cargo vendor --locked
--versioned-dirs --manifest-path rebirth/src/rust/Cargo.toml <disk-vendor-dir>`,
then `python3 tools/prepare-cran-sources.py --vendor-dir <disk-vendor-dir>`.
CI runs `--check`, which never fetches or regenerates the bundles.

## First local result (2026-10-18)

The scoped source-package gate passed independently: 7,426,568-byte tarball,
321 files and no paths over 100 bytes. Of these, 320 match repository files
exactly; DESCRIPTION preserves all 19 original fields and adds four standard
R build metadata fields. All 766 engine files are retained in the nested source
archive. Cargo resolved the Linux, Windows and macOS dependency graphs from the
shipped vendor directory with an initially empty Cargo cache and locked/offline
flags; this is dependency resolution, not cross-platform compilation.

An ordinary CPU-only `R CMD INSTALL` from that tarball succeeded offline with two
Cargo jobs and no compiler warnings. The fresh library matches 250 R function
bodies/formals, has no production selftest hooks, and exposes the current 27-field
allocation profile. The shared library has no CUDA dependency or TEXTREL.

The initial installation probe incorrectly expected text from the documented
`no_vocab` synthetic fixture. It failed with the correct tokenization error;
the package itself had installed successfully. The corrected probe checks the
specific condition class and native handle closure. It passed using the same
installation, with no rebuild/reinstall. Two total tiny-model loads and two
refused generation attempts are retained across the failed/corrected probes;
there was no successful text generation or research experiment. The earlier
inspector failure on Cargo's empty `registry/CACHEDIR.TAG` is also preserved;
its three successful metadata commands were carried without replay.

Source build used `--no-build-vignettes --no-manual`. Full checks, vignettes,
R-devel and Windows outcomes remain pending. Original statuses are not relabeled;
separate verification and source-bound evidence are in
`tests/cran/evidence/2026-10-18/` (manifest
`6829b05d4bf0b23084313dce4c4d3993afc1938e163636c2addf3075fb407907`).
One integrated independent packaging review and its two-P2 closure are recorded
in `docs/wp15-cran-review.md`.

## First Windows CI result and bounded correction

The first Windows CPU job on `08d9cf0` failed before native compilation completed
or package tests began. Its CMake source path used Rust's Windows verbatim path
syntax; generated MSYS Makefiles refused prerequisite parsing. CMake also
reported overly deep object directories. The correction keeps ordinary absolute
Windows paths, shortens native outputs inside the same Cargo profile/build-unit
boundary, and removes the build script's erroneous Darwin link flags on Windows.
Unix path handling and Linux/macOS library plans remain unchanged.

Seven new build-only controls, focused formatting/lints and YAML parsing passed
locally with no engine build or models. The next Windows run passed the seven controls and compiled its first engine
archives without those path errors/warnings, but failed on missing Rtools thread
power-throttling declarations. Whole Windows acceptance remains pending. Raw failure, source bindings and interpretation limits:
[`tests/cran/evidence/windows-08d9cf0/`](../tests/cran/evidence/windows-08d9cf0/).
No archive regeneration, dependency/version changes or numerical changes.

## Rtools header compatibility

The next job on `965ba4b` reached ggml-cpu.c and exposed missing MinGW thread
power-throttling declarations. A relm-owned, declaration-only compatibility
header now supplies the documented ABI when absent, forced into that one source
through a Windows CMake hook. Existing SDK definitions, engine source bytes,
scheduling calls and kernels are preserved. Local mocked-SDK controls pass;
actual Rtools ABI/link and package acceptance remain pending the next matrix.
Raw evidence: [`windows-965ba4b`](../tests/cran/evidence/windows-965ba4b/).

The new preflight on `fe62517` failed before the full package build: the adapter
included `windows.h` before ggml selected its Windows API target, hiding
`SetThreadInformation`. The adapter now includes the actual pinned `ggml.h`
first. New focused controls reject the previous adapter, preserve the upstream
default and an explicit target override, and retain the ABI/single-source checks.
They pass locally with no engine/model execution; actual Rtools and full Windows
acceptance remain pending. Evidence: [`windows-fe62517`](../tests/cran/evidence/windows-fe62517/).

## Windows archive collection

The `49a15c2` job passed the actual Rtools ABI/API preflight and compiled all
seven native engine/bridge archives. Installation then stopped in relm's archive
collector: upstream ggml emits `ggml.a`, `ggml-cpu.a` and `ggml-base.a` on Windows,
while the collector required a `lib` prefix. It now reads the actual platform
names and preserves the existing canonical `lib*.a` copies for Cargo/R linking.
No compiled bytes, link directives, vendor inputs or numerical behavior change.
Two new build-only naming controls pass locally; full Windows link/install and
package checks remain pending. Original failure and real SDK receipt:
[`windows-49a15c2`](../tests/cran/evidence/windows-49a15c2/).

## Windows executable system imports

On `79d1c1b`, the archive collector and FFI static-library build completed. The
wrapper generator then failed to link three Windows registry functions used by
ggml's CPU description. Cargo omitted `advapi32`, already present in the R DLL
link. The Windows-only Cargo plan now includes it; Unix plans are unchanged.
Three focused link-plan controls pass locally, and the real Rtools preflight
will verify those imports without invoking registry operations. Final generator,
DLL installation and package tests remain pending. Evidence:
[`windows-79d1c1b`](../tests/cran/evidence/windows-79d1c1b/).

## Windows vignette subprocess and extracted scripts

The `459d0c5` job passed the actual Rtools registry import linkage check (all
four receipt source hashes match). R CMD build advanced from temporary package
installation to vignette rendering. The successful install's detailed output
was not retained; this is not yet independent final DLL/package acceptance.
Two executable Quarto documents then failed because their R subprocess could
not locate `relm`. This matches the upstream Windows temporary-library issue
[quarto-r#217](https://github.com/quarto-dev/quarto-r/issues/217); installing the
package a second time is avoided. The two setups now prepend the build library
recorded by R in `R_BUILD_TEMPLIB`, leaving ordinary document use unchanged.
This uses a build-tool environment variable, not a stable public relm API.

Separately, knitr's script extraction evaluated fourteen `eval` expressions
before running their setup, printing missing-variable errors and dropping those
chunks. Equivalent ordinary R `if` blocks keep the optional model branches and
illustrative/recorded branches executable in extracted scripts. A raw-source
check proves all fourteen conditions and parsed bodies unchanged; the two
synthetic document bodies are also unchanged. No models or graphics were replayed.

Three base-R library-path controls pass, including a path with spaces, absent
and unset build libraries. The actual Windows Quarto preflight builds/checks a
pure-R probe and tangles the three affected documents before any native build.
Those hosted outcomes and the complete package check remain pending. Local
Quarto is unavailable; no full rendering claim is made. The failed run and
focused controls are retained in
[`windows-459d0c5`](../tests/cran/evidence/windows-459d0c5/).

### Preflight path spelling correction

The `77feb30` Windows run stopped in the new base preflight, before Quarto or
relm compilation. The test compared `.libPaths()`'s forward slashes with the
backslashes returned by Windows `normalizePath()` by default. It now requests
`winslash = "/"` explicitly, preserving strict equality and library ordering;
observed/expected paths are retained for diagnosis. The focused local control
rejects the original spelling and passes the three current base cases using a
simulated Windows default. This does not replace actual Windows execution.
Product code and vignette sources are unchanged; actual Quarto and full package
checks remain pending. Failure and focused evidence:
[`windows-77feb30`](../tests/cran/evidence/windows-77feb30/).

### Explicit extracted-script check

On `3d9b825`, the actual Windows path controls, three-document tangling, pure-R
probe build, vignette rebuild and package check all passed (`Status: OK`, zero
warnings/errors). The rendered HTML contains the expected executed output. The
job still failed in our collector: it required a separate extracted-script check
that R normally omits when rebuilding vignette outputs. This is R's
`_R_CHECK_VIGNETTES_SKIP_RUN_MAYBE_` default, not `--no-examples` behavior.

The probe now sets that variable to `FALSE` only for its own check subprocess,
keeping both success assertions and the warning gate. A local subprocess control
verifies the value and unchanged parent environment. The retained pure-R script
also executes once on Linux without reinstalling/rendering; this does not claim
Windows script execution. No relm native build or model calls were made. Actual
Rtools ABI/registry linkage and all four source hashes still pass. Full relm
Windows checks were skipped by the failed preflight and remain pending. Original
failure and separately verified passed stages:
[`windows-3d9b825`](../tests/cran/evidence/windows-3d9b825/).

### Windows R CMD environment inheritance

The `4c950e7` run again passed the pure-R Windows build/render/check but failed
the separate-script assertion. The earlier local Unix child test did not cover
Windows argument handling: Windows `system2()` places its `env` strings before
`CMD`; the official R 4.6.1 Windows entry point ignores such `name=value`
arguments there. Its source and the original failed job are retained.

The probe helper now uses scoped `Sys.setenv()` so the child inherits the actual
process environment, restoring unset/true/false parent values on both success
and failure. Both check assertions and the full relm check remain unchanged.
The unchanged official Windows entry point, compiled on Linux with an observing
CMD stub, rejects the old argument order and verifies all six restoration cases.
An actual local R child also receives the value. This is a focused parser and
environment test, not Windows SDK or full-package acceptance. No relm native
builds, rendering or model calls were repeated. Evidence:
[`windows-4c950e7`](../tests/cran/evidence/windows-4c950e7/).

### First complete Windows installation and spill test spelling

On `a474fbc`, the real Windows preflight passed both extracted-script execution
and vignette rebuilding. The production engine/static library, wrapper generator
and final GNU R DLL link completed. Installation, package loading, compiled-code
and Rust checks, examples and vignette rebuilds passed. The retained source tar
contains 343 files; 323 tracked source files match the candidate exactly, with
DESCRIPTION build metadata treated separately. The installed 13,954,560-byte DLL
matches its built copy (SHA-256 `0492f3635bf9a46503e1f3e8711513f3bfc3f4fe13d94d4d5cf523266705aa14`).

The overall check remains failed: 4,972 expectations passed, 141 scoped skips,
and one assertion compared the same directory with forward versus backward
slashes. R CMD check reports one error, zero warnings and zero notes. All other
nine CI jobs passed. The spill test now canonicalizes both existing parent
paths before strict equality; session-file uniqueness, absent child allocation
and surviving parent contents remain required. Runtime code is unchanged.
The one affected case passes five expectations locally using the existing DLL;
all four helper bodies/formals match current source. No model or native build,
and no unrelated case was replayed. An initial reporter setup failure occurred
before the test body and is retained. Corrected Windows execution is still pending.
Raw logs, failure and source-bound scope:
[`windows-a474fbc`](../tests/cran/evidence/windows-a474fbc/).

## Remaining gates

- Source-package size, third-party licensing, compiler flags, portable CPU
  binaries, thread/resource budgets, filesystem hygiene and public R APIs.
- R-devel/current-platform checks of the final tarball, including meaningful
  CPU tests with existing tiny fixtures; no large-model downloads during checks.
- Windows CPU build/check evidence; Windows GPU/VM remains out of scope.
- Submission metadata and concrete maintainer approval of the final upload.
  No external mail, submission, release publication or auto-merge in preparation.
- WP16 follows WP15: executable/AI-readable documentation, semver/API freeze and
  the project's 30-day green CI window before v1.0. This is not a CRAN rule.

One integrated independent review covers the coherent implementation. Reuse
unchanged prior acceptance at its recorded source; do not relabel it as execution
of a new package. Keep failures and original logs. Phase 8 is complete and its
historical numerical, benchmark and quality limits remain unchanged.

## References checked on 2026-10-18

- <https://cran.r-project.org/web/packages/policies.html>
- <https://cran.r-project.org/web/packages/using_rust.html>
- <https://cran.r-project.org/web/packages/submission_checklist.html>
- <https://cran.r-project.org/doc/manuals/r-release/R-exts.html>
- <https://win-builder.r-project.org/>
