# tests/llm-golden/reference/ — real-model goldens (DEFERRED)

Placeholder for the real-model reference goldens. **Nothing is built here in
WP6a** — this README is the hook that later work packages fill in. Do not add
tooling for these until the owning WP starts; the golden venv
(`../requirements.txt`) intentionally omits `torch`/`transformers` and a second
llama.cpp build for now.

## Planned contents

- **Unpatched reference-llama.cpp logit comparator (WP2 / WP6b).** Logit goldens
  produced by an unpatched llama.cpp build at the vendored tag (`b9726`), used to
  check the *patched* engine once activation taps land (WP4). While the vendored
  engine is unpatched (WP1) it is behaviourally identical to this reference, so
  the comparator would only compare the engine against itself; the synthetic
  numpy oracle (`../synthetic/`) is the exact-value reference until the taps
  exist.
- **HF fp32 activation goldens (WP4 / WP6b).** Per-layer residual / attention /
  MLP activations from `transformers` in fp32, for the tolerance +
  rank-correlation (≥ 0.999/layer) suite on Qwen2.5-0.5B.

## Models

Real-model goldens use only the pinned, checksummed CI model
(Qwen2.5-0.5B-Instruct Q8_0). Tests never download large models; the nightly
suite is the only place a small model is fetched, and it is cached. The
exact-value, download-free path stays on the synthetic model in `../synthetic/`.
