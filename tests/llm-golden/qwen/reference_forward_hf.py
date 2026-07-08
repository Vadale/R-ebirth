#!/usr/bin/env python3
"""HF fp32 activation reference for a REAL model -> Harness B activation goldens.

This is Harness B's real-model activation oracle (WP6b), the tolerance-level
counterpart to the exact-value synthetic numpy oracle (``../synthetic/
reference_forward.py``). It runs **Qwen2.5-0.5B-Instruct** (the CI-integration
pin) in **fp32 on CPU** through the reference PyTorch/``transformers``
implementation and captures the SAME per-layer quantities ``llm_trace`` taps, so
the vendored engine's activation taps can be cross-validated numerically against
an independent implementation on a real transformer -- not merely "looked at".

Why fp32 on CPU. The HF weights are stored bf16; loaded as fp32 and computed in
fp32 on the CPU they are the highest-precision faithful forward pass of exactly
the weights the GGUF was quantized from. The committed CI GGUF (Qwen2.5-0.5B
Q8_0) quantizes those same weights and computes activations in F32, so the
engine-vs-reference gap isolates Q8_0 quantization + kernel/op-order differences
(a documented tolerance, never bit-equality). MPS is avoided (fp32 drift).

Tap semantics -- the crux (matched EXACTLY to ``rebirth-llm/src/trace.rs`` and
D-014/D-016; a semantic mismatch is the failure mode). Each captured quantity is
taken from a forward hook, NOT from ``output_hidden_states`` (see the residual
trap below):

  * ``residual`` = the block-output residual stream after BOTH residual adds --
    the engine's ``l_out-<il>`` (trace.rs ``Component::Residual`` -> ``l_out``).
    Captured as the forward-hook output of each ``Qwen2DecoderLayer``
    (``model.model.layers[il]``), which is exactly the block output before the
    model's final norm.

    THE RESIDUAL TRAP (why not output_hidden_states): ``transformers`` returns
    ``hidden_states`` of length ``L+1`` where ``hidden_states[k]`` is the INPUT to
    block ``k`` for ``k < L`` but ``hidden_states[L]`` is the post-FINAL-NORM
    state, i.e. ``norm(block[L-1] output)``, NOT the last block's ``l_out``
    (verified here: ``hidden_states[L] == model.model.norm(hook(layers[L-1]))``
    to 0.0, and it differs from the raw ``l_out-<L-1>`` by ~1e2). Using
    ``hidden_states`` for ``residual`` would therefore silently substitute a
    NORMED tensor for the last layer -- an off-by-one/normalization defect. The
    per-block forward hook gives the correct ``l_out-<il>`` for every layer,
    including the last, and equals ``hidden_states[il+1]`` for ``il < L-1``.

  * ``mlp_out`` = the FFN sub-layer output (post down-projection) BEFORE the
    residual add -- the engine's ``ffn_out-<il>`` (trace.rs ``Component::MlpOut``
    -> ``ffn_out``). Captured as the forward-hook output of each layer's ``mlp``
    (``Qwen2MLP``, the SwiGLU block).

  * ``attn_out`` = the attention post-projection output (D-014): the output of
    each layer's ``self_attn.o_proj``, BEFORE the residual add. Captured as that
    ``Linear``'s forward-hook output.

    D-014 caveat -- NOT a committed comparable golden for qwen2. On the qwen2
    architecture ``llm_trace`` does NOT observe ``attn_out``: qwen2 names only the
    PRE-projection ``kqv_out-<il>`` (a different quantity), so requesting
    ``attn_out`` raises ``relm_error_trace`` rather than silently substituting
    the pre-Wo tensor (trace.rs ``component_name``; covered by the [MODEL] test
    ``llm_trace() attn_out on a qwen2 model is a classed, honest error`` in
    ``rebirth/tests/testthat/test-llm-trace.R``). Therefore only ``residual`` and
    ``mlp_out`` are written to the committed golden and compared by the R test.
    ``attn_out`` IS still captured here and is load-bearing: the residual-identity
    self-check (``residual[il] == residual[il-1] + attn_out[il] + mlp_out[il]``,
    with ``residual[-1] = embed_tokens``) ties all three together, and its
    per-layer scale is recorded in the manifest for provenance.

Token/position alignment (audit L-7, BOS off-by-one). Qwen2's tokenizer has NO
bos token (``bos_token is None``); ``add_special_tokens=True`` and ``=False``
yield identical ids, so ``llm_trace``'s internal ``add_special=true`` tokenization,
``llm_tokens``'s ``add_special=false`` tokenization, and this reference all agree
on the id sequence (no leading BOS on any side). The reference records each
prompt's 0-based token ids and pieces in the manifest; the R comparison test
asserts ``llm_tokens(m, prompt) - 1`` equals them AND that the trace's captured
last ``token_pos`` equals ``n_tokens`` (the 1-based last position) -- so a future
BOS/tokenizer divergence (an extra leading token) fails loudly at the alignment
guard, before any activation is compared. HF ids are 0-based; the R API is 1-based
(the shift lives in ``rebirth-ffi``).

Determinism. fp32 CPU with a single compute thread; two in-process forwards are
bit-identical (the ``--check`` self-check asserts ``torch.equal``). The committed
golden is authoritative; regenerating it on a different machine may shift the low
fp32 bits and is a golden-update event (governed by the ``golden-update`` skill),
not a silent refresh.

Golden format. The activations are a single raw little-endian float32 blob
``goldens/activations.f32`` (C-order, neuron fastest), shape and SHA256 recorded
in ``goldens/manifest.json``; the R test reads it with base ``readBin`` (no numpy
on the R side) and Python reads it back with ``np.frombuffer``. A multi-MB CSV
mirror would be absurd for a real-model golden, so there is none; the manifest is
the human-readable index.

Usage (from the HF golden venv, see ``requirements-hf.txt`` -- torch/transformers
are TEST TOOLING ONLY, never a package dependency, and are deliberately absent
from ``../requirements.txt``):

    python reference_forward_hf.py            # (re)generate goldens/ (downloads the model once)
    python reference_forward_hf.py --check    # verify committed goldens, no writes

Regeneration is governed solely by the ``golden-update`` skill.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN_DIR = os.path.join(HERE, "goldens")
ACTIVATIONS_F32 = os.path.join(GOLDEN_DIR, "activations.f32")
MANIFEST_JSON = os.path.join(GOLDEN_DIR, "manifest.json")

# The R test reads the golden during R CMD check, where only the BUILT PACKAGE is
# present (the repo-root canonical path is not) -- so the blob is duplicated into
# the package fixtures, the pattern the synthetic GGUF uses. write_goldens writes
# both; --check asserts they are byte-identical (a drift guard: regenerate together).
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
PACKAGE_FIXTURE = os.path.join(
    REPO_ROOT, "rebirth", "tests", "testthat", "fixtures", "qwen-hf-activations.f32"
)

# --- fixed, documented reference inputs ------------------------------------

MODEL_ID = "Qwen/Qwen2.5-0.5B-Instruct"

# Three fixed, ASCII-clean, low-ambiguity prompts of DIFFERING length (so the
# "last"-token handling below is exercised length-robustly). No BOS on qwen2, so
# their ids are the raw BPE tokens; the exact ids/pieces are pinned in the manifest
# and re-checked against llm_tokens by the R test.
PROMPTS = [
    "The cat sat on the mat.",
    "Paris is the capital of France.",
    "Water boils at one hundred degrees Celsius.",
]

# Capture EVERY block (1-based API layers 1..24 == 0-based HF layers 0..23) so the
# R test can compute the per-layer tolerance + rank-correlation (>= 0.999/layer)
# across the whole depth and a per-layer off-by-one would show as a mismatch.
CAPTURE_LAYERS_API = list(range(1, 25))  # filled/validated against the model below

# positions = "last": one row per prompt = its LAST token's activation. This keeps
# the golden compact (it is duplicated into the package fixtures for R CMD check),
# gives full 24-layer coverage, and is the semantically strongest position (what
# generation/logits consume). Cross-position numerics (RoPE/mask/order) are already
# checked EXACTLY on the synthetic model by the Rust gate (synthetic_trace.rs); the
# R alignment guards (id match + last token_pos == n_tokens) catch any BOS/off-by-one.
POSITIONS = "last"

# The committed, comparable components (qwen2-observable). attn_out is captured in
# addition (see the module docstring / D-014) but not written to the golden.
COMPONENT_ORDER = ("residual", "mlp_out")
ALL_HOOKED = ("residual", "attn_out", "mlp_out")

# Committed-golden round-trip tolerance for --check on the generating machine
# (where determinism makes it exact). Loose enough to tolerate same-machine fp32
# noise (0 in practice), tight enough that a genuinely drifted golden fails.
CHECK_ATOL = 1e-3
CHECK_RTOL = 1e-4

# Residual-identity self-consistency tolerance (fp32 add-order rounding across 24
# layers of growing magnitude). This is a structural tie, not the golden itself.
IDENTITY_ATOL = 1e-2


# --- model / capture (torch + transformers, imported lazily) ----------------


def _load():
    """Load the tokenizer + fp32 CPU model deterministically. Lazy import so the
    module docstring / --help work without torch installed."""
    import torch
    from huggingface_hub import snapshot_download
    from transformers import AutoModelForCausalLM, AutoTokenizer

    torch.manual_seed(0)
    torch.set_num_threads(1)  # single-thread => reproducible reduction order
    path = snapshot_download(MODEL_ID)
    tok = AutoTokenizer.from_pretrained(path)
    model = AutoModelForCausalLM.from_pretrained(path, dtype=torch.float32)
    model.eval()
    return torch, tok, model, path


def _encode(tok, text: str) -> list[int]:
    """The reference token ids for a prompt. add_special_tokens mirrors
    llm_trace's add_special=true; for qwen2 (no bos) it equals =false, so it also
    matches llm_tokens. 0-based HF ids (the R test shifts llm_tokens' 1-based ids)."""
    return list(tok(text, add_special_tokens=True)["input_ids"])


def capture_prompt(torch, model, ids: list[int]) -> dict[tuple[str, int], np.ndarray]:
    """Run one prompt (no padding, no cache) and hook every layer's residual /
    attn_out / mlp_out. Returns ``{(component, il): np.float32 [n_tokens, n_embd]}``.

    residual = Qwen2DecoderLayer output (l_out-<il>); attn_out = self_attn.o_proj
    output (post-Wo, pre-residual); mlp_out = mlp output (ffn_out-<il>, pre-residual).
    """
    cap: dict[tuple[str, int], np.ndarray] = {}

    def mk(component: str, il: int):
        def hook(_mod, _inp, out):
            t = out[0] if isinstance(out, tuple) else out
            # squeeze the batch dim -> [n_tokens, n_embd]; snapshot as float32.
            cap[(component, il)] = (
                t.detach().to(torch.float32).squeeze(0).contiguous().numpy().astype(np.float32)
            )

        return hook

    handles = []
    for il, layer in enumerate(model.model.layers):
        handles.append(layer.register_forward_hook(mk("residual", il)))
        handles.append(layer.self_attn.o_proj.register_forward_hook(mk("attn_out", il)))
        handles.append(layer.mlp.register_forward_hook(mk("mlp_out", il)))
    try:
        with torch.no_grad():
            model(torch.tensor([ids], dtype=torch.long), use_cache=False)
    finally:
        for h in handles:
            h.remove()
    return cap


def _embed(torch, model, ids: list[int]) -> np.ndarray:
    with torch.no_grad():
        e = model.model.embed_tokens(torch.tensor([ids], dtype=torch.long))
    return e.detach().to(torch.float32).squeeze(0).numpy().astype(np.float32)


def _residual_identity_maxabs(torch, model, ids, cap) -> float:
    """max |residual[il] - (residual[il-1] + attn_out[il] + mlp_out[il])| over all
    layers/positions, with residual[-1] = embed_tokens(ids). Ties residual/attn/mlp
    together: a stray or misaligned capture cannot satisfy this by accident."""
    L = len(model.model.layers)
    prev = _embed(torch, model, ids)
    worst = 0.0
    for il in range(L):
        recon = prev + cap[("attn_out", il)] + cap[("mlp_out", il)]
        worst = max(worst, float(np.max(np.abs(cap[("residual", il)] - recon))))
        prev = cap[("residual", il)]
    return worst


# --- golden assembly --------------------------------------------------------


def build_reference():
    """Run all prompts, assemble the golden array + rich provenance.

    Returns ``(acts, meta, aux)`` where ``acts`` is the committed float32 array of
    shape ``[n_layers, n_components, n_prompts, n_embd]`` (COMPONENT_ORDER on axis 1;
    each prompt row is its LAST token), ``meta`` is the manifest dict, and ``aux``
    carries recomputed tensors the self-check reuses (per-prompt captures)."""
    torch, tok, model, path = _load()
    cfg = model.config
    n_embd = int(cfg.hidden_size)
    L = int(cfg.num_hidden_layers)
    # The ORIGINAL storage dtype from config.json (loading as fp32 mutates
    # cfg.torch_dtype to float32, so read the file, not the live config).
    storage_dtype = str(json.load(open(os.path.join(path, "config.json"))).get("torch_dtype", "bfloat16"))
    layers_hf = [api - 1 for api in CAPTURE_LAYERS_API]
    assert layers_hf == list(range(L)), "CAPTURE_LAYERS_API must be 1..num_hidden_layers"

    prompt_meta = []
    caps = []
    ident_worst = 0.0
    for pi, text in enumerate(PROMPTS):
        ids = _encode(tok, text)
        cap = capture_prompt(torch, model, ids)
        caps.append(cap)
        ident_worst = max(ident_worst, _residual_identity_maxabs(torch, model, ids, cap))
        prompt_meta.append(
            {
                "index_1based": pi + 1,
                "text": text,
                "token_ids_0based": [int(i) for i in ids],
                "token_pieces": [tok.convert_ids_to_tokens(int(i)) for i in ids],
                "n_tokens": len(ids),
                "last_token_pos_1based": len(ids),  # what the trace's token_pos must equal
            }
        )

    P = len(PROMPTS)
    C = len(COMPONENT_ORDER)
    # positions = "last": one row per prompt = its LAST token. Shape
    # [layer, component, prompt, neuron] (no position axis; always the last token).
    acts = np.empty((L, C, P, n_embd), dtype=np.float32)
    per_layer_maxabs = {c: [] for c in ALL_HOOKED}
    for il in range(L):
        for ci, comp in enumerate(COMPONENT_ORDER):
            for pi in range(P):
                arr = caps[pi][(comp, il)]
                if arr.shape[-1] != n_embd:
                    raise SystemExit(
                        f"capture[{comp},{il}] prompt {pi} width {arr.shape[-1]} != {n_embd}"
                    )
                acts[il, ci, pi] = arr[-1]  # the LAST token's activation
        for comp in ALL_HOOKED:
            # provenance: the layer's activation scale over ALL positions.
            per_layer_maxabs[comp].append(
                max(float(np.max(np.abs(caps[pi][(comp, il)]))) for pi in range(P))
            )

    blob = np.ascontiguousarray(acts, dtype="<f4").tobytes()

    import huggingface_hub

    meta = {
        "purpose": "WP6b Harness B real-model activation golden (fp32 HF reference "
        "for llm_trace cross-validation on Qwen2.5-0.5B).",
        "model": MODEL_ID,
        "model_type": str(cfg.model_type),
        "hf_snapshot_commit": os.path.basename(os.path.realpath(path)),
        "model_safetensors_sha256": _safetensors_sha256(path),
        "hidden_size": n_embd,
        "num_hidden_layers": L,
        "dtype_compute": "float32",
        "dtype_weights_storage": storage_dtype,
        "device": "cpu",
        "torch_num_threads": 1,
        "torch_version": torch.__version__,
        "transformers_version": __import__("transformers").__version__,
        "numpy_version": np.__version__,
        "huggingface_hub_version": huggingface_hub.__version__,
        "tokenizer_has_bos": tok.bos_token is not None,
        "prompts": prompt_meta,
        "capture_layers_api_1based": CAPTURE_LAYERS_API,
        "capture_layers_hf_0based": layers_hf,
        "positions": POSITIONS,
        "row_meaning": "each prompt contributes one row: its LAST token's activation",
        "component_order": list(COMPONENT_ORDER),
        "activations_file": os.path.basename(ACTIVATIONS_F32),
        "activations_dtype": "<f4",
        "activations_order": "C-order [layer, component, prompt, neuron]; neuron fastest",
        "activations_shape": [L, C, P, n_embd],
        "activations_sha256": hashlib.sha256(blob).hexdigest(),
        "residual_identity_maxabs": ident_worst,
        "per_layer_maxabs_residual": per_layer_maxabs["residual"],
        "per_layer_maxabs_mlp_out": per_layer_maxabs["mlp_out"],
        "attn_out_note": (
            "attn_out (self_attn.o_proj output, post-projection, D-014) is CAPTURED "
            "and validated via residual_identity but is NOT written to the golden and "
            "NOT compared: llm_trace does not observe attn_out on qwen2 (it names only "
            "the pre-projection kqv_out), raising relm_error_trace. See the module "
            "docstring and test-llm-trace.R."
        ),
        "per_layer_maxabs_attn_out_reference_only": per_layer_maxabs["attn_out"],
        "tolerance_note": (
            "The R comparison (test-llm-trace-golden.R) compares a Q8_0 GGUF via "
            "llm_trace against this fp32 reference: expect looser than the synthetic "
            "1e-2 (quantization + kernel order). The test states the observed max |Δ| "
            "per component and the per-layer rank correlation, and runs [MODEL]-gated "
            "on RELM_TEST_MODEL_QWEN (founder's Mac / nightly)."
        ),
    }
    aux = {"torch": torch, "model": model, "tok": tok, "caps": caps, "acts": acts, "blob": blob}
    return acts, meta, aux


def _safetensors_sha256(path: str) -> str:
    """SHA256 of the resolved model.safetensors blob (HF stores blobs by digest, so
    this equals the blob filename, but we hash to be self-contained)."""
    f = os.path.join(path, "model.safetensors")
    h = hashlib.sha256()
    with open(os.path.realpath(f), "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_goldens() -> int:
    os.makedirs(GOLDEN_DIR, exist_ok=True)
    acts, meta, aux = build_reference()
    with open(ACTIVATIONS_F32, "wb") as fh:
        fh.write(aux["blob"])
    # Duplicate the blob into the package fixtures so the R test reaches it under
    # R CMD check (kept byte-identical; --check enforces it).
    os.makedirs(os.path.dirname(PACKAGE_FIXTURE), exist_ok=True)
    with open(PACKAGE_FIXTURE, "wb") as fh:
        fh.write(aux["blob"])
    with open(MANIFEST_JSON, "w") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")
    L, C, P, E = meta["activations_shape"]
    print(f"wrote HF activation golden: shape [{L},{C},{P},{E}] "
          f"({len(aux['blob'])} bytes, sha256 {meta['activations_sha256'][:16]})")
    print(f"  components   : {meta['component_order']} (attn_out captured, not committed -- D-014)")
    print(f"  prompts      : {[p['text'] for p in meta['prompts']]}")
    print(f"  residual id. : max |resid - (resid_prev+attn+mlp)| = {meta['residual_identity_maxabs']:.3e}")
    print(f"  resid |max|  : layer0 {meta['per_layer_maxabs_residual'][0]:.3g} "
          f".. layer{L-1} {meta['per_layer_maxabs_residual'][-1]:.3g}")
    return 0


def check_goldens() -> int:
    if not (os.path.exists(ACTIVATIONS_F32) and os.path.exists(MANIFEST_JSON)):
        print("FAIL: committed golden missing (run without --check to generate)", file=sys.stderr)
        return 1
    committed = json.load(open(MANIFEST_JSON))

    # 1) recompute the reference and check same-machine determinism (bit-identical
    #    forwards) via the residual identity + a second capture of prompt 0.
    acts, meta, aux = build_reference()
    torch, model, caps = aux["torch"], aux["model"], aux["caps"]
    ids0 = committed["prompts"][0]["token_ids_0based"]
    cap_again = capture_prompt(torch, model, ids0)
    for key in [("residual", 0), ("mlp_out", 0), ("attn_out", 0), ("residual", meta["num_hidden_layers"] - 1)]:
        if not np.array_equal(caps[0][key], cap_again[key]):
            print(f"FAIL: forward not deterministic (two captures of {key} differ)", file=sys.stderr)
            return 1

    # 1b) the residual identity holds (ties residual/attn_out/mlp_out together).
    if meta["residual_identity_maxabs"] > IDENTITY_ATOL:
        print(
            f"FAIL: residual identity max |Δ| {meta['residual_identity_maxabs']:.3e} "
            f"> {IDENTITY_ATOL} (residual != residual_prev + attn_out + mlp_out)",
            file=sys.stderr,
        )
        return 1

    # 2) the recomputed reference round-trips the committed blob within tolerance,
    #    and the committed manifest still describes it (shape + sha of the blob on disk).
    if committed["activations_shape"] != meta["activations_shape"]:
        print(
            f"FAIL: shape {committed['activations_shape']} != recomputed {meta['activations_shape']}",
            file=sys.stderr,
        )
        return 1
    on_disk = open(ACTIVATIONS_F32, "rb").read()
    if hashlib.sha256(on_disk).hexdigest() != committed["activations_sha256"]:
        print("FAIL: activations.f32 on disk does not match manifest activations_sha256", file=sys.stderr)
        return 1
    # The package fixture copy must be byte-identical to the canonical blob (both
    # are regenerated together; the R test reads the fixture copy under R CMD check).
    if not (os.path.exists(PACKAGE_FIXTURE) and open(PACKAGE_FIXTURE, "rb").read() == on_disk):
        print(
            "FAIL: package fixture (rebirth/tests/testthat/fixtures/qwen-hf-activations.f32) "
            "missing or differs from the canonical activations.f32; re-run without --check",
            file=sys.stderr,
        )
        return 1
    disk_arr = np.frombuffer(on_disk, dtype="<f4").reshape(committed["activations_shape"])
    if not np.allclose(disk_arr, acts, atol=CHECK_ATOL, rtol=CHECK_RTOL):
        max_abs = float(np.max(np.abs(disk_arr.astype(np.float64) - acts.astype(np.float64))))
        print(f"FAIL: recomputed activations drifted from committed golden (max abs {max_abs:.3e})",
              file=sys.stderr)
        return 1

    # 3) the pinned token ids still match this tokenizer (a tokenizer bump that
    #    shifted ids would invalidate the alignment the R guard relies on).
    for pm in committed["prompts"]:
        ids_now = _encode(aux["tok"], pm["text"])
        if ids_now != pm["token_ids_0based"]:
            print(f"FAIL: prompt {pm['index_1based']} ids changed: {ids_now} != {pm['token_ids_0based']}",
                  file=sys.stderr)
            return 1

    print("OK: HF activation golden is deterministic; blob + manifest + token ids agree")
    print(f"  residual identity max |Δ| = {meta['residual_identity_maxabs']:.3e}")
    print(f"  shape {meta['activations_shape']} sha256 {meta['activations_sha256'][:16]}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="HF fp32 activation golden for Qwen2.5-0.5B (WP6b).")
    parser.add_argument("--check", action="store_true", help="verify committed goldens, no writes")
    args = parser.parse_args()
    return check_goldens() if args.check else write_goldens()


if __name__ == "__main__":
    raise SystemExit(main())
