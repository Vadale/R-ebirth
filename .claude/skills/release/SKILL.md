---
name: release
description: Cut an R-ebirth release (r-universe tag; CRAN from Phase 9). Use at every phase end and for patch releases. Ensures the version that ships is the version that was tested.
---

# Cutting a release

1. **Preconditions (all mandatory):** current phase's WP acceptance lists fully green; CI green on the full matrix (macOS arm64, Linux; + Windows from Phase 8); no `status: proposed` entries in `DECISIONS.md` touching shipped behavior; `simplifier` agent has run on the phase (per `CLAUDE.md` cadence).
2. **Version:** bump `DESCRIPTION` (semver: breaking = major once past 1.0; feature = minor; fix = patch). Pre-1.0, minor bumps per phase.
3. **NEWS.md:** every user-visible change since the last tag, user language, grouped (new features / fixes / breaking). The doc-writer agent owns the wording.
4. **Docs pass:** `devtools::document()`; `devtools::run_examples()` — every example executes; pkgdown builds clean; README quickstart re-tested against the *built* package, not the dev tree.
5. **Final checks on a clean R session:** `R CMD build` then `R CMD check --as-cran` on the tarball (not the source dir). Zero errors, zero warnings; notes explained in the release notes.
6. **Founder smoke test:** install the built tarball on the Mac mini, run both demos from RStudio with pinned seeds — outputs must match the recorded expected results.
7. **Tag:** `git tag -a v<X.Y.Z>` with a message summarizing the phase delivered; push tag. Verify r-universe picks it up and serves binaries (install from a clean machine/VM: `install.packages("rebirth", repos = <r-universe>)`).
8. **CRAN (Phase 9 onward):** follow the CRAN Rust vendoring policy checklist in `ARCHITECTURE.md`; submit; record submission + outcome in `DECISIONS.md`.
9. **Post-release:** update `CLAUDE.md` status line (current phase, released version); open the next phase only after the release is verified installable.
