# Owned extendr 0.9.0 lookup patch (D057)

The founder approved this bounded patch on 2026-10-23. Versions, dependency
metadata and Cargo.lock remain fixed. The 115 original source/license/metadata
files are retained; only the three Rust files listed in manifest.json change.
The patch corrects R_getVar/R_getVarEx signatures and contains lookup errors in
R_ToplevelExec before returning to the two Rust API callers. Local and inherited
lookups distinguish missing names from present NULL with a protected unique
sentinel. No engine, numerical, public relm API or upstream cache is modified.

The root .cargo/config.toml uses Cargo's restricted paths overrides for developer
commands run within this repository. Source packages use the byte-identical
patched copies in vendor.tar.xz through their existing offline source replacement.
Run tools/prepare-cran-sources.py --check to verify both copies, per-file Cargo
checksums and reverse-patch recovery of every upstream file. Package checksum
fields retain upstream registry identities; the local changed-file hashes and
explicit patch document the downstream delta. They do not label modified source
as an unchanged upstream archive. Build commands outside this repository must
use the packaged offline sources or explicitly load the project configuration.

Regeneration uses a pristine cargo vendor --locked --versioned-dirs directory;
tools/prepare-cran-sources.py applies only the pinned three-file delta and two
checksum records. Existing omission of four WASI-only binary assets is unchanged.
Acceptance includes focused native R/target-webR controls and the ordinary current
CI matrix. Successful loading does not imply browser model inference support.
