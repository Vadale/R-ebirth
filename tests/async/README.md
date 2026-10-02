# WP9 asynchronous generation verification

Portable regressions are in `rebirth/tests/testthat/test-llm-async*.R`,
`rebirth/src/rust/rebirth-llm/src/{domain,async_job}.rs` and
`rebirth/src/rust/rebirth-llm/tests/async_synthetic.rs`. Native VLM checkpoint
cases live beside the generation code and require the existing cached model/
projector or the vision nightly. No model download is required in ordinary PR CI.

`measurements/macos-arm64-2026-10-01` preserves the local execution history,
including failed attempts and corrected results. Raw logs/session output are
losslessly compressed; `raw-log-index.json` records their original byte hashes. `summary.json` reports actual
scope; `source-manifest.json` is a post-run snapshot, with its archive comparison
explained explicitly. `SHA256SUMS` binds the files in that directory. Recorded
verification scripts contain local paths and are provenance, not an instruction
to repeat completed builds. Foreground RStudio and final PR CI were still pending
when these receipts were collected.

See `docs/wp9-implementation.md` for acceptance status and limitations. The
transport-memory estimate is not a process RSS cap; a real VLM cancellation
checkpoint is not interruption inside an executing native encoder call.
