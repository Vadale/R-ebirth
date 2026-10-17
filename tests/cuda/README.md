# CUDA verification and retained evidence

- `configuration.R`: nine model-free opt-in/default-off/platform/SDK/link checks;
  runs in the ordinary R CI jobs, without CUDA tools or a GPU.
- `device-smoke.cu`: standalone real allocation/kernel/readback check. This requires
  the separately prepared toolkit/GPU and is not an ordinary CI dependency.
- CUDA-feature native gates live in `rebirth-llm/tests/cuda_backend.rs`, the six
  synthetic numeric/resource binaries and the `cuda_projection_` unit tests.
  They require an actual GPU and fail if unavailable; ordinary CI retains CPU
  numeric gates. Never relabel CPU execution as CUDA acceptance.
- `evidence/2026-10-17/manifest.json`:339 preserved files / 20,487,391 bytes. Native,
  installed and performance sources/results include original failures and separate
  owner receipts. Absolute paths in frozen scripts/manifests identify the original
  host; copying a receipt does not execute it. Compiled artifacts and host crash
  journals stay local, with hashes in `local-artifacts.json`.
- `render-performance.R`: redraws only the retained timing CSV, no model or RNG.

Run `Rscript tests/cuda/configuration.R` from the repository root for build-routing
checks. The [installation guide](../../docs/linux-cuda.md) documents SDK/compiler
and architecture settings. Hardware tests are an explicitly selected local gate;
no manual replay of previously accepted CPU/Metal or consumed research holdouts
is needed. The final ordinary PR matrix checks compatibility independently.

The frozen final benchmark script is intentionally retained with its original
logger-order defect. Native logs from those three processes are empty and cannot
be reconstructed. Separate zero-inference CPU/CUDA load receipts and the valid
installed/profile logs are explicitly distinguished. Any future new experiment
must initialize the product backend before installing the test logger, as in
`performance-placement-preparation/placement.R`; do not overwrite/replay the old
experiment or portray the load-only receipts as its original native logs.

See the [result report](../../docs/wp13-linux-cuda-implementation.md) for exact
counts, bounds, rejected candidate, timing interpretation and numerical limits.
