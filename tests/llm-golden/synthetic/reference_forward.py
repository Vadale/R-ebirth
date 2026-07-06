#!/usr/bin/env python3
"""Numpy reference forward pass for the synthetic llama model -> logit goldens.

This is Harness B's exact-value oracle. It reimplements, in pure numpy, the
llama.cpp b9726 ``LLM_ARCH_LLAMA`` forward pass (``src/models/llama.cpp`` and
the ggml CPU kernels it calls) and computes the logits for the fixed
``INPUT_TOKENS`` sequence. WP2's ``llm_logits`` / greedy decoding are checked
against these goldens; here we only build the oracle and prove it reproducible.

Forward pass (all per-token, positions 0..S-1), matching the engine:

  x = token_embd[token]
  for each block:
      h        = rmsnorm(x, attn_norm) * w
      q,k,v    = h @ Wq^T, h @ Wk^T, h @ Wv^T           (reshaped into heads)
      q,k      = rope_norm(q,k)                          (NORM mode, full head)
      a        = softmax(q·kᵀ / sqrt(head_dim) + causal_mask) @ v
      x        = x + (concat_heads(a) @ Wo^T)            (residual)
      f        = (silu(h2 @ Wgate^T) * (h2 @ Wup^T)) @ Wdown^T,  h2 = rmsnorm(x, ffn_norm)
      x        = x + f                                   (residual)
  x = rmsnorm(x, output_norm)
  logits = x @ output^T

Precision. The engine computes in F32 (the weights are F32). This reference
computes in float64 to serve as the higher-precision mathematical truth; WP2's
engine-vs-oracle comparison therefore uses a documented tolerance rather than
bit-equality (cross-implementation float is never bit-identical). See README.

Determinism. The weights come from the committed GGUF's single seed and the
computation is pure numpy, so re-running yields identical values on a given
machine (the ``--check`` self-check asserts this). Across platforms the float64
values agree to a few ULP (libm/BLAS differences) and the greedy tokens are
identical; ``--check`` enforces a tight tolerance plus exact greedy-token match.

Usage (from the pinned golden venv, see ../requirements.txt):

    python reference_forward.py            # (re)generate the goldens in goldens/
    python reference_forward.py --check    # verify committed goldens, no writes

Regeneration is governed solely by the ``golden-update`` skill.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

from synthetic_model import (
    CONFIG,
    GGUF_FILENAME,
    GREEDY_N_NEW,
    GREEDY_PROMPT,
    INPUT_TOKENS,
    build_weights,
    canonical_gguf_path,
    head_dim,
    package_fixture_path,
)

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN_DIR = os.path.join(HERE, "goldens")
LOGITS_NPY = os.path.join(GOLDEN_DIR, "logits.npy")
LOGITS_CSV = os.path.join(GOLDEN_DIR, "logits.csv")
EMBEDDINGS_NPY = os.path.join(GOLDEN_DIR, "embeddings.npy")
EMBEDDINGS_CSV = os.path.join(GOLDEN_DIR, "embeddings.csv")
GREEDY_CSV = os.path.join(GOLDEN_DIR, "greedy_tokens.csv")
GREEDY_CONT_CSV = os.path.join(GOLDEN_DIR, "greedy_continuation.csv")
META_JSON = os.path.join(GOLDEN_DIR, "metadata.json")

# Cross-platform tolerance for the committed-golden comparison in --check. Real
# regressions move logits by >> 1e-3; float64 libm/BLAS differences across
# platforms are ~1e-12 on O(1) logits, so this band separates the two cleanly.
CHECK_ATOL = 1e-8
CHECK_RTOL = 1e-6


# --- kernels (numpy, float64) ----------------------------------------------


def rmsnorm(x: np.ndarray, weight: np.ndarray, eps: float) -> np.ndarray:
    # ggml_rms_norm: x / sqrt(mean(x^2) + eps), then multiplied by the gain.
    ms = np.mean(x * x, axis=-1, keepdims=True)
    return x / np.sqrt(ms + eps) * weight


def silu(x: np.ndarray) -> np.ndarray:
    return x / (1.0 + np.exp(-x))


def rope_norm(x: np.ndarray, positions: np.ndarray, n_rot: int, freq_base: float) -> np.ndarray:
    """NORM-mode RoPE, matching ggml rotate_pairs(scale=1) + rope_cache_init.

    x: (seq, n_head, head_dim). Rotates adjacent pairs (2k, 2k+1) of each head
    by theta = pos * freq_base**(-2k/n_rot) for k in 0..n_rot/2. With
    n_rot == head_dim the whole head is rotated.
    """
    out = x.copy()
    for k in range(n_rot // 2):
        theta = positions * (freq_base ** (-2.0 * k / n_rot))  # (seq,)
        cos = np.cos(theta)[:, None]  # (seq, 1) -> broadcast over heads
        sin = np.sin(theta)[:, None]
        a = x[:, :, 2 * k]
        b = x[:, :, 2 * k + 1]
        out[:, :, 2 * k] = a * cos - b * sin
        out[:, :, 2 * k + 1] = a * sin + b * cos
    return out


def softmax_lastdim(x: np.ndarray) -> np.ndarray:
    m = np.max(x, axis=-1, keepdims=True)
    e = np.exp(x - m)
    return e / np.sum(e, axis=-1, keepdims=True)


# --- forward pass ----------------------------------------------------------


def hidden_states(weights: dict[str, np.ndarray], tokens: list[int]) -> np.ndarray:
    """Return the post-final-norm hidden states, shape (seq_len, n_embd), float64.

    This is the value of ``x`` immediately AFTER the final ``output_norm`` RMSNorm
    and BEFORE the LM-head matmul -- llama.cpp's ``result_norm`` tensor, i.e.
    exactly what ``llama_get_embeddings_ith`` returns for a NONE-pooling context
    (ADR D-011, ``docs/wp3-embed-plan.md`` s7.1). ``forward`` composes the logits
    from it, so extracting it here is a pure refactor: the numeric ops and their
    order are unchanged, so the logit goldens do not drift (``--check`` enforces
    this).
    """
    n_embd = int(CONFIG["n_embd"])  # type: ignore[arg-type]
    n_layer = int(CONFIG["n_layer"])  # type: ignore[arg-type]
    n_head = int(CONFIG["n_head"])  # type: ignore[arg-type]
    n_head_kv = int(CONFIG["n_head_kv"])  # type: ignore[arg-type]
    hd = head_dim()
    eps = float(CONFIG["rms_eps"])  # type: ignore[arg-type]
    freq_base = float(CONFIG["rope_freq_base"])  # type: ignore[arg-type]
    kq_scale = 1.0 / np.sqrt(hd)

    seq = len(tokens)
    positions = np.arange(seq, dtype=np.float64)
    # Causal mask: key j visible to query i iff j <= i.
    causal = np.where(np.tril(np.ones((seq, seq))) == 1.0, 0.0, -np.inf)

    def w(name: str) -> np.ndarray:
        return weights[name].astype(np.float64)

    x = w("token_embd.weight")[np.asarray(tokens, dtype=np.int64)]  # (seq, n_embd)

    for il in range(n_layer):
        # --- attention sub-block ---
        h = rmsnorm(x, w(f"blk.{il}.attn_norm.weight"), eps)
        q = h @ w(f"blk.{il}.attn_q.weight").T  # (seq, n_head*hd)
        k = h @ w(f"blk.{il}.attn_k.weight").T  # (seq, n_head_kv*hd)
        v = h @ w(f"blk.{il}.attn_v.weight").T  # (seq, n_head_kv*hd)

        q = q.reshape(seq, n_head, hd)
        k = k.reshape(seq, n_head_kv, hd)
        v = v.reshape(seq, n_head_kv, hd)

        q = rope_norm(q, positions, hd, freq_base)
        k = rope_norm(k, positions, hd, freq_base)

        attn_out = np.empty((seq, n_head, hd), dtype=np.float64)
        for head in range(n_head):
            kvh = head  # n_head_kv == n_head (no GQA); identity mapping
            qh = q[:, head, :]  # (seq, hd)
            kh = k[:, kvh, :]  # (seq, hd)
            vh = v[:, kvh, :]  # (seq, hd)
            scores = (qh @ kh.T) * kq_scale + causal  # (seq_q, seq_k)
            attn_out[:, head, :] = softmax_lastdim(scores) @ vh

        attn_flat = attn_out.reshape(seq, n_head * hd)
        x = x + attn_flat @ w(f"blk.{il}.attn_output.weight").T  # residual

        # --- feed-forward sub-block (SwiGLU) ---
        h2 = rmsnorm(x, w(f"blk.{il}.ffn_norm.weight"), eps)
        gate = silu(h2 @ w(f"blk.{il}.ffn_gate.weight").T)
        up = h2 @ w(f"blk.{il}.ffn_up.weight").T
        ff = (gate * up) @ w(f"blk.{il}.ffn_down.weight").T
        x = x + ff  # residual

    x = rmsnorm(x, w("output_norm.weight"), eps)
    return x  # (seq, n_embd) post-final-norm hidden states ("result_norm")


def forward(weights: dict[str, np.ndarray], tokens: list[int]) -> np.ndarray:
    """Return logits of shape (seq_len, n_vocab), float64.

    Composed from the post-final-norm hidden states so both goldens derive from
    one forward pass: ``logits = hidden_states(...) @ output.T``. This matmul is
    byte-identical to the previously inlined ``x @ w("output.weight").T`` (same
    float64 operands, same order), so ``logits.npy`` must not drift.
    """
    x = hidden_states(weights, tokens)
    return x @ weights["output.weight"].astype(np.float64).T  # (seq, n_vocab)


# --- goldens ---------------------------------------------------------------


def compute_logits() -> np.ndarray:
    return forward(build_weights(), INPUT_TOKENS)


def compute_hidden_states() -> np.ndarray:
    """Post-final-norm hidden states for INPUT_TOKENS (the embeddings golden)."""
    return hidden_states(build_weights(), INPUT_TOKENS)


def greedy_tokens(logits: np.ndarray) -> np.ndarray:
    return np.argmax(logits, axis=-1).astype(np.int64)


def greedy_continuation(
    weights: dict[str, np.ndarray],
    prompt: list[int],
    n_new: int,
) -> tuple[list[int], float]:
    """Autoregressive greedy decode: forward -> argmax -> append -> repeat.

    Returns the `n_new` generated token ids (excluding the prompt) and the
    minimum top-1/top-2 logit margin observed across the generation steps (the
    precision-stability guard). Recomputes the full sequence each step, which is
    mathematically identical to a KV-cached incremental decode under causal
    attention, so the engine (which does cache) must reproduce these ids exactly.
    """
    tokens = list(prompt)
    margins: list[float] = []
    for _ in range(n_new):
        last = forward(weights, tokens)[-1]
        srt = np.sort(last)
        margins.append(float(srt[-1] - srt[-2]))
        tokens.append(int(np.argmax(last)))
    return tokens[len(prompt):], (min(margins) if margins else float("inf"))


def top2_margins(logits: np.ndarray) -> np.ndarray:
    srt = np.sort(logits, axis=-1)
    return srt[:, -1] - srt[:, -2]


def gguf_weights_match_source() -> bool:
    """Assert the committed GGUF holds exactly the weights the oracle uses."""
    import gguf  # local import: only needed for this consistency check

    path = canonical_gguf_path()
    reader = gguf.GGUFReader(path)
    on_disk = {t.name: np.array(t.data) for t in reader.tensors}
    source = build_weights()
    if set(on_disk) != set(source):
        raise AssertionError(
            "GGUF tensor set differs from build_weights():"
            f" only in GGUF={set(on_disk) - set(source)},"
            f" only in source={set(source) - set(on_disk)}"
        )
    for name, arr in source.items():
        disk = on_disk[name].reshape(arr.shape)
        if not np.array_equal(disk.astype(np.float32), arr):
            raise AssertionError(f"GGUF tensor '{name}' differs from build_weights()")
    return True


def write_goldens() -> None:
    os.makedirs(GOLDEN_DIR, exist_ok=True)
    logits = compute_logits()
    greedy = greedy_tokens(logits)

    np.save(LOGITS_NPY, logits)

    # Human-readable mirror of the authoritative .npy (full float64 precision).
    with open(LOGITS_CSV, "w") as fh:
        fh.write("position," + ",".join(f"logit_{j}" for j in range(logits.shape[1])) + "\n")
        for i, row in enumerate(logits):
            fh.write(str(i) + "," + ",".join(f"{v:.17g}" for v in row) + "\n")

    # Embeddings golden (WP3): the per-token post-final-norm hidden states -- the
    # exact tensor llama_get_embeddings_ith returns under NONE pooling (D-011).
    # Same .npy + .csv format/precision convention as the logits golden above.
    emb = compute_hidden_states()
    np.save(EMBEDDINGS_NPY, emb)
    with open(EMBEDDINGS_CSV, "w") as fh:
        fh.write("position," + ",".join(f"embd_{j}" for j in range(emb.shape[1])) + "\n")
        for i, row in enumerate(emb):
            fh.write(str(i) + "," + ",".join(f"{v:.17g}" for v in row) + "\n")

    with open(GREEDY_CSV, "w") as fh:
        fh.write("position,token,input_token\n")
        for i, (tok, inp) in enumerate(zip(greedy, INPUT_TOKENS)):
            fh.write(f"{i},{int(tok)},{inp}\n")

    cont, cont_margin = greedy_continuation(build_weights(), GREEDY_PROMPT, GREEDY_N_NEW)
    with open(GREEDY_CONT_CSV, "w") as fh:
        fh.write("step,token\n")
        for i, tok in enumerate(cont):
            fh.write(f"{i},{int(tok)}\n")

    # Pooled embedding goldens for the llm_embed() pooling modes, reduced over
    # the per-token rows: mean = elementwise average of all rows, last = the
    # final token (row 7). Normalized variants are L2 unit vectors (v/||v||),
    # what normalize = TRUE returns; these pin the Rust reduction + L2 path.
    mean_pool = emb.mean(axis=0)
    last_pool = emb[-1]
    mean_pool_normalized = mean_pool / np.linalg.norm(mean_pool)
    last_pool_normalized = last_pool / np.linalg.norm(last_pool)

    meta = {
        "model": str(CONFIG["name"]),
        "arch": str(CONFIG["arch"]),
        "gguf": GGUF_FILENAME,
        "config": CONFIG,
        "input_tokens": INPUT_TOKENS,
        "seq_len": int(logits.shape[0]),
        "n_vocab": int(logits.shape[1]),
        "compute_dtype": "float64",
        "greedy_tokens": [int(t) for t in greedy],
        "min_top2_margin": float(np.min(top2_margins(logits))),
        "greedy_prompt": GREEDY_PROMPT,
        "greedy_continuation": [int(t) for t in cont],
        "greedy_continuation_min_margin": cont_margin,
        "logits_sha256": _sha256_array(logits),
        "embeddings_sha256": _sha256_array(emb),
        "mean_pool": mean_pool.tolist(),
        "last_pool": last_pool.tolist(),
        "mean_pool_normalized": mean_pool_normalized.tolist(),
        "last_pool_normalized": last_pool_normalized.tolist(),
        "numpy_version": np.__version__,
    }
    with open(META_JSON, "w") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")

    print(f"wrote goldens for {logits.shape[0]} positions x {logits.shape[1]} vocab")
    print(f"  embeddings    : {emb.shape[0]} x {emb.shape[1]} (sha256 {_sha256_array(emb)[:16]})")
    print(f"  greedy tokens : {[int(t) for t in greedy]}")
    print(f"  min top-2 gap : {np.min(top2_margins(logits)):.4g}")
    print(f"  greedy cont.  : {cont} (min step margin {cont_margin:.4g})")


def _sha256_array(arr: np.ndarray) -> str:
    import hashlib

    return hashlib.sha256(np.ascontiguousarray(arr, dtype=np.float64).tobytes()).hexdigest()


def _files_equal(a: str, b: str) -> bool:
    if not (os.path.exists(a) and os.path.exists(b)):
        return False
    with open(a, "rb") as fa, open(b, "rb") as fb:
        return fa.read() == fb.read()


def check_goldens() -> int:
    # 1) Same-machine determinism: two independent recomputations are identical.
    a = compute_logits()
    b = compute_logits()
    if not np.array_equal(a, b):
        print("FAIL: forward pass is not deterministic (two runs differ)", file=sys.stderr)
        return 1

    # 1b) Same-machine determinism for the post-final-norm hidden states (the
    #     embeddings golden), matching the logits determinism guard above.
    ha = compute_hidden_states()
    hb = compute_hidden_states()
    if not np.array_equal(ha, hb):
        print("FAIL: hidden_states is not deterministic (two runs differ)", file=sys.stderr)
        return 1

    # 2) The committed GGUF holds exactly the oracle's weights.
    gguf_weights_match_source()

    # 2b) The R package test fixture is byte-identical to the canonical GGUF
    #     (drift guard: both must be regenerated together by build_synthetic.py).
    if not _files_equal(canonical_gguf_path(), package_fixture_path()):
        print(
            "FAIL: package fixture differs from canonical GGUF; "
            "re-run build_synthetic.py",
            file=sys.stderr,
        )
        return 1

    # 3) Committed goldens still describe this forward pass.
    if not os.path.exists(LOGITS_NPY):
        print(f"FAIL: committed golden missing: {LOGITS_NPY}", file=sys.stderr)
        return 1
    committed = np.load(LOGITS_NPY)
    if committed.shape != a.shape:
        print(f"FAIL: golden shape {committed.shape} != recomputed {a.shape}", file=sys.stderr)
        return 1
    if not np.allclose(committed, a, atol=CHECK_ATOL, rtol=CHECK_RTOL):
        max_abs = float(np.max(np.abs(committed - a)))
        print(f"FAIL: logits drifted from committed golden (max abs {max_abs:.3e})", file=sys.stderr)
        return 1
    if not np.array_equal(greedy_tokens(committed), greedy_tokens(a)):
        print("FAIL: greedy tokens differ from committed golden", file=sys.stderr)
        return 1

    # 3b) The committed embeddings golden round-trips: it loads and still matches
    #     the recomputed post-final-norm hidden states (same tolerance as logits).
    if not os.path.exists(EMBEDDINGS_NPY):
        print(f"FAIL: committed golden missing: {EMBEDDINGS_NPY}", file=sys.stderr)
        return 1
    committed_emb = np.load(EMBEDDINGS_NPY)
    if committed_emb.shape != ha.shape:
        print(
            f"FAIL: embeddings golden shape {committed_emb.shape} != recomputed {ha.shape}",
            file=sys.stderr,
        )
        return 1
    if not np.allclose(committed_emb, ha, atol=CHECK_ATOL, rtol=CHECK_RTOL):
        max_abs = float(np.max(np.abs(committed_emb - ha)))
        print(
            f"FAIL: hidden states drifted from committed golden (max abs {max_abs:.3e})",
            file=sys.stderr,
        )
        return 1

    # 3c) Cross-consistency: the committed hidden states, pushed through the LM
    #     head, reproduce the committed logits -- proving embeddings.npy is the
    #     pre-LM-head tensor of the SAME forward pass (not a stray array), so the
    #     two goldens are tied together and neither can drift silently alone.
    output_w = build_weights()["output.weight"].astype(np.float64)
    if not np.allclose(committed_emb @ output_w.T, committed, atol=CHECK_ATOL, rtol=CHECK_RTOL):
        print("FAIL: committed embeddings @ output.T != committed logits", file=sys.stderr)
        return 1

    # 4) The autoregressive greedy-continuation golden still reproduces, and its
    #    per-step margin stays comfortably above the F32 noise floor.
    if not os.path.exists(GREEDY_CONT_CSV):
        print(f"FAIL: committed golden missing: {GREEDY_CONT_CSV}", file=sys.stderr)
        return 1
    cont, cont_margin = greedy_continuation(build_weights(), GREEDY_PROMPT, GREEDY_N_NEW)
    committed_cont = _read_continuation_csv(GREEDY_CONT_CSV)
    if committed_cont != cont:
        print(
            f"FAIL: greedy continuation differs from committed golden "
            f"(committed {committed_cont} != recomputed {cont})",
            file=sys.stderr,
        )
        return 1
    if cont_margin < 0.02:
        print(
            f"FAIL: greedy continuation min margin {cont_margin:.4g} < 0.02 "
            "(too close to the F32 noise floor; choose a safer prompt/length)",
            file=sys.stderr,
        )
        return 1

    print("OK: reference forward is deterministic; GGUF and committed goldens agree")
    print(f"  embeddings    : {ha.shape[0]} x {ha.shape[1]} (sha256 {_sha256_array(ha)[:16]})")
    print(f"  greedy tokens : {[int(t) for t in greedy_tokens(a)]}")
    print(f"  min top-2 gap : {np.min(top2_margins(a)):.4g}")
    print(f"  greedy cont.  : {cont} (min step margin {cont_margin:.4g})")
    return 0


def _read_continuation_csv(path: str) -> list[int]:
    with open(path) as fh:
        rows = fh.read().splitlines()
    # header: "step,token"
    return [int(line.split(",")[1]) for line in rows[1:] if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the committed goldens (self-check) without writing",
    )
    args = parser.parse_args()

    if args.check:
        return check_goldens()

    # Regenerate: run the same integrity checks the oracle relies on, then write.
    a = compute_logits()
    b = compute_logits()
    if not np.array_equal(a, b):
        print("FAIL: forward pass is not deterministic; refusing to write", file=sys.stderr)
        return 1
    gguf_weights_match_source()
    write_goldens()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
