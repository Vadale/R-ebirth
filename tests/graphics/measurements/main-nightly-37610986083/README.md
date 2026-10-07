# Separately observed main nightly failure

Source main `0d1f08799dab9b7ac505ccd227a860bfd68f620e`, before F6c implementation.
Run https://github.com/Vadale/R-ebirth/actions/runs/37610986083 failed in the
model-suite step: lifecycle children could not load an installed relm package.
The workflow calls pkgload::load_all in the parent without first making a
matching installed package available to those fresh child processes. This is
not the prior Rust cache-download failure or evidence of a general GitHub outage.
Later workflow stages were skipped. The full available failed-step log is kept.

Both ordinary post-merge workflows passed (R37610671898/Rust37610671947).
No workflow correction or retry is included in F6c; this harness prerequisite
remains a separate maintenance item. Do not call this nightly green or silently
reuse older model acceptance as execution of this run.
