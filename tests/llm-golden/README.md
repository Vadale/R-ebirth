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
      greedy_tokens.csv     argmax token per position (teacher-forced target)
      greedy_continuation.csv autoregressive greedy decode from a fixed prompt
      metadata.json         config, input/prompt tokens, greedy tokens, hashes
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

- **The engine path.** `build_synthetic.py` writes the GGUF; `relm::llm()`
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

### Engine-vs-oracle (WP2)

The WP2 de-risking step proves the vendored engine and this numpy oracle agree
on the synthetic model, so the oracle can guard every future regression:

- **Where:** the Rust integration test
  `rebirth/src/rust/rebirth-llm/tests/synthetic_logits.rs`, run in the
  `cargo test -p rebirth-llm` CI job (rust.yaml). It builds the engine, loads the
  committed GGUF on the **CPU** backend, computes teacher-forced next-token
  logits for `INPUT_TOKENS`, and compares them to `goldens/logits.csv`.
- **Tolerance:** the engine computes in **F32**, the oracle in **float64**, so
  this is a documented cross-precision tolerance, not bit-equality. The observed
  max absolute deviation is **~2e-3**; the test asserts every logit within
  `atol = 1e-2` (≈5x headroom over the observed gap, ≈5x below the ~5e-2
  top-1/top-2 margin) **and** that the integer greedy argmax matches exactly at
  every position.
- **Result:** they agree with no oracle reconciliation needed — the numpy
  reimplementation of the llama.cpp b9726 `LLM_ARCH_LLAMA` forward pass (NORM-mode
  RoPE, op order, SwiGLU) already matched the engine on first comparison.

### Greedy generation (WP2 Step 3)

`greedy_continuation.csv` is the autoregressive greedy-decode golden: from the
fixed `GREEDY_PROMPT`, the oracle repeatedly runs forward -> argmax -> append.
The engine's greedy decode (with its KV cache) must reproduce these ids
**token-for-token** — the real cross-implementation validation, since one argmax
flip cascades into a different sequence. The prompt and length
(`synthetic_model.GREEDY_PROMPT`, `GREEDY_N_NEW`) are chosen so every step's
top-1/top-2 margin stays ≥ ~2e-2 (~10x the observed F32 gap); the `--check`
self-check re-asserts both the sequence and that margin floor. The engine side
is `rebirth/src/rust/rebirth-llm/tests/greedy_generation.rs`.

## Current coverage and deferred work (2026-09-27)

- **Synthetic oracle:** active per commit, covering logits, greedy generation,
  embeddings, activations, and interventions without a model download.
- **HF fp32 activations:** implemented in `qwen/`, with separately pinned Python
  tooling. R comparisons run with `RELM_TEST_MODEL_QWEN`, including the model
  tolerance nightly. D-018 defines the scale-robust cross-implementation checks;
  an exact HF match or a universal 0.999 per-layer correlation is not claimed.
- **Vision:** `vision/` supplies committed reference artifacts. The vision nightly
  builds an unpatched upstream encoder on its own runner for an exact same-machine
  comparison; this does not validate text-only patched logits against upstream.
- **Unpatched text-logit comparator:** still deferred in `reference/`. Do not
  describe this planned gate as active. Observation uses an eval callback; the
  vendored ablation hook means upstream equivalence is still worth checking.

See `../../docs/validation-status.md` for CI ownership and outstanding acceptance
checks. Golden regeneration remains governed by the project's golden-update workflow.
