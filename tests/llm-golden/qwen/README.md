# tests/llm-golden/qwen/ — real-model activation golden (WP6b)

The tolerance-level half of Harness B: an **independent PyTorch/`transformers`
fp32 reference** for `llm_trace`'s activation taps on a real model
(Qwen2.5-0.5B-Instruct, the CI-integration pin). Where `../synthetic/` proves the
engine exact against a numpy oracle on a tiny in-repo model, this proves the same
taps against a *different implementation of a real transformer*, at a documented
tolerance (Q8_0 GGUF vs fp32 HF differ by quantization + kernel/op order).

**Regeneration is governed solely by the `golden-update` skill.** Goldens are
never hand-edited.

## Layout

```
tests/llm-golden/qwen/
  reference_forward_hf.py   fp32 CPU forward + hooks -> the golden + self-check
  requirements-hf.txt       pinned torch/transformers venv (TEST TOOLING ONLY)
  goldens/
    activations.f32         raw little-endian float32 blob (C-order), authoritative
    manifest.json           provenance: model SHA, prompts+ids, shape, versions, SHA256
```

`activations.f32` holds shape `[n_layers, n_components, n_prompts, n_embd]`
(component axis = `("residual", "mlp_out")`), C-order, neuron fastest. Each prompt
contributes one row — its **last** token's activation (`positions = "last"`), which
keeps the golden small enough to duplicate into the package fixtures for R CMD
check, gives full 24-layer coverage, and is what generation/logits consume;
cross-position numerics are already checked exactly on the synthetic model. The R
comparison test reads it with base `readBin` (no numpy on the R side) and pins its
SHA256; Python reads it back with `np.frombuffer`. There is no CSV mirror — a
real-model golden as CSV would be absurd; `manifest.json` is the human-readable index.

## Tap semantics (the crux — matched to `rebirth-llm/src/trace.rs`, D-014/D-016)

Captured from forward hooks, NOT `output_hidden_states`:

- **`residual`** = each `Qwen2DecoderLayer` output = the engine's `l_out-<il>`
  (post both residual adds). `output_hidden_states` is deliberately NOT used: its
  last entry is the post-**final-norm** state (`norm(block[L-1])`), not the last
  block's `l_out` — using it would silently substitute a normed tensor for the
  last layer. The per-block hook is correct for every layer.
- **`mlp_out`** = each layer's `mlp` output = the engine's `ffn_out-<il>` (pre
  residual add).
- **`attn_out`** = each layer's `self_attn.o_proj` output (post-projection, D-014).
  **Captured and validated (residual identity) but NOT committed / NOT compared:**
  `llm_trace` does not observe `attn_out` on qwen2 (it names only the
  pre-projection `kqv_out`, a different quantity) and raises `rebirth_error_trace`
  — covered by an existing [MODEL] test in `test-llm-trace.R`.

A residual-identity self-check ties the three together:
`residual[il] == residual[il-1] + attn_out[il] + mlp_out[il]`
(with `residual[-1] = embed_tokens`), observed max |Δ| = 0.

## Alignment (audit L-7, BOS off-by-one)

Qwen2 has no BOS token, so `llm_trace` (`add_special=true`), `llm_tokens`
(`add_special=false`) and this reference agree on the id sequence. The manifest
pins each prompt's 0-based ids/pieces; the R test asserts
`llm_tokens(m, prompt) - 1` equals them and that the trace's last `token_pos`
equals `n_tokens` — a future tokenizer/BOS divergence (an extra leading token)
fails at that guard before any activation is compared.

## Where the comparison runs

`rebirth/tests/testthat/test-llm-trace-golden.R`. The golden-integrity checks
run in per-commit CI (no model). The numerical comparison is **[MODEL]-gated on
`REBIRTH_TEST_MODEL_QWEN`** (a local Qwen2.5-0.5B GGUF) — it runs on the founder's
Mac / nightly, never in per-commit CI, and never downloads a model.

## Regenerating

```sh
python3 -m venv .hf-golden-venv
.hf-golden-venv/bin/pip install -r tests/llm-golden/qwen/requirements-hf.txt
.hf-golden-venv/bin/python tests/llm-golden/qwen/reference_forward_hf.py
.hf-golden-venv/bin/python tests/llm-golden/qwen/reference_forward_hf.py --check
```

Regenerating changes the committed SHA256 (pinned in the R test and the manifest)
and is a documented golden-update event, not a silent refresh.
