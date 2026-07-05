# tests/llm-golden/ — Harness B

Harness B is the project's numerical oracle: reference values that let generation
(WP2) and later activation traces (WP4) be validated numerically, not merely
"looked at". This directory holds those references (the **goldens**) and the
pinned tooling that regenerates them.

**Regeneration is governed solely by the `golden-update` skill**
(`.claude/skills/golden-update/SKILL.md`). Goldens are never hand-edited — a
golden changed without a documented, script-based reason is corruption of the
trust layer even if every test passes afterwards.

## Layout

```
tests/llm-golden/
  requirements.txt        pinned Python venv for all golden tooling (test-only)
  synthetic/              the in-repo synthetic model + its exact-value goldens
    synthetic_model.py      shared: dims, seeded F32 weights, fixed input tokens
    build_synthetic.py      writes the committed GGUF from synthetic_model
    reference_forward.py    numpy forward pass -> logit goldens + self-check
    synthetic-llama-2l.gguf the committed model (~95 KB, F32, download-free)
    goldens/
      logits.npy            authoritative logit goldens (float64, seq x vocab)
      logits.csv            human-readable mirror of logits.npy
      greedy_tokens.csv     argmax token per position (greedy-decode target)
      metadata.json         config, input tokens, greedy tokens, hashes
  reference/              hooks for the DEFERRED real-model goldens (see below)
    README.md
```

## The synthetic model (bedrock, WP6a)

`synthetic-llama-2l.gguf` is a tiny but genuinely valid `llama`-architecture
model: 2 transformer blocks, `n_embd = 32`, 4 heads, `n_ff = 64`, vocab 48, all
weights F32, deterministically seeded from a single value in `synthetic_model.py`.
It exists so exact-value tests need no download and so that **every activation is
independently recomputable in numpy** — the harness's bedrock.

Two independent producers share one seed:

- **The engine path.** `build_synthetic.py` writes the GGUF; `rebirth::llm()`
  loads it and (in WP2) will produce logits from it.
- **The oracle path.** `reference_forward.py` reimplements the llama.cpp b9726
  `LLM_ARCH_LLAMA` forward pass in pure numpy and computes the logit goldens.

Because both read the same seeded weights (the reference even asserts the
committed GGUF byte-content equals its source weights), the goldens describe the
exact bytes llama.cpp loads.

### Regenerating the synthetic goldens

From the repo root, with the pinned venv:

```sh
python3 -m venv .golden-venv
.golden-venv/bin/pip install -r tests/llm-golden/requirements.txt

# rebuild the GGUF (byte-reproducible from the seed)
.golden-venv/bin/python tests/llm-golden/synthetic/build_synthetic.py

# recompute the logit goldens
.golden-venv/bin/python tests/llm-golden/synthetic/reference_forward.py

# self-check (also run in CI): determinism + GGUF/golden agreement, no writes
.golden-venv/bin/python tests/llm-golden/synthetic/reference_forward.py --check
```

The GGUF is byte-identical across runs and platforms (numpy's `default_rng`
stream is stable), so `build_synthetic.py` reproduces the committed file exactly.

### Floating-point determinism and tolerance

- **The reference is float64** — the higher-precision mathematical truth. The
  engine computes in **F32** (the weights are F32), so the WP2 engine-vs-oracle
  comparison uses a documented tolerance, not bit-equality: cross-implementation
  float is never bit-identical (op order, SIMD/FMA, Metal-vs-CPU all differ).
- **Same machine, re-running is bit-identical.** `reference_forward.py --check`
  asserts this (two in-process recomputations must be equal).
- **Across platforms** the float64 logits agree to a few ULP (libm/BLAS), so
  `--check` compares the committed golden within a tight tolerance
  (`atol 1e-8`, `rtol 1e-6`) and additionally requires the integer **greedy
  tokens to match exactly**. The synthetic weights keep the top-1 vs top-2 logit
  margin comfortably large (~5e-2 » F32 noise), so greedy decoding is stable
  across precisions and backends.

## Deferred to WP2 / WP6b (do not build yet)

Set up as directory/README hooks only in this first slice:

- **Unpatched reference-llama.cpp logit comparator.** The vendored engine is
  unpatched at WP1 (behaviourally identical to upstream b9726), so a second,
  unpatched llama.cpp build would compare the engine against itself — it earns
  its keep only once llama.cpp is patched for activation taps (WP4). The
  synthetic numpy oracle is the exact-value reference until then.
- **HF fp32 / torch+transformers activation goldens** (WP4/WP6b) — needs `torch`
  and `transformers` in the venv, deliberately absent from `requirements.txt`.
- **Nightly Qwen2.5-0.5B tolerance + rank-correlation suite** and the
  **off-by-one mutation test** (WP6b).

See `reference/README.md`.

## Status

- **WP6a (this slice):** synthetic model + logit goldens + self-check + CI
  wiring. Done.
- **WP6b:** activation goldens, nightly 0.5B tolerance runs, mutation test.
