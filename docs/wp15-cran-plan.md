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
