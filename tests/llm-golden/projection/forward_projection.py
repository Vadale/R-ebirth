"""Independent token-at-a-time Llama mathematics with explicit producer sites.

No engine imports: kernels come only from the accepted NumPy oracle. All cached
K/V belongs to already executed tokens and is immutable on later updates.
"""
from __future__ import annotations

import numpy as np
from reference_forward import Intervention, rmsnorm, rope_norm, silu, softmax_lastdim


class ProjectionForward:
    def __init__(self, weights, config, project, sites=None, fault=""):
        self.weights = {name: value.astype(np.float64) for name, value in weights.items()}
        self.config = dict(config)
        self.project = project
        self.sites = sites or {}
        self.fault = fault
        self.position = 0
        self.keys = [None] * int(config["n_layer"])
        self.values = [None] * int(config["n_layer"])
        self.rows = []

    def apply_site(self, values, residual, layer, component, pending):
        # A real GGML producer supplies F32. The independent model kernels stay
        # F64; the producer boundary is rounded once before projection arithmetic.
        before = values[0].astype(np.float32)
        result = before.copy()
        if (layer, component) in self.sites:
            direction, coefficient = self.sites[(layer, component)]
            candidate, dot, updated = self.project(before, direction, coefficient)
            if self.fault == "residual_site":
                result = self.project((values + residual)[0].astype(np.float32),
                                      direction, coefficient)[0]
                # The caller subtracts the existing residual so the wrong
                # residual-sum projection is not accidentally added twice.
                result = result.astype(np.float64) - residual[0]
            elif self.fault in ("missing", "noop") or (
                    self.fault == "last_prefill_row_only" and self.position < 512):
                result = before
            elif self.fault == "read_only":
                # A changed host/capture copy is insufficient: later nodes must
                # consume it. Publish the false observation but use old values.
                pending[(layer, component)] = candidate.astype(np.float64)
            else:
                result = candidate
            self.rows.append((self.position + 1, layer + 1, component,
                              before.copy(), np.asarray(result).copy(), dot, updated))
        return np.asarray(result, dtype=np.float64)[None, :]

    def decode(self, token, intervention=None):
        intervention = intervention or Intervention()
        c, w = self.config, self.weights
        heads, width = int(c["n_head"]), int(c["n_embd"])
        assert int(c["n_head_kv"]) == heads
        hd, eps = width // heads, float(c["rms_eps"])
        position = np.asarray([self.position], dtype=np.float64)
        x = w["token_embd.weight"][[token]]
        capture, pending = {}, {}
        for layer in range(int(c["n_layer"])):
            base = f"blk.{layer}."
            h = rmsnorm(x, w[base + "attn_norm.weight"], eps)
            q, k, v = [(h @ w[base + "attn_" + kind + ".weight"].T).reshape(1, heads, hd)
                       for kind in ("q", "k", "v")]
            q = rope_norm(q, position, hd, float(c["rope_freq_base"]))
            k = rope_norm(k, position, hd, float(c["rope_freq_base"]))
            old_k, old_v = self.keys[layer], self.values[layer]
            keys = k if old_k is None else np.concatenate((old_k, k), axis=0)
            values = v if old_v is None else np.concatenate((old_v, v), axis=0)
            if old_k is not None:
                assert np.array_equal(keys[:-1], old_k) and np.array_equal(values[:-1], old_v)
            self.keys[layer], self.values[layer] = keys, values
            attention = np.empty((1, heads, hd), dtype=np.float64)
            for head in range(heads):
                scores = q[:, head] @ keys[:, head].T / np.sqrt(hd)
                attention[:, head] = softmax_lastdim(scores) @ values[:, head]
            # Llama attention projection is after Wo, before adding x.
            attn = attention.reshape(1, width) @ w[base + "attn_output.weight"].T
            attn = self.apply_site(attn, x, layer, "attn_out", pending)
            x = x + attn
            h = rmsnorm(x, w[base + "ffn_norm.weight"], eps)
            gate = silu(h @ w[base + "ffn_gate.weight"].T)
            up = h @ w[base + "ffn_up.weight"].T
            # The raw down-projected FFN output is edited before residual add.
            mlp = (gate * up) @ w[base + "ffn_down.weight"].T
            mlp = self.apply_site(mlp, x, layer, "mlp_out", pending)
            x = intervention.apply(x + mlp, layer)
            capture[(layer, "attn_out")] = pending.get((layer, "attn_out"), attn[0].copy())
            capture[(layer, "mlp_out")] = pending.get((layer, "mlp_out"), mlp[0].copy())
            capture[(layer, "residual")] = x[0].copy()
        self.position += 1
        logits = rmsnorm(x, w["output_norm.weight"], eps) @ w["output.weight"].T
        return logits[0], capture
