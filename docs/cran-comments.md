# Submission comments — relm 0.6.2 draft

**Not submitted. Final artifact and check results pending.** This is an update
to CRAN 0.5.0 in response to the October 30 notice, deadline November 20.

## Reported installation failures

- Fedora Clang: add the direct standard `<cerrno>` include required by the
  existing GGUF file-open error diagnostic. The pinned engine is unchanged.
- GCC-ASAN: retain the R-compiled state archive separately from Rust's staticlib,
  linking it explicitly in the final R shared library. This preserves the GNU
  slim-LTO symbol index and the C-to-Rust finalizer callback. Compiler,
  sanitizer and LTO flags are unchanged; no check is disabled.

## Changes since CRAN 0.5.0

The update also includes the already released 0.6.0/0.6.1 changes described in
NEWS: explicit thread selection, modern chat-template compatibility, and owned
extendr binding/portability corrections. Dependencies, engine version, numerical
bounds and public API compatibility are retained. Optional Python reference
tooling is not an R package runtime dependency.

## Candidate evidence to complete before submission

- Exact commit and built source archive SHA256: pending.
- GCC slim-LTO plus ASAN/UBSAN/bounds-strict installation: pending final package.
- Clang compilation and ordinary Windows/macOS/Linux, R release/oldrel/devel,
  actual non-shared-R installation, source bundles and PDF manual: pending CI.
- Errors, warnings, notes, scoped model/selftest skips and reverse dependencies:
  record from the final candidate; do not substitute historical results.

No new model evaluation is claimed. The exact CRAN Fedora toolchain and its
instrumented R host are not identical to the local diagnostic environment.
