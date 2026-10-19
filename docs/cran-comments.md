# Submission comments — relm 0.5.0 draft

**Not sent; not upload-ready.** Fill the final-candidate fields after its ordinary
CI matrix and artifact inspection. See [the admission questions](cran-submission.md).

## First submission

relm is an existing local-model R package, previously distributed through
r-universe. It exposes ordinary R objects and bundles patched llama.cpp and
81 locked Rust crates, with installed authorship/license notices. Installation
does not download models, dependencies or a toolchain. CUDA is opt-in and disabled
in ordinary CPU source-package checks. Compilation explicitly uses two Cargo jobs.

## Compiler requirements disclosed for CRAN's consideration

Cargo and rustc >= 1.85.0 are independently required and checked. The locked
Arrow 59 sources use Rust 2024 edition. Rust/Cargo 1.85 was released 2025-02-20,
so the candidate does not meet the two-year Cargo-age guidance on 2026-10-19.
No exception has been granted. CMake >= 3.28 is required. The wrapper follow-up
generates wrappers inside the installing R after DLL linking, replacing the
standalone executable; real non-shared R installation is a pending CI gate.
The founder chose direct form submission after the technical checks, with these
requirements disclosed for CRAN's consideration. No preliminary email will be
sent, and passing hosted CI does not establish farm availability or an exception.

## Exact candidate and checks — pending

- Final Git commit and source tar SHA256: pending new CI artifact inspection.
- R-devel `--as-cran`, incoming checks, HTML Tidy and PDF manual: pending.
- Windows CPU and macOS/Linux release/oldrel: pending for this candidate.
- Actual errors, warnings, notes and scoped skips: pending; never copy old counts
  into this section as if they came from the final tar.
- Source/installed size and notices: pending final artifact inspection. Parent
  PR71 source was <=8.36 MB; installed Linux size was126.4 MB including113.26 MB
  of retained debug sections. No stripping is proposed.

The 2026-10-19 current and archived CRAN indexes contained no relm name entry;
the current index contained no reverse-dependency mention. This does not reserve
the name. GitHub/issues/r-universe URL checks returned HTTP200 on that date.

Tests use committed tiny fixtures. Optional external models and production-omitted
test hooks are explicitly skipped; those skips do not validate the capabilities.
Historical numerical/quality limitations and Windows GPU/live-cleanup boundaries
remain documented. No broad quality or platform-equivalence claim is made.

The founder authorized agent merge once every current check passes and form
submission after exact-archive validation. Nothing has been uploaded; no separate
release publication is authorized. Maintainer email confirmation may require
the founder's action.
