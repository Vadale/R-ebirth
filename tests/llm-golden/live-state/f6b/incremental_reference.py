"""Pure NumPy token-at-a-time forward pass with explicit immutable KV history.

This independent implementation shares only mathematical kernels and seeded
weights with the full-prefix oracle. It never imports or calls the engine.
"""

from __future__ import annotations

import numpy as np

from reference_forward import Intervention, rmsnorm, rope_norm, silu, softmax_lastdim


class IncrementalReference:
    def __init__(self, weights: dict, config: dict):
        self.weights = {name: value.astype(np.float64) for name, value in weights.items()}
        self.config = dict(config)
        self.position = 0
        self.keys = [None] * int(config["n_layer"])
        self.values = [None] * int(config["n_layer"])

    def decode(self, token: int, intervention: Intervention):
        """Decode only this token; previous K/V entries are never recomputed."""
        n_head = int(self.config["n_head"])
        assert self.config["n_head_kv"] == n_head, "fixture uses ordinary multi-head attention"
        n_embd = int(self.config["n_embd"])
        hd = n_embd // n_head
        eps = float(self.config["rms_eps"])
        freq_base = float(self.config["rope_freq_base"])
        position = np.asarray([self.position], dtype=np.float64)
        weights = self.weights
        x = weights["token_embd.weight"][[token]]
        capture = {}
        for layer in range(int(self.config["n_layer"])):
            base = f"blk.{layer}."
            h = rmsnorm(x, weights[base + "attn_norm.weight"], eps)
            q = (h @ weights[base + "attn_q.weight"].T).reshape(1, n_head, hd)
            k = (h @ weights[base + "attn_k.weight"].T).reshape(1, n_head, hd)
            v = (h @ weights[base + "attn_v.weight"].T).reshape(1, n_head, hd)
            q = rope_norm(q, position, hd, freq_base)
            k = rope_norm(k, position, hd, freq_base)
            old_keys, old_values = self.keys[layer], self.values[layer]
            keys = k if old_keys is None else np.concatenate([old_keys, k], axis=0)
            values = v if old_values is None else np.concatenate([old_values, v], axis=0)
            if old_keys is not None:
                np.testing.assert_array_equal(keys[:-1], old_keys)
                np.testing.assert_array_equal(values[:-1], old_values)
            self.keys[layer], self.values[layer] = keys, values
            attention = np.empty((1, n_head, hd), dtype=np.float64)
            for head in range(n_head):
                scores = (q[:, head] @ keys[:, head].T) / np.sqrt(hd)
                attention[:, head] = softmax_lastdim(scores) @ values[:, head]
            attn_out = attention.reshape(1, n_embd) @ weights[base + "attn_output.weight"].T
            x = x + attn_out
            normalized = rmsnorm(x, weights[base + "ffn_norm.weight"], eps)
            gate = silu(normalized @ weights[base + "ffn_gate.weight"].T)
            up = normalized @ weights[base + "ffn_up.weight"].T
            mlp_out = (gate * up) @ weights[base + "ffn_down.weight"].T
            x = intervention.apply(x + mlp_out, layer)
            capture[(layer, "attn_out")] = attn_out[0].copy()
            capture[(layer, "mlp_out")] = mlp_out[0].copy()
            capture[(layer, "residual")] = x[0].copy()
        self.position += 1
        normalized = rmsnorm(x, weights["output_norm.weight"], eps)
        return (normalized @ weights["output.weight"].T)[0], capture
