"""Shared definition of the synthetic 2-layer llama model (Harness B bedrock).

Single source of truth for the model's dimensions, the deterministically seeded
weights, and the fixed golden input. Both ``build_synthetic.py`` (which writes
the committed GGUF that llama.cpp loads) and ``reference_forward.py`` (which
recomputes the logit goldens in pure numpy) import from here, so the engine and
the oracle provably share the same weights.

The architecture is a minimal but faithful ``llama`` decoder as implemented by
llama.cpp b9726 (``src/models/llama.cpp``): token embedding, then per block a
pre-attention RMSNorm, multi-head self-attention with NORM-mode RoPE and causal
masking, a pre-FFN RMSNorm and a SwiGLU MLP (both sub-blocks residual), then a
final RMSNorm and the LM-head projection. All weights are F32.

Nothing here is a package dependency: this is test tooling run only in the
pinned golden venv (see ../requirements.txt). Regeneration is governed solely by
the ``golden-update`` skill.
"""

from __future__ import annotations

import os

import numpy as np

# --- model definition ------------------------------------------------------

# Deliberately tiny so the whole model is ~95 KB of F32 and every activation is
# recomputable by hand. Dimensions chosen so n_head * head_dim == n_embd (plain
# multi-head attention, no GQA) and head_dim is even (RoPE rotates full pairs).
CONFIG: dict[str, object] = {
    "arch": "llama",
    "name": "rebirth-synthetic-llama-2l",
    "n_vocab": 48,
    "n_embd": 32,
    "n_layer": 2,
    "n_head": 4,
    "n_head_kv": 4,  # == n_head: multi-head attention, no grouped-query
    "n_ff": 64,
    "n_ctx_train": 4096,
    "rope_freq_base": 10000.0,
    "rms_eps": 1.0e-5,
    "seed": 20260705,
}

# The fixed token sequence the logit goldens are computed for. Token ids only
# (the synthetic model carries no real tokenizer); every id is < n_vocab. WP2
# feeds exactly this sequence to llm_logits() and compares against the goldens.
INPUT_TOKENS: list[int] = [1, 7, 13, 22, 5, 31, 44, 2]

# The fixed prompt and length for the autoregressive greedy-continuation golden
# (WP2 Step 3): forward -> argmax -> append -> repeat. This is the real
# cross-implementation check that the engine's greedy decode reproduces an
# independent numpy generation token-for-token. The prompt/length are chosen so
# every step's top-1 vs top-2 logit margin stays >= ~2e-2 (~10x the observed F32
# engine-vs-oracle deviation), keeping the argmax precision-stable and the golden
# non-flaky across backends. Token ids only (no_vocab model).
GREEDY_PROMPT: list[int] = [1, 7]
GREEDY_N_NEW: int = 16

GGUF_FILENAME = "synthetic-llama-2l.gguf"

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.normpath(os.path.join(_HERE, "..", "..", ".."))


def canonical_gguf_path() -> str:
    """The committed GGUF next to this module (the oracle's source of truth)."""
    return os.path.join(_HERE, GGUF_FILENAME)


def package_fixture_path() -> str:
    """The byte-identical copy shipped in the R package so the testthat load
    test can reach the model inside the R CMD check tarball (the repo-root copy
    is outside the package). Kept in sync by build_synthetic.py; the byte
    identity of the two is enforced by reference_forward.py --check.
    """
    return os.path.join(
        _REPO_ROOT, "rebirth", "tests", "testthat", "fixtures", GGUF_FILENAME
    )


def head_dim() -> int:
    return int(CONFIG["n_embd"]) // int(CONFIG["n_head"])  # type: ignore[operator]


# --- deterministic weights -------------------------------------------------

# Every weight matrix is stored in canonical (out_features, in_features) layout,
# which is what gguf.GGUFWriter.add_tensor expects and what llama.cpp reads back
# as ggml ne = {in, out} (verified against load_arch_tensors at b9726). Weights
# are drawn in the fixed order below from a single PCG64 stream, so the byte
# content of the GGUF is fully determined by CONFIG["seed"]. numpy guarantees
# the Generator bit stream across platforms and versions, so the seed -> weights
# map is reproducible everywhere.


def _linear(rng: np.random.Generator, out_features: int, in_features: int) -> np.ndarray:
    # Fan-in scaling keeps activations O(1) through the residual stack so the
    # forward pass neither saturates SiLU/softmax nor underflows.
    scale = 1.0 / np.sqrt(in_features)
    return (rng.standard_normal((out_features, in_features)) * scale).astype(np.float32)


def _norm(rng: np.random.Generator, n: int) -> np.ndarray:
    # RMSNorm gains centred on 1.0, as in a trained model.
    return (1.0 + 0.05 * rng.standard_normal(n)).astype(np.float32)


def build_weights() -> dict[str, np.ndarray]:
    """Return every model tensor as an F32 numpy array, keyed by GGUF name."""
    n_vocab = int(CONFIG["n_vocab"])  # type: ignore[arg-type]
    n_embd = int(CONFIG["n_embd"])  # type: ignore[arg-type]
    n_layer = int(CONFIG["n_layer"])  # type: ignore[arg-type]
    n_head = int(CONFIG["n_head"])  # type: ignore[arg-type]
    n_head_kv = int(CONFIG["n_head_kv"])  # type: ignore[arg-type]
    n_ff = int(CONFIG["n_ff"])  # type: ignore[arg-type]
    hd = head_dim()

    rng = np.random.default_rng(int(CONFIG["seed"]))  # type: ignore[arg-type]
    w: dict[str, np.ndarray] = {}

    # Draw order is load-bearing: it fixes the RNG stream. Do not reorder.
    w["token_embd.weight"] = (rng.standard_normal((n_vocab, n_embd)) * 0.1).astype(np.float32)
    for i in range(n_layer):
        w[f"blk.{i}.attn_norm.weight"] = _norm(rng, n_embd)
        w[f"blk.{i}.attn_q.weight"] = _linear(rng, n_head * hd, n_embd)
        w[f"blk.{i}.attn_k.weight"] = _linear(rng, n_head_kv * hd, n_embd)
        w[f"blk.{i}.attn_v.weight"] = _linear(rng, n_head_kv * hd, n_embd)
        w[f"blk.{i}.attn_output.weight"] = _linear(rng, n_embd, n_head * hd)
        w[f"blk.{i}.ffn_norm.weight"] = _norm(rng, n_embd)
        w[f"blk.{i}.ffn_gate.weight"] = _linear(rng, n_ff, n_embd)
        w[f"blk.{i}.ffn_up.weight"] = _linear(rng, n_ff, n_embd)
        w[f"blk.{i}.ffn_down.weight"] = _linear(rng, n_embd, n_ff)
    w["output_norm.weight"] = _norm(rng, n_embd)
    w["output.weight"] = _linear(rng, n_vocab, n_embd)

    return w
